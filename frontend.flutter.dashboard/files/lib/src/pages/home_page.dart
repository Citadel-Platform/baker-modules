import 'package:flutter/material.dart';

import '../design/primitives.dart';
import '../design/states.dart';

/// The first page. Empty until the client's own screens are built.
///
/// Deliberately nothing but an empty state: a starting application with
/// sample customers and invented charts is one somebody demonstrates by
/// accident.
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) => const AppPage(
    title: 'Home',
    child: EmptyState(title: 'Nothing here yet'),
  );
}
