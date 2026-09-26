import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:http/http.dart' as http;

/// A caller whose Firebase ID token checked out.
class VerifiedUser {
  const VerifiedUser({
    required this.uid,
    required this.roles,
    required this.authTime,
    required this.issuedAt,
    this.email,
  });

  final String uid;
  final String? email;

  /// The `roles` custom claim: strings only, anything else ignored.
  final Set<String> roles;

  /// When the person signed in, which revocation is judged against.
  final DateTime authTime;
  final DateTime issuedAt;
}

/// Why a token was refused. The reason is for the log; the caller only ever
/// learns that it was not accepted.
class TokenRejected implements Exception {
  const TokenRejected(this.reason);
  final String reason;
  @override
  String toString() => 'token rejected: $reason';
}

/// Google's current signing keys for Firebase ID tokens, by key id.
abstract interface class SigningKeys {
  /// The keys, refetched early when [unknownKeyId] says a token named one the
  /// cached set does not have.
  Future<Map<String, RSAPublicKey>> current({bool unknownKeyId = false});
}

/// Verifies Firebase ID tokens as Firebase documents for third-party JWT
/// libraries: RS256, a known key id, the signature, and every claim.
///
/// The library checks the signature and nothing else; the claims are checked
/// here, explicitly, so each rule is one line that a test names.
class FirebaseTokenVerifier {
  FirebaseTokenVerifier({
    required this.projectId,
    required this.keys,
    DateTime Function()? clock,
    this.allowUnsigned = false,
  }) : _clock = clock ?? DateTime.now;

  final String projectId;
  final SigningKeys keys;
  final DateTime Function() _clock;

  /// Only for the Auth emulator, whose tokens are unsigned. `buildApi`
  /// refuses to enable it on Cloud Run.
  final bool allowUnsigned;

  /// Tolerance for clocks that disagree by a little.
  static const Duration skew = Duration(minutes: 1);

  Future<VerifiedUser> verify(String token) async {
    final List<String> parts = token.split('.');
    if (parts.length != 3) throw const TokenRejected('not a JWT');
    final Map<String, Object?> header = _json(parts[0], 'header');
    final Map<String, Object?> claims;

    if (header['alg'] == 'none' && allowUnsigned) {
      claims = _json(parts[1], 'payload');
    } else {
      if (header['alg'] != 'RS256') {
        throw TokenRejected('algorithm ${header['alg']}');
      }
      final Object? kid = header['kid'];
      if (kid is! String) throw const TokenRejected('no key id');
      final RSAPublicKey? key =
          (await keys.current())[kid] ??
          (await keys.current(unknownKeyId: true))[kid];
      if (key == null) throw TokenRejected('unknown key id $kid');
      try {
        JWT.verify(
          token,
          key,
          checkHeaderType: false,
          checkExpiresIn: false,
          checkNotBefore: false,
        );
      } on JWTException catch (error) {
        throw TokenRejected('signature: ${error.message}');
      }
      claims = _json(parts[1], 'payload');
    }

    final DateTime now = _clock();
    final DateTime exp = _time(claims, 'exp');
    final DateTime iat = _time(claims, 'iat');
    final DateTime authTime = _time(claims, 'auth_time');
    if (!exp.isAfter(now.subtract(skew))) throw const TokenRejected('expired');
    if (iat.isAfter(now.add(skew))) {
      throw const TokenRejected('issued in the future');
    }
    if (authTime.isAfter(now.add(skew))) {
      throw const TokenRejected('signed in in the future');
    }
    if (claims['aud'] != projectId) {
      throw TokenRejected('audience ${claims['aud']}');
    }
    if (claims['iss'] != 'https://securetoken.google.com/$projectId') {
      throw TokenRejected('issuer ${claims['iss']}');
    }
    final Object? sub = claims['sub'];
    if (sub is! String || sub.isEmpty || sub.length > 128) {
      throw const TokenRejected('subject');
    }

    final Object? roles = claims['roles'];
    return VerifiedUser(
      uid: sub,
      email: claims['email'] is String ? claims['email']! as String : null,
      roles: roles is List
          ? <String>{
              for (final Object? r in roles)
                if (r is String && r.isNotEmpty) r,
            }
          : const <String>{},
      authTime: authTime,
      issuedAt: iat,
    );
  }

  static Map<String, Object?> _json(String part, String what) {
    try {
      final Object? decoded = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(part))),
      );
      if (decoded is Map<String, Object?>) return decoded;
    } on FormatException {
      // Falls through to the refusal.
    }
    throw TokenRejected('unreadable $what');
  }

  static DateTime _time(Map<String, Object?> claims, String name) {
    final Object? value = claims[name];
    if (value is! int) throw TokenRejected('no $name');
    return DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true);
  }
}

/// Google's published certificates for Firebase ID tokens, cached for as
/// long as Google's `Cache-Control` says.
///
/// Google rotates them. Fetching per request would add a round trip to every
/// call; never refetching would refuse every token after a rotation. A key id
/// not in the cached set triggers one early refetch, at most once a minute,
/// so a rotation is picked up without letting junk tokens cause a fetch each.
class GoogleSigningKeys implements SigningKeys {
  GoogleSigningKeys(this._client, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static final Uri certificates = Uri.parse(
    'https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com',
  );

  final http.Client _client;
  final DateTime Function() _clock;
  Map<String, RSAPublicKey> _keys = const <String, RSAPublicKey>{};
  DateTime _expires = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _fetched = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void>? _refreshing;

  static const Duration _earliestRefetch = Duration(minutes: 1);

  @override
  Future<Map<String, RSAPublicKey>> current({bool unknownKeyId = false}) async {
    final DateTime now = _clock();
    final bool stale = now.isAfter(_expires);
    final bool rotated =
        unknownKeyId && now.difference(_fetched) > _earliestRefetch;
    if (stale || rotated) await (_refreshing ??= _refresh());
    return _keys;
  }

  Future<void> _refresh() async {
    try {
      final http.Response response = await _client.get(certificates);
      if (response.statusCode != 200) {
        throw StateError('Google certificates answered ${response.statusCode}');
      }
      final Map<String, Object?> pems =
          jsonDecode(response.body) as Map<String, Object?>;
      _keys = <String, RSAPublicKey>{
        for (final MapEntry<String, Object?> e in pems.entries)
          e.key: RSAPublicKey.cert('${e.value}'),
      };
      final RegExpMatch? maxAge = RegExp(
        r'max-age=(\d+)',
      ).firstMatch(response.headers['cache-control'] ?? '');
      _fetched = _clock();
      _expires = _clock().add(
        Duration(seconds: int.tryParse(maxAge?.group(1) ?? '') ?? 3600),
      );
    } finally {
      _refreshing = null;
    }
  }
}
