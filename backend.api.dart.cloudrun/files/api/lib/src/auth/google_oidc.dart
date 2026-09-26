import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart' as pc;

import 'token_verifier.dart';

/// Verifies the OIDC tokens Google Cloud attaches when Cloud Tasks or Cloud
/// Scheduler calls a route: Google's signature, issuer, audience, expiry, and
/// the calling service account's verified email.
class GoogleOidcVerifier {
  GoogleOidcVerifier({
    required this.audience,
    required this.keys,
    this.alsoAccept = const <String>{},
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// What the task or job was told to put in `aud`; set in Terraform.
  final String audience;

  /// Other audiences to accept: Eventarc's push tokens are for the service's
  /// own URL and cannot be given another.
  final Set<String> alsoAccept;
  final SigningKeys keys;
  final DateTime Function() _clock;

  /// The caller's service account email, once everything checks.
  ///
  /// [addressedTo] is where this request arrived, as `https://host/path`.
  /// Eventarc signs its push for the address it delivers to, which is Cloud
  /// Run's hashed legacy URL plus the route's path, an address that only
  /// exists once the service does and so cannot be configured in advance
  /// (seen live 26/09/26: every push refused). A token naming the address it
  /// was actually sent to, or that address's origin, is accepted: one minted
  /// for another service or route names somewhere else, so the audience still
  /// stops a replay, and the caller's identity is checked separately.
  Future<String> verify(String token, {Uri? addressedTo}) async {
    final List<String> parts = token.split('.');
    if (parts.length != 3) throw const TokenRejected('not a JWT');
    final Map<String, Object?> header = _json(parts[0]);
    if (header['alg'] != 'RS256') throw const TokenRejected('algorithm');
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
    final Map<String, Object?> claims = _json(parts[1]);
    final Object? exp = claims['exp'];
    if (exp is! int ||
        !DateTime.fromMillisecondsSinceEpoch(
          exp * 1000,
          isUtc: true,
        ).isAfter(_clock().subtract(FirebaseTokenVerifier.skew))) {
      throw const TokenRejected('expired');
    }
    final Object? iss = claims['iss'];
    if (iss != 'https://accounts.google.com' && iss != 'accounts.google.com') {
      throw TokenRejected('issuer $iss');
    }
    final Object? aud = claims['aud'];
    final Set<String> accepted = <String>{
      audience,
      ...alsoAccept,
      if (addressedTo != null) ...<String>{
        '${addressedTo.scheme}://${addressedTo.authority}',
        '${addressedTo.scheme}://${addressedTo.authority}${addressedTo.path}',
      },
    };
    if (aud is! String || !accepted.contains(aud)) {
      throw TokenRejected('audience $aud');
    }
    final Object? email = claims['email'];
    if (email is! String || claims['email_verified'] != true) {
      throw const TokenRejected('no verified email');
    }
    return email;
  }

  static Map<String, Object?> _json(String part) {
    try {
      final Object? v = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(part))),
      );
      if (v is Map<String, Object?>) return v;
    } on FormatException {
      // Falls through.
    }
    throw const TokenRejected('unreadable');
  }
}

/// Google's OAuth signing keys (JWK), cached per `Cache-Control`, with the
/// same early refetch on an unknown key id as [GoogleSigningKeys].
class GoogleOidcKeys implements SigningKeys {
  GoogleOidcKeys(this._client, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static final Uri jwks = Uri.parse(
    'https://www.googleapis.com/oauth2/v3/certs',
  );

  final http.Client _client;
  final DateTime Function() _clock;
  Map<String, RSAPublicKey> _keys = const <String, RSAPublicKey>{};
  DateTime _expires = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _fetched = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void>? _refreshing;

  @override
  Future<Map<String, RSAPublicKey>> current({bool unknownKeyId = false}) async {
    final DateTime now = _clock();
    if (now.isAfter(_expires) ||
        (unknownKeyId &&
            now.difference(_fetched) > const Duration(minutes: 1))) {
      await (_refreshing ??= _refresh());
    }
    return _keys;
  }

  Future<void> _refresh() async {
    try {
      final http.Response r = await _client.get(jwks);
      if (r.statusCode != 200) {
        throw StateError('Google JWKS answered ${r.statusCode}');
      }
      final List<Object?> keys =
          (jsonDecode(r.body) as Map<String, Object?>)['keys']!
              as List<Object?>;
      _keys = <String, RSAPublicKey>{
        for (final Object? k in keys)
          if (k case {
            'kid': final String kid,
            'kty': 'RSA',
            'n': final String n,
            'e': final String e,
          })
            kid: RSAPublicKey.raw(pc.RSAPublicKey(_int(n), _int(e))),
      };
      final RegExpMatch? maxAge = RegExp(
        r'max-age=(\d+)',
      ).firstMatch(r.headers['cache-control'] ?? '');
      _fetched = _clock();
      _expires = _clock().add(
        Duration(seconds: int.tryParse(maxAge?.group(1) ?? '') ?? 3600),
      );
    } finally {
      _refreshing = null;
    }
  }

  static BigInt _int(String b64) {
    final List<int> bytes = base64Url.decode(base64Url.normalize(b64));
    BigInt v = BigInt.zero;
    for (final int b in bytes) {
      v = (v << 8) | BigInt.from(b);
    }
    return v;
  }
}
