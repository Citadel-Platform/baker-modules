import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:googleapis/firestore/v1.dart' as fs;
import 'package:http/http.dart' as http;

import '../api.dart';
import 'ledger.dart';
import 'token_store.dart';

/// Xero's OAuth 2.0, as its SDKs and OpenAPI description define it:
/// authorize at `login.xero.com/identity/connect/authorize`, tokens from
/// `identity.xero.com/connect/token` (form body, client credentials as HTTP
/// Basic), organisations from `api.xero.com/connections`.
///
/// Access tokens last 30 minutes. Refresh tokens last 60 days unused and
/// rotate: each refresh returns a new one and the old stops working, except
/// that a refresh which got no answer may be retried with the old token for
/// 30 minutes. So a refresh happens under a lock (two instances refreshing
/// at once would each burn the other's token), and the new token is stored
/// before it is used.
class XeroAuth {
  XeroAuth({
    required this.client,
    required this.clientId,
    required this.clientSecret,
    required this.redirectUri,
    required this.tokens,
    required this.db,
    Uri? identity,
    Uri? api,
    DateTime Function()? clock,
  }) : identity = identity ?? Uri.parse('https://identity.xero.com/'),
       loginUri = Uri.parse(
         'https://login.xero.com/identity/connect/authorize',
       ),
       apiRoot = api ?? Uri.parse('https://api.xero.com/'),
       _clock = clock ?? DateTime.now;

  final http.Client client;
  final String clientId;
  final String clientSecret;
  final String redirectUri;
  final TokenStore tokens;
  final AppFirestore db;
  final Uri identity;
  final Uri loginUri;
  final Uri apiRoot;
  final DateTime Function() _clock;

  static const List<String> scopes = <String>[
    'offline_access',
    'accounting.transactions',
    'accounting.contacts',
    'accounting.settings.read',
  ];

  static const String connection = '_ledger/xero';
  static const String states = '_ledger_oauth_states';
  static const String lock = '_ledger_locks/xero-refresh';

  String? _access;
  DateTime _accessExpires = DateTime.fromMillisecondsSinceEpoch(0);

