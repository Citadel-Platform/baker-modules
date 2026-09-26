import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf_static/shelf_static.dart';

/// Response headers on everything served.
///
/// The same set Firebase Hosting sends in `deploy.firebase.hosting.frontend.flutter`.
/// The content security policy is report-only until a real deployment shows
/// it clean in the browser console; then rename the header to enforce it.
const Map<String, String> securityHeaders = <String, String>{
  'strict-transport-security': 'max-age=31536000; includeSubDomains',
  'x-content-type-options': 'nosniff',
  'referrer-policy': 'strict-origin-when-cross-origin',
  'x-frame-options': 'DENY',
  'permissions-policy': 'camera=(), microphone=(), geolocation=(), payment=()',
  'cross-origin-opener-policy': 'same-origin-allow-popups',
  'content-security-policy-report-only':
      "default-src 'self'; "
      "script-src 'self' 'wasm-unsafe-eval' https://www.gstatic.com https://apis.google.com; "
      "style-src 'self' 'unsafe-inline'; "
      "img-src 'self' data: blob: https:; "
      "font-src 'self' data: https://fonts.gstatic.com; "
      "connect-src 'self' https://*.googleapis.com https://www.gstatic.com "
      'https://fonts.gstatic.com https://*.run.app wss://*.firebaseio.com; '
      'frame-src https://*.firebaseapp.com https://accounts.google.com; '
      "worker-src 'self' blob:; object-src 'none'; base-uri 'self'; "
      "frame-ancestors 'none'; form-action 'self'",
  // Flutter's web build does not put content hashes in its file names, so
  // anything cached could be a stale app. Revalidating is cheap: the files
  // carry Last-Modified and a revalidation that matches is a 304.
  'cache-control': 'no-cache',
};

/// The whole server: health, the application's own routes, then the app.
///
/// [routes] is where server-side behaviour goes (an API, a webhook). It
/// answers first; a 404 from it falls through to the static files.
Handler webServer({required Directory publicDir, Handler? routes}) {
  final File index = File('${publicDir.path}/index.html');
  if (!index.existsSync()) {
    throw StateError('No index.html in ${publicDir.path}: nothing to serve.');
  }
  final Handler files = createStaticHandler(
    publicDir.path,
    defaultDocument: 'index.html',
    serveFilesOutsidePath: false,
  );

  Response app(Request request) {
    return Response.ok(
      index.readAsBytesSync(),
      headers: <String, String>{'content-type': 'text/html; charset=utf-8'},
    );
  }

  final Handler cascade = Cascade(statusCodes: <int>[404, 405])
      .add(routes ?? (_) => Response.notFound(''))
      .add((Request request) async {
        if (request.method != 'GET' && request.method != 'HEAD') {
          return Response(405, headers: <String, String>{'allow': 'GET, HEAD'});
        }
        final Response found = await files(request);
        if (found.statusCode != 404) return found;
        // A path with no file extension is a page of the app (`/clients/42`):
        // serve the app and let its router decide. A missing file (`/x.js`)
        // is a real 404, so a broken asset link is not hidden behind HTML.
        final String last = request.url.pathSegments.isEmpty
            ? ''
            : request.url.pathSegments.last;
        return last.contains('.') ? found : app(request);
      })
      .handler;

  return const Pipeline()
      .addMiddleware(_log())
      .addMiddleware(_headers())
      .addMiddleware(_gzip())
      .addHandler((Request request) {
        if (request.url.path == 'healthz') return Response.ok('ok');
        return cascade(request);
      });
}

/// Compresses text-like responses for clients that accept gzip.
///
/// Done here rather than by `HttpServer.autoCompress`, which skipped every
/// static file: they carry a Content-Length, and the whole 2.4 MB
/// `main.dart.js` went out uncompressed (found running the image).
Middleware _gzip() =>
    (Handler inner) => (Request request) async {
      final Response response = await inner(request);
      final String type = response.headers['content-type'] ?? '';
      final bool accepts = (request.headers['accept-encoding'] ?? '')
          .split(',')
          .any((String e) => e.trim().split(';').first == 'gzip');
      if (!accepts ||
          request.method == 'HEAD' ||
          response.statusCode != 200 ||
          response.headers.containsKey('content-encoding') ||
          !compressible(type)) {
        return response;
      }
      return Response(
        200,
        body: response.read().transform(gzip.encoder),
        headers: <String, Object>{
          for (final MapEntry<String, List<String>> h
              in response.headersAll.entries)
            if (h.key != 'content-length') h.key: h.value,
          'content-encoding': 'gzip',
          'vary': 'Accept-Encoding',
        },
      );
    };

/// Types worth compressing: text, and the WebAssembly and JSON Flutter loads.
bool compressible(String contentType) {
  final String t = contentType.split(';').first.trim().toLowerCase();
  return t.startsWith('text/') ||
      t == 'application/javascript' ||
      t == 'application/json' ||
      t == 'application/wasm' ||
      t == 'image/svg+xml' ||
      t == 'application/manifest+json';
}

Middleware _headers() =>
    (Handler inner) => (Request request) async {
      final Response response = await inner(request);
      return response.change(headers: securityHeaders);
    };

/// One JSON line per request, in Cloud Logging's structured format. Paths
/// only: query strings can carry tokens.
Middleware _log() =>
    (Handler inner) => (Request request) async {
      final Stopwatch watch = Stopwatch()..start();
      final Response response = await inner(request);
      stdout.writeln(
        jsonEncode(<String, Object?>{
          'severity': response.statusCode >= 500 ? 'ERROR' : 'INFO',
          'httpRequest': <String, Object?>{
            'requestMethod': request.method,
            'requestUrl': '/${request.url.path}',
            'status': response.statusCode,
            'latency': '${watch.elapsedMicroseconds / 1e6}s',
            'userAgent': request.headers['user-agent'],
          },
          'logging.googleapis.com/trace': request
              .headers['x-cloud-trace-context']
              ?.split('/')
              .first,
        }),
      );
      return response;
    };
