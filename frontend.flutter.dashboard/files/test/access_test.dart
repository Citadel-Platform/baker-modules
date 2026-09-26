import 'package:{{baker.packageName}}/src/access/access.dart';
import 'package:{{baker.packageName}}/src/access/session.dart';
import 'package:{{baker.packageName}}/src/routing/router.dart';
import 'package:{{baker.packageName}}/src/routing/routes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the route table', () {
    // Public pages are the guard's own (sign-in, errors), which live outside
    // this table. A client page made public is a decision somebody should
    // have to write down here.
    const Set<String> publicOnPurpose = <String>{};

    test('no page is public unless it is on the short list', () {
      for (final AppRoute route in appRoutes) {
        if (route.access is PublicAccess) {
          expect(
            publicOnPurpose,
            contains(route.path),
            reason: '${route.path} is public',
          );
        }
      }
    });

    test('paths are absolute and unique, and clear of the guard\'s own', () {
      final Set<String> seen = <String>{};
      for (final AppRoute route in appRoutes) {
        expect(route.path, startsWith('/'));
        expect(seen.add(route.path), isTrue, reason: 'duplicate ${route.path}');
        expect(<String>[
          SystemPaths.signIn,
          SystemPaths.forbidden,
          SystemPaths.noSignIn,
          SystemPaths.starting,
        ], isNot(contains(route.path)));
      }
    });
  });

  group('decideAccess', () {
    const SignedIn staff = SignedIn(uid: 'u1', roles: <String>{'staff'});
    const SignedIn nobody = SignedIn(uid: 'u2', roles: <String>{});

    test(
      'public is open to everyone, including before the session is known',
      () {
        for (final Session? s in <Session?>[
          null,
          const NoSignIn(),
          const SignedOut(),
          staff,
        ]) {
          expect(decideAccess(const Access.public(), s), AccessDecision.allow);
        }
      },
    );

    test('an unknown session waits rather than guessing', () {
      expect(
        decideAccess(const Access.signedIn(), null),
        AccessDecision.pending,
      );
    });

    test('no sign-in, signed out, and signed in each get their own answer', () {
      expect(
        decideAccess(const Access.signedIn(), const NoSignIn()),
        AccessDecision.noSignIn,
      );
      expect(
        decideAccess(const Access.signedIn(), const SignedOut()),
        AccessDecision.signIn,
      );
      expect(
        decideAccess(const Access.signedIn(), nobody),
        AccessDecision.allow,
      );
    });

    test('a role rule admits any one of its roles and nobody else', () {
      const Access admins = Access.roles(<String>{'admin', 'owner'});
      expect(decideAccess(admins, staff), AccessDecision.forbidden);
      expect(decideAccess(admins, nobody), AccessDecision.forbidden);
      expect(
        decideAccess(
          admins,
          const SignedIn(uid: 'u3', roles: <String>{'owner'}),
        ),
        AccessDecision.allow,
      );
      expect(decideAccess(admins, const SignedOut()), AccessDecision.signIn);
    });
  });

  group('safeReturnPath', () {
    test('keeps a local path with its query', () {
      expect(safeReturnPath('/clients/42?tab=notes'), '/clients/42?tab=notes');
    });

    test('refuses anything that could leave the app', () {
      for (final String hostile in <String>[
        'https://evil.example/',
        '//evil.example/path',
        r'/\evil.example',
        'javascript:alert(1)',
        'clients',
        '',
      ]) {
        expect(safeReturnPath(hostile), '/', reason: hostile);
      }
      expect(safeReturnPath(null), '/');
    });
  });

  group('guard', () {
    final Uri at = Uri.parse('/clients/42?tab=notes');

    test('sends a signed-out person to sign in and remembers where', () {
      final String? to = guard(const Access.signedIn(), const SignedOut(), at);
      final Uri uri = Uri.parse(to!);
      expect(uri.path, SystemPaths.signIn);
      expect(uri.queryParameters['from'], '/clients/42?tab=notes');
    });

    test('waits on an unknown session, and lets an allowed one through', () {
      expect(
        Uri.parse(guard(const Access.signedIn(), null, at)!).path,
        SystemPaths.starting,
      );
      expect(
        guard(
          const Access.signedIn(),
          const SignedIn(uid: 'u', roles: <String>{}),
          at,
        ),
        isNull,
      );
    });
  });
}
