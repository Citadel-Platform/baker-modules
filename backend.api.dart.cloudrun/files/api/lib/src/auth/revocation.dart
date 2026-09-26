import 'dart:convert';

import 'package:http/http.dart' as http;

import 'token_verifier.dart';

/// Whether a signed-in person's session still stands: not revoked, account
/// not disabled. A valid token says who someone was when it was issued; this
/// asks Firebase about now.
abstract interface class RevocationCheck {
  /// Throws [TokenRejected] when the session no longer stands.
  Future<void> check(VerifiedUser user);
}

/// Through the Identity Toolkit API (`accounts:lookup`), as the service's own
/// identity. Answers are cached for [ttl] per person: revoking takes effect
/// within that, and a busy page does not look the account up per request.
class IdentityToolkitRevocation implements RevocationCheck {
  IdentityToolkitRevocation(
    this._client, {
    required this.projectId,
    Uri? endpoint,
    this.ttl = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : endpoint =
           endpoint ?? Uri.parse('https://identitytoolkit.googleapis.com/v1/'),
       _clock = clock ?? DateTime.now;

  final http.Client _client;
  final String projectId;
  final Uri endpoint;
  final Duration ttl;
  final DateTime Function() _clock;
  final Map<String, ({DateTime at, DateTime validSince, bool disabled})>
  _cache = <String, ({DateTime at, DateTime validSince, bool disabled})>{};

  @override
  Future<void> check(VerifiedUser user) async {
    final DateTime now = _clock();
    ({DateTime at, DateTime validSince, bool disabled})? known =
        _cache[user.uid];
    if (known == null || now.difference(known.at) > ttl) {
      known = await _lookup(user.uid, now);
      _cache[user.uid] = known;
    }
    if (known.disabled) throw const TokenRejected('account disabled');
    // Revoking sets validSince to the revocation time, in whole seconds;
    // any sign-in before it no longer stands.
    if (user.authTime.isBefore(known.validSince)) {
      throw const TokenRejected('sign-in revoked');
    }
  }

  Future<({DateTime at, DateTime validSince, bool disabled})> _lookup(
    String uid,
    DateTime now,
  ) async {
    final http.Response r = await _client.post(
      endpoint.resolve('projects/$projectId/accounts:lookup'),
      headers: <String, String>{'content-type': 'application/json'},
      body: jsonEncode(<String, Object?>{
        'localId': <String>[uid],
      }),
    );
    if (r.statusCode != 200) {
      throw StateError('accounts:lookup answered ${r.statusCode}');
    }
    final Object? users = (jsonDecode(r.body) as Map<String, Object?>)['users'];
    if (users is! List || users.isEmpty) {
      throw const TokenRejected('account deleted');
    }
    final Map<String, Object?> u = users.first as Map<String, Object?>;
    final int since = int.tryParse('${u['validSince'] ?? 0}') ?? 0;
    return (
      at: now,
      validSince: DateTime.fromMillisecondsSinceEpoch(
        since * 1000,
        isUtc: true,
      ),
      disabled: u['disabled'] == true,
    );
  }
}
