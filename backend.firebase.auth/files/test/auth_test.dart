import 'package:{{baker.packageName}}/src/access/session.dart';
import 'package:{{baker.packageName}}/src/auth/firebase_session.dart';
import 'package:{{baker.packageName}}/src/auth/firebase_sign_in.dart';
import 'package:{{baker.packageName}}/src/foundation/failure.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mock_exceptions/mock_exceptions.dart';

import '../tool/src/roles_admin.dart';

void main() {
  group('roles from claims', () {
    test('strings only; anything malformed grants nothing', () {
      expect(
        rolesFromClaims(<String, dynamic>{
          'roles': <Object?>['admin', 'staff'],
        }),
        <String>{'admin', 'staff'},
      );
      expect(rolesFromClaims(<String, dynamic>{'roles': 'admin'}), isEmpty);
      expect(
        rolesFromClaims(<String, dynamic>{
          'roles': <Object?>[1, null, '', 'ok'],
        }),
        <String>{'ok'},
      );
      expect(rolesFromClaims(null), isEmpty);
      expect(
        rolesFromClaims(<String, dynamic>{
          'role': <String>['admin'],
        }),
        isEmpty,
      );
    });
  });

  group('the session', () {
    test('signed out, then signed in with the token\'s roles', () async {
      final MockFirebaseAuth auth = MockFirebaseAuth(
        mockUser: MockUser(
          uid: 'u1',
          email: 'a@example.com',
          customClaim: <String, dynamic>{
            'roles': <String>['staff'],
          },
        ),
      );
      final List<Session> seen = <Session>[];
      final sub = firebaseSessions(auth).listen(seen.add);
      await pumpEventQueue();
      expect(seen.last, isA<SignedOut>());

      await FirebaseSignIn(auth).options.single.signIn();
      await pumpEventQueue();
      final SignedIn signedIn = seen.last as SignedIn;
      expect(signedIn.uid, 'u1');
      expect(signedIn.roles, <String>{'staff'});

      await FirebaseSignIn(auth).signOut();
      await pumpEventQueue();
      expect(seen.last, isA<SignedOut>());
      await sub.cancel();
    });
  });

  group('sign-in failures read as sentences', () {
    AppFailure fail(String code) =>
        signInFailure(FirebaseAuthException(code: code, message: 'raw $code'));

    test('each kind says what happened and nothing raw', () {
      expect(fail('popup-closed-by-user').message, 'Sign-in was cancelled.');
      expect(fail('network-request-failed'), isA<Unavailable>());
      expect(fail('network-request-failed').retryable, isTrue);
      expect(fail('user-disabled'), isA<NotPermitted>());
      expect(fail('operation-not-allowed'), isA<NotConfigured>());
      expect(fail('unauthorized-domain'), isA<NotConfigured>());
      for (final String code in <String>['internal-error', 'something-new']) {
        expect(fail(code).message, isNot(contains('raw')));
      }
    });

    test('a refused sign-in surfaces as an AppFailure', () async {
      final MockFirebaseAuth auth = MockFirebaseAuth();
      whenCalling(
        Invocation.method(#signInWithProvider, null),
      ).on(auth).thenThrow(FirebaseAuthException(code: 'user-disabled'));
      await expectLater(
        FirebaseSignIn(auth).options.single.signIn(),
        throwsA(isA<NotPermitted>()),
      );
    });
  });

  group('claims the roles tool will write', () {
    test('keeps other claims, replaces roles, sorts them', () {
      expect(
        RolesAdmin.claimsWith(
          <String, Object?>{
            'tenant': 't1',
            'roles': <String>['old'],
          },
          <String>{'staff', 'admin'},
        ),
        <String, Object?>{
          'tenant': 't1',
          'roles': <String>['admin', 'staff'],
        },
      );
      expect(
        RolesAdmin.claimsWith(<String, Object?>{
          'roles': <String>['a'],
        }, <String>{}),
        isEmpty,
        reason: 'no roles removes the claim rather than writing []',
      );
    });

    test('refuses malformed names, too many roles, and oversized claims', () {
      for (final String bad in <String>['Admin', 'a b', '1st', 'x' * 33, '']) {
        expect(
          () => RolesAdmin.claimsWith(<String, Object?>{}, <String>{bad}),
          throwsFormatException,
          reason: bad,
        );
      }
      expect(
        () => RolesAdmin.claimsWith(<String, Object?>{}, <String>{
          for (int i = 0; i < 21; i++) 'r$i',
        }),
        throwsFormatException,
      );
      expect(
        () => RolesAdmin.claimsWith(
          <String, Object?>{'blob': 'x' * 990},
          <String>{'a'},
        ),
        throwsFormatException,
      );
    });
  });
}
