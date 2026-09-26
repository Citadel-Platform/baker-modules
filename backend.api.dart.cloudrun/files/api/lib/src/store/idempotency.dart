import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// A stored answer to an idempotent request.
class StoredAnswer {
  const StoredAnswer({
    required this.status,
    required this.body,
    required this.contentType,
  });
  final int status;
  final String body;
  final String contentType;
}

/// What claiming a key found.
sealed class Claim {
  const Claim();
}

/// Nobody had the key: this request acts, then [IdempotencyStore.complete]s.
final class Claimed extends Claim {
  const Claimed();
}

/// The same request again, already answered.
final class Answered extends Claim {
  const Answered(this.answer);
  final StoredAnswer answer;
}

/// The same key is still being acted on.
final class InProgress extends Claim {
  const InProgress();
}

/// The key was used before for a different request.
final class Reused extends Claim {
  const Reused();
}

/// Records idempotency keys so a retried request acts once.
///
/// Shared by every instance: an in-memory store would let a retry that lands
/// on another instance act twice.
abstract interface class IdempotencyStore {
  /// Claims [key] for a request with [fingerprint], atomically.
  Future<Claim> claim(String key, String fingerprint);

  /// Stores the answer; repeats get it back until it expires.
  Future<void> complete(String key, StoredAnswer answer);

  /// Forgets the claim, so the request can be tried again (after a failure
  /// that did not act).
  Future<void> release(String key);
}

/// The document id for a caller's key on a route: a hash, so neither the key
/// nor the person is readable from the id.
String idempotencyId(String uid, String route, String key) =>
    sha256.convert(utf8.encode('$uid\u0000$route\u0000$key')).toString();

/// A request's fingerprint: method, path and body.
String requestFingerprint(String method, String path, List<int> body) => sha256
    .convert(<int>[...utf8.encode('$method $path\n'), ...body])
    .toString();

/// In Firestore, via its REST API, in the `_idempotency` collection. A TTL
/// policy on `expireAt` (Terraform) deletes records after [keep].
class FirestoreIdempotencyStore implements IdempotencyStore {
  FirestoreIdempotencyStore(
    this._client, {
    required String projectId,
    String database = '(default)',
    Uri? endpoint,
    this.keep = const Duration(hours: 24),
    this.claimTimeout = const Duration(minutes: 2),
    DateTime Function()? clock,
  }) : _documents =
           (endpoint ?? Uri.parse('https://firestore.googleapis.com/v1/'))
               .resolve('projects/$projectId/databases/$database/documents/'),
       _clock = clock ?? DateTime.now;

  final http.Client _client;
  final Uri _documents;
  final Duration keep;

  /// A pending claim older than this is taken to be from a request that died
  /// without releasing it, and may be claimed again.
  final Duration claimTimeout;
  final DateTime Function() _clock;

  static const String collection = '_idempotency';

  Uri _doc(String key) => _documents.resolve('$collection/$key');

