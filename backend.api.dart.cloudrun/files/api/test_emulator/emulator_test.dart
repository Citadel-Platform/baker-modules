@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:api/api.dart';
import 'package:googleapis/firestore/v1.dart' as fs;
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// The Firestore idempotency store and the revocation check, against the
/// emulators: the same REST surfaces as production.
///
///     firebase emulators:exec --only auth,firestore --project demo-local \
///       "cd api && dart test test_emulator"
void main() {
  final String store = Platform.environment['FIRESTORE_EMULATOR_HOST'] ?? '';
  final String auth = Platform.environment['FIREBASE_AUTH_EMULATOR_HOST'] ?? '';
  const String project = 'demo-local';
  late http.Client owner;

  setUpAll(() {
    expect(store, isNotEmpty, reason: 'Run under firebase emulators:exec.');
    expect(auth, isNotEmpty, reason: 'Run under firebase emulators:exec.');
    owner = _Owner();
  });
  tearDownAll(() => owner.close());

  group('FirestoreIdempotencyStore', () {
    late FirestoreIdempotencyStore s;
    DateTime now = DateTime.now();
    setUp(() {
      now = DateTime.now();
      s = FirestoreIdempotencyStore(
        owner,
        projectId: project,
        endpoint: Uri.parse('http://$store/v1/'),
        clock: () => now,
      );
    });
    String key() => 'k${DateTime.now().microsecondsSinceEpoch}';

    test('claim, complete, replay; a different request is refused', () async {
      final String k = key();
      expect(await s.claim(k, 'f1'), isA<Claimed>());
      expect(await s.claim(k, 'f1'), isA<InProgress>());
      expect(await s.claim(k, 'f2'), isA<Reused>());
      await s.complete(
        k,
        const StoredAnswer(
          status: 201,
          body: '{"a":1}',
          contentType: 'application/json',
        ),
      );
      final Claim again = await s.claim(k, 'f1');
      expect(again, isA<Answered>());
      expect((again as Answered).answer.body, '{"a":1}');
      expect(again.answer.status, 201);
    });

    test('release lets it be claimed afresh', () async {
      final String k = key();
      await s.claim(k, 'f');
      await s.release(k);
      expect(await s.claim(k, 'f'), isA<Claimed>());
    });

    test('a claim abandoned past the timeout is taken over, once', () async {
      final String k = key();
      await s.claim(k, 'f');
      now = now.add(const Duration(minutes: 3));
      final List<Claim> racers = await Future.wait(<Future<Claim>>[
        s.claim(k, 'f'),
        s.claim(k, 'f'),
      ]);
      expect(racers.whereType<Claimed>(), hasLength(1));
      expect(racers.whereType<InProgress>(), hasLength(1));
    });

    test('two first claims race and exactly one wins', () async {
      final String k = key();
      final List<Claim> racers = await Future.wait(<Future<Claim>>[
        for (int i = 0; i < 5; i++) s.claim(k, 'f'),
      ]);
      expect(racers.whereType<Claimed>(), hasLength(1));
    });

    test('records carry an expiry for the TTL policy', () async {
      final String k = key();
      await s.claim(k, 'f');
      final http.Response r = await owner.get(
        Uri.parse(
          'http://$store/v1/projects/$project/databases/(default)/documents/_idempotency/$k',
        ),
      );
      final Map<String, Object?> fields =
          (jsonDecode(r.body) as Map<String, Object?>)['fields']!
              as Map<String, Object?>;
      expect(fields, contains('expireAt'));
    });
  });

  group('AppFirestore', () {
    late AppFirestore db;
    setUp(() {
      db = AppFirestore(
        fs.FirestoreApi(owner, rootUrl: 'http://$store/'),
        projectId: 'demo-store-${DateTime.now().microsecondsSinceEpoch}',
      );
    });

    test('a conditional write fails once the document has changed', () async {
      await db.commit(<fs.Write>[
        db.set('things/a', <String, Object?>{'n': 1}),
      ]);
      final ({Map<String, Object?> data, String updateTime}) v = (await db
          .getVersioned('things/a'))!;
      await db.commit(<fs.Write>[
        db.update('things/a', <String, Object?>{'n': 2}),
      ]);
      await expectLater(
        db.commit(<fs.Write>[
          db.updateIfUnchanged('things/a', <String, Object?>{
            'n': 3,
          }, v.updateTime),
        ]),
        throwsA(isA<fs.DetailedApiRequestError>()),
      );
      expect((await db.get('things/a'))!['n'], 2);
      final ({Map<String, Object?> data, String updateTime}) now = (await db
          .getVersioned('things/a'))!;
      await db.commit(<fs.Write>[
        db.updateIfUnchanged('things/a', <String, Object?>{
          'n': 3,
        }, now.updateTime),
      ]);
      expect((await db.get('things/a'))!['n'], 3);
    });

    test(
      'values round-trip, and paging by id visits each document once',
      () async {
        final DateTime t = DateTime.utc(2026, 9, 27, 1, 2, 3);
        await db.commit(<fs.Write>[
          for (int i = 0; i < 7; i++)
            db.set('rows/r$i', <String, Object?>{
              'i': i,
              'at': t,
              'tags': <Object?>['a', 1, true],
              'money': <String, Object?>{'minor': 1234, 'currency': 'SGD'},
              'none': null,
            }),
        ]);
        final Map<String, Object?> r0 = (await db.get('rows/r0'))!;
        expect(r0['at'], t);
        expect(r0['tags'], <Object?>['a', 1, true]);
        expect(r0['money'], <String, Object?>{
          'minor': 1234,
          'currency': 'SGD',
        });
        expect(r0.containsKey('none'), isTrue);

        final List<String> seen = <String>[];
        String? after;
        do {
          final List<({String id, Map<String, Object?> data})> page = await db
              .query('rows', limit: 3, startAfterId: after);
          seen.addAll(
            page.map((({String id, Map<String, Object?> data}) p) => p.id),
          );
          after = page.length == 3 ? page.last.id : null;
        } while (after != null);
        expect(seen, <String>['r0', 'r1', 'r2', 'r3', 'r4', 'r5', 'r6']);
      },
    );
  });

  group('IdentityToolkitRevocation', () {
    Future<String> signUp() async {
      final http.Response r = await http.post(
        Uri.parse(
          'http://$auth/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake',
        ),
        headers: <String, String>{'content-type': 'application/json'},
        body: jsonEncode(<String, Object?>{
          'email': 'r${DateTime.now().microsecondsSinceEpoch}@example.com',
          'password': 'emulator-only',
        }),
      );
      return (jsonDecode(r.body) as Map<String, Object?>)['localId']! as String;
    }

    IdentityToolkitRevocation check() => IdentityToolkitRevocation(
      owner,
      projectId: project,
      endpoint: Uri.parse('http://$auth/identitytoolkit.googleapis.com/v1/'),
      ttl: Duration.zero,
    );

    VerifiedUser user(String uid, DateTime signedIn) => VerifiedUser(
      uid: uid,
      roles: const <String>{},
      authTime: signedIn,
      issuedAt: signedIn,
    );

    test('a standing sign-in passes; a disabled account does not', () async {
      final String uid = await signUp();
      await check().check(user(uid, DateTime.now()));
      await owner.post(
        Uri.parse(
          'http://$auth/identitytoolkit.googleapis.com/v1/projects/$project/accounts:update',
        ),
        headers: <String, String>{'content-type': 'application/json'},
        body: jsonEncode(<String, Object?>{
          'localId': uid,
          'disableUser': true,
        }),
      );
      await expectLater(
        check().check(user(uid, DateTime.now())),
        throwsA(
          isA<TokenRejected>().having(
            (TokenRejected r) => r.reason,
            'reason',
            'account disabled',
          ),
        ),
      );
    });

    test('a sign-in from before a revocation no longer stands', () async {
      final String uid = await signUp();
      final DateTime before = DateTime.now().subtract(
        const Duration(minutes: 5),
      );
      final int nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await owner.post(
        Uri.parse(
          'http://$auth/identitytoolkit.googleapis.com/v1/projects/$project/accounts:update',
        ),
        headers: <String, String>{'content-type': 'application/json'},
        body: jsonEncode(<String, Object?>{
          'localId': uid,
          'validSince': '$nowSeconds',
        }),
      );
      await expectLater(
        check().check(user(uid, before)),
        throwsA(
          isA<TokenRejected>().having(
            (TokenRejected r) => r.reason,
            'reason',
            'sign-in revoked',
          ),
        ),
      );
      await check().check(
        user(uid, DateTime.now().add(const Duration(seconds: 2))),
      );
    });

    test('a deleted account does not stand', () async {
      await expectLater(
        check().check(
          user(
            'no-such-uid-${DateTime.now().microsecondsSinceEpoch}',
            DateTime.now(),
          ),
        ),
        throwsA(isA<TokenRejected>()),
      );
    });
  });
}

class _Owner extends http.BaseClient {
  final http.Client _inner = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['authorization'] = 'Bearer owner';
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
