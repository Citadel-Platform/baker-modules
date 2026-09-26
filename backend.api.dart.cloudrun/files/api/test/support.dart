import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:api/api.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:pointycastle/export.dart' as pc;

/// A real RSA key pair, made in memory for the tests; nothing is stored.
({pc.RSAPublicKey public, pc.RSAPrivateKey private}) rsaPair() {
  final pc.SecureRandom random = pc.FortunaRandom()
    ..seed(
      pc.KeyParameter(
        Uint8List.fromList(
          List<int>.generate(32, (_) => Random.secure().nextInt(256)),
        ),
      ),
    );
  final pc.RSAKeyGenerator generator = pc.RSAKeyGenerator()
    ..init(
      pc.ParametersWithRandom(
        pc.RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64),
        random,
      ),
    );
  final pc.AsymmetricKeyPair<pc.PublicKey, pc.PrivateKey> pair = generator
      .generateKeyPair();
  return (
    public: pair.publicKey as pc.RSAPublicKey,
    private: pair.privateKey as pc.RSAPrivateKey,
  );
}

/// Keys handed to a verifier, counting how often it asks.
class FakeKeys implements SigningKeys {
  FakeKeys(this.keys);
  Map<String, RSAPublicKey> keys;
  int refetches = 0;

  @override
  Future<Map<String, RSAPublicKey>> current({bool unknownKeyId = false}) async {
    if (unknownKeyId) refetches++;
    return keys;
  }
}

const String project = 'demo-api';

/// A Firebase-shaped ID token signed with [key].
String firebaseToken(
  pc.RSAPrivateKey key, {
  String kid = 'k1',
  String sub = 'u1',
  Object? roles,
  DateTime? now,
  Duration expiresIn = const Duration(hours: 1),
  DateTime? authTime,
  String aud = project,
  String? iss,
}) {
  final int t = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  return JWT(
    <String, Object?>{
      'iss': iss ?? 'https://securetoken.google.com/$aud',
      'aud': aud,
      'sub': sub,
      'iat': t,
      'exp': t + expiresIn.inSeconds,
      'auth_time':
          (authTime ?? now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000,
      'email': '$sub@example.com',
      'roles': ?roles,
    },
    header: <String, Object?>{'kid': kid},
  ).sign(
    RSAPrivateKey.raw(key),
    algorithm: JWTAlgorithm.RS256,
    noIssueAt: true,
  );
}

String b64(Map<String, Object?> m) =>
    base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