  @override
  Future<Claim> claim(String key, String fingerprint) async {
    final DateTime now = _clock().toUtc();
    final http.Response created = await _client.post(
      _documents.resolve('$collection?documentId=$key'),
      headers: <String, String>{'content-type': 'application/json'},
      body: jsonEncode(<String, Object?>{
        'fields': <String, Object?>{
          'state': <String, Object?>{'stringValue': 'pending'},
          'fingerprint': <String, Object?>{'stringValue': fingerprint},
          'claimedAt': <String, Object?>{
            'timestampValue': now.toIso8601String(),
          },
          'expireAt': <String, Object?>{
            'timestampValue': now.add(keep).toIso8601String(),
          },
        },
      }),
    );
    if (created.statusCode == 200) return const Claimed();
    if (created.statusCode != 409) {
      throw StateError(
        'Firestore answered ${created.statusCode} creating a claim',
      );
    }

    final http.Response got = await _client.get(_doc(key));
    if (got.statusCode == 404) return claim(key, fingerprint);
    if (got.statusCode != 200) {
      throw StateError('Firestore answered ${got.statusCode} reading a claim');
    }
    final Map<String, Object?> doc =
        jsonDecode(got.body) as Map<String, Object?>;
    final Map<String, Object?> f = doc['fields']! as Map<String, Object?>;
    String str(String n) =>
        '${(f[n] as Map<String, Object?>?)?['stringValue'] ?? ''}';
    if (str('fingerprint') != fingerprint) return const Reused();
    if (str('state') == 'done') {
      return Answered(
        StoredAnswer(
          status: int.parse(
            '${(f['status']! as Map<String, Object?>)['integerValue']}',
          ),
          body: str('body'),
          contentType: str('contentType'),
        ),
      );
    }
    final DateTime claimedAt = DateTime.parse(
      '${(f['claimedAt']! as Map<String, Object?>)['timestampValue']}',
    );
    if (now.difference(claimedAt) > claimTimeout) {
      // Take over only if nobody else did first: the write is conditional on
      // the document being unchanged since it was read. A commit, with the
      // precondition in the body, which is the form Firestore documents for
      // conditional writes.
      final String name =
          '${_documents.path.substring(_documents.path.indexOf('projects/'))}$collection/$key';
      final http.Response retaken = await _client.post(
        _documents.replace(
          path: _documents.path.replaceFirst(
            RegExp(r'/documents/$'),
            '/documents:commit',
          ),
        ),
        headers: <String, String>{'content-type': 'application/json'},
        body: jsonEncode(<String, Object?>{
          'writes': <Object?>[
            <String, Object?>{
              'update': <String, Object?>{
                'name': name,
                'fields': <String, Object?>{
                  'claimedAt': <String, Object?>{
                    'timestampValue': now.toIso8601String(),
                  },
                },
              },
              'updateMask': <String, Object?>{
                'fieldPaths': <String>['claimedAt'],
              },
              'currentDocument': <String, Object?>{
                'updateTime': doc['updateTime'],
              },
            },
          ],
        }),
      );
      if (retaken.statusCode == 200) return const Claimed();
    }
    return const InProgress();
  }

  @override
  Future<void> complete(String key, StoredAnswer answer) async {
    final http.Response r = await _client.patch(
      _doc(key).replace(
        queryParameters: <String, List<String>>{
          'updateMask.fieldPaths': <String>[
            'state',
            'status',
            'body',
            'contentType',
          ],
        },
      ),
      headers: <String, String>{'content-type': 'application/json'},
      body: jsonEncode(<String, Object?>{
        'fields': <String, Object?>{
          'state': <String, Object?>{'stringValue': 'done'},
          'status': <String, Object?>{'integerValue': '${answer.status}'},
          'body': <String, Object?>{'stringValue': answer.body},
          'contentType': <String, Object?>{'stringValue': answer.contentType},
        },
      }),
    );
    if (r.statusCode != 200) {
      throw StateError('Firestore answered ${r.statusCode} storing an answer');
    }
  }

  @override
  Future<void> release(String key) async {
    final http.Response r = await _client.delete(_doc(key));
    if (r.statusCode != 200 && r.statusCode != 404) {
      throw StateError('Firestore answered ${r.statusCode} releasing a claim');
    }
  }
}

/// For tests and local runs with no database.
class MemoryIdempotencyStore implements IdempotencyStore {
  final Map<String, ({String fingerprint, StoredAnswer? answer})> _entries =
      <String, ({String fingerprint, StoredAnswer? answer})>{};

  @override
  Future<Claim> claim(String key, String fingerprint) async {
    final ({String fingerprint, StoredAnswer? answer})? e = _entries[key];
    if (e == null) {
      _entries[key] = (fingerprint: fingerprint, answer: null);
      return const Claimed();
    }
    if (e.fingerprint != fingerprint) return const Reused();
    return e.answer == null ? const InProgress() : Answered(e.answer!);
  }

  @override
  Future<void> complete(String key, StoredAnswer answer) async {
    _entries[key] = (fingerprint: _entries[key]!.fingerprint, answer: answer);
  }

  @override
  Future<void> release(String key) async => _entries.remove(key);
}
