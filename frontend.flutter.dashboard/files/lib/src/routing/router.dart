import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../access/access.dart';
import '../access/session.dart';
import '../pages/system_pages.dart';
import 'routes.dart';
import 'shell.dart';

/// Paths the guard itself sends people to. Public, and out of the navigation.
abstract final class SystemPaths {
  static const String signIn = '/sign-in';
  static const String forbidden = '/forbidden';
  static const String noSignIn = '/no-sign-in';
  static const String starting = '/starting';
}

/// Where the guard sends a request for [access] at [location], or null to let
/// it through. Separate from the router so it can be tested exhaustively.
String? guard(Access access, Session? session, Uri location) {
  final String from = Uri.encodeComponent(location.toString());
  return switch (decideAccess(access, session)) {
    AccessDecision.allow => null,
    AccessDecision.pending => '${SystemPaths.starting}?from=$from',
    AccessDecision.signIn => '${SystemPaths.signIn}?from=$from',
    AccessDecision.forbidden => SystemPaths.forbidden,
    AccessDecision.noSignIn => SystemPaths.noSignIn,
  };
}

/// The router, rebuilt from nothing only once; the session changing
/// re-runs every guard through [GoRouter.refresh].
final Provider<GoRouter> routerProvider = Provider<GoRouter>((Ref ref) {
  // A session that failed to load is treated as signed out: deny, and offer
  // sign-in again. Waiting on it would leave the app on "Starting" for ever.
  Session? current() {
    final AsyncValue<Session> session = ref.read(sessionProvider);
    if (session.hasValue) return session.requireValue;
    if (session.hasError) return const SignedOut();
    return null;
  }

  GoRoute guarded(AppRoute route) => GoRoute(
    path: route.path,
    redirect: (_, GoRouterState state) =>
        guard(route.access, current(), state.uri),
    builder: route.builder,
  );

  final GoRouter router = GoRouter(
    initialLocation: '/',
    routes: <RouteBase>[
      ShellRoute(
        builder: (_, GoRouterState state, Widget child) =>
            AppShell(location: state.uri.path, child: child),
        routes: <RouteBase>[
          for (final AppRoute route in appRoutes) guarded(route),
          GoRoute(
            path: SystemPaths.forbidden,
            builder: (_, _) => const ForbiddenPage(),
          ),
        ],
      ),
      GoRoute(
        path: SystemPaths.signIn,
        // Somebody already signed in has nothing to do here.
        redirect: (_, GoRouterState state) => current() is SignedIn
            ? safeReturnPath(state.uri.queryParameters['from'])
            : null,
        builder: (_, GoRouterState state) => SignInPage(
          returnTo: safeReturnPath(state.uri.queryParameters['from']),
        ),
      ),
      GoRoute(
        path: SystemPaths.noSignIn,
        builder: (_, _) => const NoSignInPage(),
      ),
      GoRoute(
        path: SystemPaths.starting,
        // Once the session is known, go where the person was going; that
        // route's own guard then decides.
        redirect: (_, GoRouterState state) => current() == null
            ? null
            : safeReturnPath(state.uri.queryParameters['from']),
        builder: (_, _) => const StartingPage(),
      ),
    ],
    errorBuilder: (_, GoRouterState state) => const NotFoundPage(),
  );

  ref.listen(sessionProvider, (_, _) => router.refresh());
  ref.onDispose(router.dispose);
  return router;
});
