import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'src/app.dart';
import 'src/configure.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Real paths (`/clients/42`) rather than `/#/clients/42`, so links can be
  // shared and the hosting rewrites every path to index.html.
  usePathUrlStrategy();
  final List<Override> overrides = await configure();
  runApp(ProviderScope(overrides: overrides, child: const ClientApp()));
}
