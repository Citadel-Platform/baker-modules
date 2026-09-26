import 'package:api/api.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:test/test.dart';

import 'support.dart';

/// Google-signed OIDC tokens, as Cloud Tasks, Scheduler and Eventarc send
/// them. No test covered this verifier until 26/09/26, when a live deployment
/// found `alsoAccept` was never consulted and Eventarc's pushes, signed for
/// an address Terraform cannot know, were all refused.
void main() {
  late ({pc.RSAPublicKey public, pc.RSAPrivateKey private}) key;
  late FakeKeys keys;

  setUpAll(() => key = rsaPair());
  setUp(
    () => keys = FakeKeys(<String, RSAPublicKey>{
      'k1': RSAPublicKey.raw(key.public),
    }),
  );

  String token(
    String aud, {
    String email = 'caller@p.iam.gserviceaccount.com',
  }) {
    final int t = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return JWT(
      <String, Object?>{
        'iss': 'https://accounts.google.com',
        'aud': aud,
        'sub': '1',
        'iat': t,
        'exp': t + 3600,
        'email': email,
        'email_verified': true,
      },
      header: <String, Object?>{'kid': 'k1'},
    ).sign(
      RSAPrivateKey.raw(key.private),
      algorithm: JWTAlgorithm.RS256,
      noIssueAt: true,
    );
  }

  GoogleOidcVerifier verifier() => GoogleOidcVerifier(
    audience: 'app-api-internal',
    keys: keys,
    alsoAccept: <String>{'https://app-api-123.us-central1.run.app'},
  );

  final Uri pushedTo = Uri.parse(
    'https://app-api-abc123-uc.a.run.app/internal/sheets/changed',
  );

  Future<void> refused(Future<String> f) => expectLater(
    f,
    throwsA(
      isA<TokenRejected>().having(
        (TokenRejected r) => r.reason,
        'reason',
        contains('audience'),
      ),
    ),
  );

  test(
    'the configured audience, as Cloud Tasks and Scheduler send it',
    () async {
      expect(
        await verifier().verify(token('app-api-internal')),
        'caller@p.iam.gserviceaccount.com',
      );
    },
  );

  test('an audience in alsoAccept is accepted', () async {
    expect(
      await verifier().verify(token('https://app-api-123.us-central1.run.app')),
      'caller@p.iam.gserviceaccount.com',
    );
  });

  test("Eventarc's push: the address it was sent to, path and all", () async {
    final GoogleOidcVerifier v = verifier();
    expect(
      await v.verify(token(pushedTo.toString()), addressedTo: pushedTo),
      isNotEmpty,
    );
    expect(
      await v.verify(
        token('https://app-api-abc123-uc.a.run.app'),
        addressedTo: pushedTo,
      ),
      isNotEmpty,
      reason: 'the origin alone, as some push subscriptions set it',
    );
  });

  test(
    'a token for another service or another route is still refused',
    () async {
      final GoogleOidcVerifier v = verifier();
      await refused(
        v.verify(
          token(
            'https://other-api-abc123-uc.a.run.app/internal/sheets/changed',
          ),
          addressedTo: pushedTo,
        ),
      );
      await refused(
        v.verify(
          token('https://app-api-abc123-uc.a.run.app/internal/mail/send'),
          addressedTo: pushedTo,
        ),
      );
      await refused(v.verify(token(pushedTo.toString())));
    },
  );
}
