import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:web_server/web_server.dart';

/// Serves the Flutter web build.
///
/// Cloud Run sends SIGTERM before stopping an instance; requests in flight
/// are finished rather than cut off.
Future<void> main() async {
  final int port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;
  final Directory publicDir = Directory(
    Platform.environment['PUBLIC_DIR'] ?? '/app/public',
  );
  final Handler handler = webServer(publicDir: publicDir, routes: routes);
  final HttpServer server = await io.serve(
    handler,
    InternetAddress.anyIPv4,
    port,
  );
  server.autoCompress = true;
  stdout.writeln('{"severity":"INFO","message":"serving on $port"}');

  late final StreamSubscription<ProcessSignal> sigterm;
  sigterm = ProcessSignal.sigterm.watch().listen((_) async {
    await sigterm.cancel();
    await server.close();
    exit(0);
  });
}

/// The application's server-side routes. None yet: add them here, and
/// return 404 for anything not handled so the app is served instead.
Response routes(Request request) => Response.notFound('');