  /// The address to send an administrator to, and remember the request by.
  Future<Uri> authorizeUrl({required String uid}) async {
    // 32 random bytes: the state is what stops another site completing a
    // connection with its own Xero account.
    final Random random = Random.secure();
    final String state = base64Url
        .encode(List<int>.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    await db.commit(<fs.Write>[
      db.set('$states/$state', <String, Object?>{
        'uid': uid,
        'expireAt': _clock().toUtc().add(const Duration(minutes: 10)),
      }, mustNotExist: true),
    ]);
    return loginUri.replace(
      queryParameters: <String, String>{
        'response_type': 'code',
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'scope': scopes.join(' '),
        'state': state,
      },
    );
  }

  /// Completes the connection from Xero's redirect: the state must be one
  /// this API issued in the last 10 minutes, used once.
  Future<({String tenantId, String tenantName, int organisations})> complete({
    required String code,
    required String state,
  }) async {
    final Map<String, Object?>? issued = await db.get('$states/$state');
    await db.commit(<fs.Write>[db.delete('$states/$state')]);
    final DateTime? expires = issued?['expireAt'] as DateTime?;
    if (issued == null || expires == null || _clock().isAfter(expires)) {
      throw const Problem(
        400,
        'bad_state',
        'This connection link expired or was already used',
      );
    }
    final Map<String, Object?> t = await _token(<String, String>{
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': redirectUri,
    });
    await _keep(t);
    final List<Object?> orgs = await _connections();
    if (orgs.isEmpty) {
      throw const Problem(
        409,
        'no_organisation',
        'The Xero account connected no organisation',
      );
    }
    // One organisation per application: several would need a choice this
    // module does not guess at.
    final Map<String, Object?> org = orgs.first! as Map<String, Object?>;
    await db.commit(<fs.Write>[
      db.set(connection, <String, Object?>{
        'tenantId': org['tenantId'],
        'tenantName': org['tenantName'],
        'connectionId': org['id'],
        'connectedBy': issued['uid'],
        'connectedAt': _clock().toUtc(),
        'organisations': orgs.length,
      }),
    ]);
    return (
      tenantId: '${org['tenantId']}',
      tenantName: '${org['tenantName']}',
      organisations: orgs.length,
    );
  }

  /// A valid access token, refreshing if needed.
  Future<String> accessToken() async {
    if (_access != null && _clock().isBefore(_accessExpires)) return _access!;
    await _withLock(() async {
      // Another instance may have refreshed while this one waited.
      if (_access != null && _clock().isBefore(_accessExpires)) return;
      final String? refresh = await tokens.read();
      if (refresh == null) throw const LedgerNotConnected();
      Map<String, Object?> t;
      try {
        t = await _token(<String, String>{
          'grant_type': 'refresh_token',
          'refresh_token': refresh,
        });
      } on TimeoutException {
        // No answer: the old token stays good for 30 minutes; try once more.
        t = await _token(<String, String>{
          'grant_type': 'refresh_token',
          'refresh_token': refresh,
        });
      }
      await _keep(t);
    });
    return _access!;
  }

  /// Makes the next call refresh (after Xero refused the token).
  void forget() => _access = null;

  Future<void> _keep(Map<String, Object?> t) async {
    final Object? refresh = t['refresh_token'];
    if (refresh is! String || refresh.isEmpty) {
      throw LedgerUnavailable(
        'Xero issued no refresh token; offline_access may not be granted',
      );
    }
    // Stored before use: a token lost after rotation disconnects the client.
    await tokens.write(refresh);
    _access = t['access_token']! as String;
    final int life = (t['expires_in'] as int?) ?? 1800;
    _accessExpires = _clock().add(Duration(seconds: life - 60));
  }

  Future<Map<String, Object?>> _token(Map<String, String> form) async {
    final http.Response r = await client
        .post(
          identity.resolve('connect/token'),
          headers: <String, String>{
            'authorization':
                'Basic ${base64.encode(utf8.encode('$clientId:$clientSecret'))}',
            'content-type': 'application/x-www-form-urlencoded',
          },
          body: form,
        )
        .timeout(const Duration(seconds: 20));
    final Object? body = r.body.isEmpty ? null : jsonDecode(r.body);
    if (r.statusCode == 400 &&
        body is Map &&
        body['error'] == 'invalid_grant') {
      // Revoked, expired after 60 days unused, or already rotated.
      await tokens.clear();
      throw const LedgerNotConnected();
    }
    if (r.statusCode != 200 || body is! Map<String, Object?>) {
      throw LedgerUnavailable('Xero identity answered ${r.statusCode}');
    }
    return body;
  }

  Future<List<Object?>> _connections() async {
    final http.Response r = await client.get(
      apiRoot.resolve('connections'),
      headers: <String, String>{
        'authorization': 'Bearer ${await accessToken()}',
      },
    );
    if (r.statusCode != 200) {
      throw LedgerUnavailable('Xero connections answered ${r.statusCode}');
    }
    return jsonDecode(r.body) as List<Object?>;
  }

  /// Disconnects: removes the organisation's connection at Xero and forgets
  /// the tokens. The ledger's documents are untouched.
  Future<void> disconnect() async {
    final Map<String, Object?>? c = await db.get(connection);
    final Object? id = c?['connectionId'];
    if (id is String) {
      try {
        await client.delete(
          apiRoot.resolve('connections/$id'),
          headers: <String, String>{
            'authorization': 'Bearer ${await accessToken()}',
          },
        );
      } on LedgerNotConnected {
        // Already gone at Xero's end.
      }
    }
    await tokens.clear();
    _access = null;
    await db.commit(<fs.Write>[db.delete(connection)]);
  }

  Future<void> _withLock(Future<void> Function() body) async {
    for (int attempt = 0; attempt < 20; attempt++) {
      final DateTime now = _clock().toUtc();
      try {
        await db.commit(<fs.Write>[
          db.set(lock, <String, Object?>{
            'at': now,
            'expireAt': now.add(const Duration(minutes: 1)),
          }, mustNotExist: true),
        ]);
      } on fs.DetailedApiRequestError catch (e) {
        if (e.status != 409) rethrow;
        final ({Map<String, Object?> data, String updateTime})? held = await db
            .getVersioned(lock);
        final DateTime? at = held?.data['at'] as DateTime?;
        if (held != null &&
            at != null &&
            now.difference(at) > const Duration(seconds: 45)) {
          // Only the stale lock that was read: not one taken since.
          try {
            await db.commit(<fs.Write>[
              fs.Write(
                delete: db.name(lock),
                currentDocument: fs.Precondition(updateTime: held.updateTime),
              ),
            ]);
          } on fs.DetailedApiRequestError catch (e) {
            if (e.status != 400 && e.status != 409) rethrow;
          }
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        continue;
      }
      try {
        return await body();
      } finally {
        await db.commit(<fs.Write>[db.delete(lock)]);
      }
    }
    throw LedgerUnavailable(
      'Another instance is refreshing the Xero connection',
      retryAfterSeconds: 5,
    );
  }
}
