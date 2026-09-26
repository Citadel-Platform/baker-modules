import 'dart:async';
import 'dart:math' as math;

import 'package:{{baker.packageName}}/src/access/session.dart';
import 'package:{{baker.packageName}}/src/app.dart';
import 'package:{{baker.packageName}}/src/design/tokens.dart';
import 'package:{{baker.packageName}}/src/routing/router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _Actions implements SignInActions {
  _Actions(this.sessions);
  final StreamController<Session> sessions;
  int signOuts = 0;

  @override
  List<SignInOption> get options => <SignInOption>[
    SignInOption(
      label: 'Continue',
      icon: Icons.login,
      signIn: () async => sessions.add(
        const SignedIn(
          uid: 'u1',
          email: 'a@example.com',
          roles: <String>{'staff'},
        ),
      ),
    ),
  ];

  @override
  Future<void> signOut() async {
    signOuts++;
    sessions.add(const SignedOut());
  }
}

void main() {
  testWidgets('a fresh build says it has no sign-in, and shows nothing else', (
    WidgetTester t,
  ) async {
    await t.pumpWidget(const ProviderScope(child: ClientApp()));
    await t.pumpAndSettle();
    expect(find.text('No sign-in connected'), findsOneWidget);
  });

  testWidgets('signed out, a deep link goes to sign-in and back after', (
    WidgetTester t,
  ) async {
    final StreamController<Session> sessions = StreamController<Session>();
    addTearDown(sessions.close);
    final _Actions actions = _Actions(sessions);
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        sessionProvider.overrideWith((Ref ref) => sessions.stream),
        signInActionsProvider.overrideWithValue(actions),
      ],
    );
    addTearDown(container.dispose);
    await t.pumpWidget(
      UncontrolledProviderScope(container: container, child: const ClientApp()),
    );
    await t.pump();
    // The session is not known yet: nothing is shown as if it were.
    expect(find.text('Home'), findsNothing);

    sessions.add(const SignedOut());
    await t.pumpAndSettle();
    final GoRouter router = container.read(routerProvider);
    expect(
      router.routerDelegate.currentConfiguration.uri.path,
      SystemPaths.signIn,
    );

    await t.tap(find.text('Continue'));
    await t.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path, '/');
    expect(find.text('Nothing here yet'), findsOneWidget);
  });

  testWidgets('a session that fails to load is treated as signed out', (
    WidgetTester t,
  ) async {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        sessionProvider.overrideWith(
          (Ref ref) => Stream<Session>.error(StateError('token service down')),
        ),
      ],
    );
    addTearDown(container.dispose);
    await t.pumpWidget(
      UncontrolledProviderScope(container: container, child: const ClientApp()),
    );
    await t.pumpAndSettle();
    expect(
      container
          .read(routerProvider)
          .routerDelegate
          .currentConfiguration
          .uri
          .path,
      SystemPaths.signIn,
    );
  });

  test('text colours are legible on every surface, in both modes', () {
    // WCAG 2.x relative luminance and contrast ratio.
    double luminance(Color c) {
      double lin(double v) => v <= 0.03928
          ? v / 12.92
          : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
      return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
    }

    double contrast(Color a, Color b) {
      final double la = luminance(a) + 0.05;
      final double lb = luminance(b) + 0.05;
      return la > lb ? la / lb : lb / la;
    }

    for (final AppColors c in <AppColors>[AppColors.light, AppColors.dark]) {
      for (final Color ground in <Color>[
        c.background,
        c.surface,
        c.surfaceRaised,
      ]) {
        for (final (String name, Color text) in <(String, Color)>[
          ('textPrimary', c.textPrimary),
          ('textSecondary', c.textSecondary),
          ('textMuted', c.textMuted),
          ('accentText', c.accentText),
          ('danger', c.danger),
        ]) {
          expect(
            contrast(text, ground),
            greaterThanOrEqualTo(4.5),
            reason:
                '$name on $ground (${c == AppColors.light ? 'light' : 'dark'})',
          );
        }
      }
    }
  });
}
