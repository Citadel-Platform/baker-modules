import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../access/access.dart';
import '../access/session.dart';
import '../design/tokens.dart';
import '../foundation/failure.dart';
import '../foundation/layout.dart';
import 'routes.dart';

/// Navigation and layout around every signed-in screen.
///
/// Bottom navigation on a phone, a rail on a tablet, a labelled rail on a
/// desktop. Only destinations the person may open are shown: a menu full of
/// doors that say "not allowed" is noise, and the guard still stands behind
/// each one for anybody who types the address.
class AppShell extends ConsumerWidget {
  const AppShell({required this.location, required this.child, super.key});

  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Session? session = ref.watch(sessionProvider).value;
    final List<AppRoute> destinations = <AppRoute>[
      for (final AppRoute route in appRoutes)
        if (route.inNavigation &&
            decideAccess(route.access, session) == AccessDecision.allow)
          route,
    ];
    final int selected = _selectedIndex(destinations);
    void go(int index) => context.go(destinations[index].path);

    final WindowSize size = WindowSize.of(context);
    final Widget body = SafeArea(child: child);

    if (size == WindowSize.compact || destinations.length < 2) {
      return Scaffold(
        appBar: AppBar(
          title: Text(selected >= 0 ? destinations[selected].title : ''),
          actions: <Widget>[_AccountMenu(session: session)],
        ),
        body: body,
        bottomNavigationBar: destinations.length >= 2
            ? NavigationBar(
                selectedIndex: selected < 0 ? 0 : selected,
                onDestinationSelected: go,
                destinations: <NavigationDestination>[
                  for (final AppRoute route in destinations)
                    NavigationDestination(
                      icon: Icon(route.icon ?? Icons.circle_outlined),
                      label: route.title,
                    ),
                ],
              )
            : null,
      );
    }

    final bool extended = size == WindowSize.expanded;
    return Scaffold(
      body: Row(
        children: <Widget>[
          NavigationRail(
            extended: extended,
            selectedIndex: selected < 0 ? null : selected,
            onDestinationSelected: go,
            labelType: extended ? null : NavigationRailLabelType.all,
            trailing: Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: AppTokens.space4),
                  child: _AccountMenu(session: session),
                ),
              ),
            ),
            destinations: <NavigationRailDestination>[
              for (final AppRoute route in destinations)
                NavigationRailDestination(
                  icon: Icon(route.icon ?? Icons.circle_outlined),
                  label: Text(route.title),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: body),
        ],
      ),
    );
  }

  /// The destination [location] is in: an exact match, else the longest path
  /// it sits under (`/clients/42` highlights `/clients`).
  int _selectedIndex(List<AppRoute> destinations) {
    int best = -1;
    int bestLength = -1;
    for (int i = 0; i < destinations.length; i++) {
      final String path = destinations[i].path;
      final bool under =
          location == path || (path != '/' && location.startsWith('$path/'));
      if (under && path.length > bestLength) {
        best = i;
        bestLength = path.length;
      }
    }
    return best;
  }
}

class _AccountMenu extends ConsumerWidget {
  const _AccountMenu({required this.session});
  final Session? session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Session? s = session;
    if (s is! SignedIn) return const SizedBox.shrink();
    final SignInActions? actions = ref.watch(signInActionsProvider);
    return PopupMenuButton<void>(
      tooltip: s.label,
      icon: const Icon(Icons.account_circle_outlined),
      itemBuilder: (BuildContext context) => <PopupMenuEntry<void>>[
        PopupMenuItem<void>(enabled: false, child: Text(s.label)),
        if (actions != null)
          PopupMenuItem<void>(
            onTap: () async {
              try {
                await actions.signOut();
              } on Object catch (error) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(describeFailure(error))),
                  );
                }
              }
            },
            child: const Text('Sign out'),
          ),
      ],
    );
  }
}
