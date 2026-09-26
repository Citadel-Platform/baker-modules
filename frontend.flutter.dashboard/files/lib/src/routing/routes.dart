import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../access/access.dart';
import '../pages/home_page.dart';

/// One screen of the application, and who may open it.
///
/// [access] is required: a route nobody thought about is a route anybody can
/// open. The test in `test/routes_test.dart` sweeps this table and fails on a
/// public page that is not on its short list.
class AppRoute {
  const AppRoute({
    required this.path,
    required this.title,
    required this.access,
    required this.builder,
    this.icon,
    this.inNavigation = true,
  });

  /// Absolute, starting with `/`.
  final String path;
  final String title;
  final IconData? icon;
  final Access access;
  final Widget Function(BuildContext context, GoRouterState state) builder;

  /// Whether it is a destination in the navigation. Detail pages are not.
  final bool inNavigation;
}

/// The application's screens. Add a client's pages here, each with its rule.
///
/// Roles are the client's own vocabulary (`admin`, `staff`, …) and are set as
/// custom claims by a server; see `backend.firebase.auth`.
final List<AppRoute> appRoutes = <AppRoute>[
  AppRoute(
    path: '/',
    title: 'Home',
    icon: Icons.space_dashboard_outlined,
    access: const Access.signedIn(),
    builder: (_, _) => const HomePage(),
  ),
];
