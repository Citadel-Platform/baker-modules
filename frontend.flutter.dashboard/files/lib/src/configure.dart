import 'package:flutter_riverpod/misc.dart';

/// Connects modules to the application, before the first frame.
///
/// Each module that needs starting — a sign-in, a database — says in its next
/// steps what to add here. The list is empty in a fresh build, and the
/// screens then say "not connected" rather than pretending.
Future<List<Override>> configure() async {
  return <Override>[];
}
