import 'package:flutter/material.dart';

import 'design/tokens.dart';
import 'shell.dart';

/// The application.
///
/// Theming comes from the design system's tokens rather than from a palette
/// written here, so a client application and the Citadel console age together
/// instead of drifting into two half-similar looks.
class ClientApp extends StatelessWidget {
  const ClientApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Client',
      debugShowCheckedModeBanner: false,
      theme: appTheme(),
      home: const AppShell(),
    );
  }
}
