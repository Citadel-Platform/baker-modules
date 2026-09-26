import 'package:flutter_riverpod/misc.dart';
// baker:imports

/// Connects modules to the application, before the first frame.
///
/// Modules that need starting (a sign-in, a database) add themselves at the
/// `baker:` lines when the application is bootstrapped. In a build with none,
/// the list is empty and the screens say "not connected" rather than
/// pretending.
Future<List<Override>> configure() async {
  return <Override>[
    // baker:overrides
  ];
}
