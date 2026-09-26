import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:web_server/web_server.dart';

void main() {
  late Directory dir;
  late Handler handler;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('web-');
    File('${dir.path}/index.html').writeAsStringSync('<html>app</html>');
    File('${dir.path}/main.dart.js').writeAsStringSync('js');
    Directory('${dir.path}/assets').createSync();
    File('${dir.path}/assets/a.json').writeAsStringSync('{}');
    File('${dir.parent.path}/secret-${dir.path.hashCode}.txt')
        .writeAsStringSync('outside');
    handler = webServer(
      publicDir: dir,
      routes: (Request r) => r.url.path == 'api/ping'
          ? Response.ok('pong')
          : Response.notFound(''),
    );
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<Response> get(String path, {String method = 'GET'}) async =>
      await handler(Request(method, Uri.parse('http://localhost$path')));

  test('files are served with every security header', () async {
    final Response r = await get('/main.dart.js');
    expect(r.statusCode, 200);
    expect(await r.readAsString(), 'js');
    for (final String h in securityHeaders.keys) {
      expect(r.headers[h], securityHeaders[h], reason: h);
    }
  });

  test('a page of the app serves the app; a missing file is a 404', () async {
    final Response page = await get('/clients/42?tab=notes');
    expect(page.statusCode, 200);
    expect(await page.readAsString(), '<html>app</html>');
    expect(page.headers['content-type'], startsWith('text/html'));
    expect(page.headers['cache-control'], 'no-cache');
    expect((await get('/missing.js')).statusCode, 404);
    expect((await get('/assets/missing.png')).statusCode, 404);
  });

  test('nothing outside the build is reachable', () async {
    final Response r = await get('/../secret-${dir.path.hashCode}.txt');
    expect(await r.readAsString(), isNot('outside'));
    final Response encoded = await get('/%2e%2e/secret-${dir.path.hashCode}.txt');
    expect(await encoded.readAsString(), isNot('outside'));
  });

  test('server routes answer first, and only what they handle', () async {
    expect(await (await get('/api/ping')).readAsString(), 'pong');
    expect((await get('/api/other')).statusCode, 200,
        reason: 'unhandled paths are pages of the app');
  });

  test('only GET and HEAD reach the files', () async {
    final Response r = await get('/index.html', method: 'POST');
    expect(r.statusCode, 405);
    expect(r.headers['allow'], 'GET, HEAD');
    expect((await get('/', method: 'HEAD')).statusCode, 200);
  });

  test('health', () async {
    expect(await (await get('/healthz')).readAsString(), 'ok');
  });

  test('refuses to start with no build', () {
    expect(
      () => webServer(publicDir: Directory('${dir.path}/nope')),
      throwsStateError,
    );
  });
}
