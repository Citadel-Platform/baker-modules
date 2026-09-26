import 'package:api/api.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late ({pc.RSAPublicKey public, pc.RSAPrivateKey private}) key;
  late ({pc.RSAPublicKey public, pc.RSAPrivateKey private}) other;
  late FakeKeys keys;
  late FirebaseTokenVerifier verifier;

  setUpAll(() {
    key = rsaPair();
    other = rsaPair();
  });

  setUp(() {
    keys = FakeKeys(<String, RSAPublicKey>{'k1': RSAPublicKey.raw(key.public)});
    verifier = FirebaseTokenVerifier(projectId: project, keys: keys);
  });

  Future<void> refused(String token, String reason) => expectLater(
    verifier.verify(token),
    throwsA(
      isA<TokenRejected>().having(
        (TokenRejected r) => r.reason,
        'reason',
        contains(reason),
      ),
    ),
  );

  test('a good token gives the person and their roles', () async {
    final VerifiedUser u = await verifier.verify(
      firebaseToken(key.private, roles: <Object?>['admin', 3, '']),
    );
    expect(u.uid, 'u1');
    expect(u.email, 'u1@example.com');
    expect(u.roles, <String>{'admin'});
  });

  test('a token signed by another key is refused', () async {
    await refused(firebaseToken(other.private), 'signature');
  });

  test(
    'HS256 "signed" with the public key is refused (algorithm confusion)',
    () async {
      final String forged = JWT(
        <String, Object?>{'sub': 'u1', 'aud': project},
        header: <String, Object?>{'kid': 'k1'},
      ).sign(SecretKey('${key.public.modulus}'), algorithm: JWTAlgorithm.HS256);
      await refused(forged, 'algorithm');
    },
  );

  test(
    'an unsigned token is refused unless the emulator is configured',
    () async {
      final int t = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final String unsigned =
          '${b64(<String, Object?>{'alg': 'none'})}.${b64(<String, Object?>{'iss': 'https://securetoken.google.com/$project', 'aud': project, 'sub': 'u1', 'iat': t, 'exp': t + 60, 'auth_time': t})}.';
      await refused(unsigned, 'algorithm');
      final FirebaseTokenVerifier emulator = FirebaseTokenVerifier(
        projectId: project,
        keys: keys,
        allowUnsigned: true,
      );
      expect((await emulator.verify(unsigned)).uid, 'u1');
    },
  );

  test('each claim is checked', () async {
    final DateTime now = DateTime.now();
    await refused(
      firebaseToken(key.private, now: now.subtract(const Duration(hours: 2))),
      'expired',
    );
    await refused(
      firebaseToken(key.private, now: now.add(const Duration(minutes: 10))),
      'future',
    );
    await refused(firebaseToken(key.private, aud: 'someone-else'), 'audience');
    await refused(
      firebaseToken(key.private, iss: 'https://evil.example/$project'),
      'issuer',
    );
    await refused(firebaseToken(key.private, sub: ''), 'subject');
    await refused(firebaseToken(key.private, sub: 'x' * 129), 'subject');
  });

  test('a minute of clock skew is tolerated, not more', () async {
    final DateTime now = DateTime.now();
    await verifier.verify(
      firebaseToken(key.private, now: now.add(const Duration(seconds: 30))),
    );
    await refused(
      firebaseToken(key.private, now: now.add(const Duration(minutes: 2))),
      'future',
    );
  });

  test('an unknown key id asks for fresh keys once, then refuses', () async {
    await refused(firebaseToken(key.private, kid: 'rotated'), 'unknown key id');
    expect(keys.refetches, 1);
    keys.keys = <String, RSAPublicKey>{'rotated': RSAPublicKey.raw(key.public)};
    expect(
      (await verifier.verify(firebaseToken(key.private, kid: 'rotated'))).uid,
      'u1',
    );
  });

  test('garbage is refused, not thrown as something else', () async {
    for (final String junk in <String>['', 'a.b', 'a.b.c', '!!!.???.***']) {
      await expectLater(verifier.verify(junk), throwsA(isA<TokenRejected>()));
    }
  });
}
