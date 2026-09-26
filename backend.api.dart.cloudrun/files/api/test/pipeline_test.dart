import 'dart:async';
import 'dart:convert';

import 'package:api/api.dart';
import 'package:api/routes/app_routes.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'support.dart';

class _Revocation implements RevocationCheck {
  final Set<String> revoked = <String>{};
  int checks = 0;
  @override
  Future<void> check(VerifiedUser user) async {
    checks++;
    if (revoked.contains(user.uid)) throw const TokenRejected('revoked');
  }
}

void main() {
  late ({pc.RSAPublicKey public, pc.RSAPrivateKey private}) key;
  late _Revocation revocation;
  late MemoryIdempotencyStore store;
  late Handler api;
  late int sideEffects;
  late Completer<void>? hold;

  setUpAll(() => key = rsaPair());

  setUp(() {
    revocation = _Revocation();
    store = MemoryIdempotencyStore();
    sideEffects = 0;
    hold = null;
    api = buildApi(
      routes: <ApiRoute>[
        ...appRoutes(
          const AppContext(
            internalCaller: 'internal@example.iam.gserviceaccount.com',
          ),
        ),
        ApiRoute(
          'POST',
          '/v1/records',
          (ApiCall call) async {
            final JsonBody body = await JsonBody.read(call.request);
            final String name = body.string('name', maxLength: 20);
            final int count = body.integer('count', min: 1, max: 5);
            body.check();
            if (hold != null) await hold!.future;
            if (name == 'explode') {
              throw StateError('database password is hunter2');
            }
            sideEffects++;
            return json(<String, Object?>{
              'name': name,
              'count': count,
              'n': sideEffects,
            }, status: 201);
          },
          access: const ApiAccess.roles(<String>{'admin'}),
          idempotent: true,
        ),
        ApiRoute(
          'GET',
          '/v1/records/<id>',
          (ApiCall call) async =>
              json(<String, Object?>{'id': call.parameters['id']}),
          access: const ApiAccess.signedIn(),
        ),
      ],
      services: ApiServices(
        tokens: FirebaseTokenVerifier(
          projectId: project,
          keys: FakeKeys(<String, RSAPublicKey>{
            'k1': RSAPublicKey.raw(key.public),
          }),
        ),
        revocation: revocation,
        idempotency: store,
      ),
      config: const ApiConfig(
        allowedOrigins: <String>{'https://app.example.com'},
        maxBodyBytes: 1024,
      ),
    );
  });

  String bearer({Object? roles, String sub = 'u1'}) =>
      'Bearer ${firebaseToken(key.private, roles: roles, sub: sub)}';

  Future<Response> send(
    String method,
    String path, {
    Map<String, String> headers = const <String, String>{},
    Object? body,
  }) async => await api(
    Request(
      method,
      Uri.parse('https://api.example.com$path'),
      headers: <String, String>{
        if (body != null) 'content-type': 'application/json',
        ...headers,
      },
      body: body == null ? null : (body is String ? body : jsonEncode(body)),
    ),
  );

  Future<Map<String, Object?>> problem(Response r) async {
    expect(r.headers['content-type'], 'application/problem+json');
    return jsonDecode(await r.readAsString()) as Map<String, Object?>;
  }

  Map<String, String> admin(String key) => <String, String>{
    'authorization': bearer(roles: <String>['admin']),
    'idempotency-key': key,
  };

  test('public and signed-in routes, with API headers on everything', () async {
    final Response health = await send('GET', '/health');
    expect(await health.readAsString(), 'ok');
    expect(health.headers['cache-control'], 'no-store');
    expect(health.headers['x-content-type-options'], 'nosniff');
    expect(health.headers['x-request-id'], isNotEmpty);

    final Response me = await send(
      'GET',
      '/v1/me',
      headers: <String, String>{
        'authorization': bearer(roles: <String>['staff', 'admin']),
      },
    );
    expect(jsonDecode(await me.readAsString()), <String, Object?>{
      'uid': 'u1',
      'email': 'u1@example.com',
      'roles': <String>['admin', 'staff'],
    });
    final Response param = await send(
      'GET',
      '/v1/records/abc',
      headers: <String, String>{'authorization': bearer()},
    );
    expect(jsonDecode(await param.readAsString()), <String, Object?>{
      'id': 'abc',
    });
  });

  test(
    '401 without a token or with a bad one, saying nothing of why',
    () async {
      final Response none = await send('GET', '/v1/me');
      expect(none.statusCode, 401);
      expect(none.headers['www-authenticate'], 'Bearer');
      expect((await problem(none))['code'], 'unauthenticated');
      final Response bad = await send(
        'GET',
        '/v1/me',
        headers: <String, String>{'authorization': 'Bearer not.a.token'},
      );
      expect(bad.statusCode, 401);
      expect(await bad.readAsString(), isNot(contains('JWT')));
    },
  );

  test('403 without the role; revocation checked on role routes', () async {
    final Response staff = await send(
      'POST',
      '/v1/records',
      headers: <String, String>{
        'authorization': bearer(roles: <String>['staff']),
        'idempotency-key': 'k',
      },
      body: <String, Object?>{'name': 'a', 'count': 1},
    );
    expect(staff.statusCode, 403);
    expect((await problem(staff))['code'], 'not_permitted');

    revocation.revoked.add('u1');
    final Response revoked = await send(
      'POST',
      '/v1/records',
      headers: admin('k2'),
      body: <String, Object?>{'name': 'a', 'count': 1},
    );
    expect(revoked.statusCode, 401);
    expect(sideEffects, 0);
  });

  test('404 and 405 are problems; 405 names the allowed methods', () async {
    expect((await send('GET', '/nope')).statusCode, 404);
    final Response wrong = await send('DELETE', '/v1/me');
    expect(wrong.statusCode, 405);
    expect(wrong.headers['allow'], 'GET');
  });

  test('every bad field is named in one 400', () async {
    final Response r = await send(
      'POST',
      '/v1/records',
      headers: admin('k'),
      body: <String, Object?>{'name': 'x' * 30, 'count': 9},
    );
    expect(r.statusCode, 400);
    expect((await problem(r))['fields'], <String, Object?>{
      'name': 'must be at most 20 characters',
      'count': 'must be between 1 and 5',
    });
    final Response notJson = await send(
      'POST',
      '/v1/records',
      headers: admin('k3'),
      body: '{nope',
    );
    expect((await problem(notJson))['detail'], contains('not valid JSON'));
  });

  test('bodies over the limit are refused, declared or not', () async {
    final Response declared = await send(
      'POST',
      '/v1/records',
      headers: admin('k'),
      body: <String, Object?>{'name': 'x' * 2000, 'count': 1},
    );
    expect(declared.statusCode, 413);
    final Response streamed = await api(
      Request(
        'POST',
        Uri.parse('https://api.example.com/v1/records'),
        headers: <String, String>{
          ...admin('k4'),
          'content-type': 'application/json',
        },
        body: Stream<List<int>>.fromIterable(<List<int>>[
          utf8.encode('{"name":"'),
          utf8.encode('x' * 2000),
          utf8.encode('","count":1}'),
        ]),
      ),
    );
    expect(streamed.statusCode, 413);
    expect(sideEffects, 0);
  });

  test('an unexpected error is a 500 carrying only the request id', () async {
    final Response r = await send(
      'POST',
      '/v1/records',
      headers: admin('k'),
      body: <String, Object?>{'name': 'explode', 'count': 1},
    );
    expect(r.statusCode, 500);
    final String text = await r.readAsString();
    expect(text, isNot(contains('hunter2')));
    expect(jsonDecode(text), containsPair('requestId', isNotEmpty));
  });

  group('idempotency', () {
    test('a retry gets the first answer and acts once', () async {
      final Response first = await send(
        'POST',
        '/v1/records',
        headers: admin('same'),
        body: <String, Object?>{'name': 'a', 'count': 1},
      );
      final Response again = await send(
        'POST',
        '/v1/records',
        headers: admin('same'),
        body: <String, Object?>{'name': 'a', 'count': 1},
      );
      expect(first.statusCode, 201);
      expect(again.statusCode, 201);
      expect(again.headers['idempotent-replayed'], 'true');
      expect(await again.readAsString(), await first.readAsString());
      expect(sideEffects, 1);
    });

    test('the same key for a different body is refused', () async {
      await send(
        'POST',
        '/v1/records',
        headers: admin('k'),
        body: <String, Object?>{'name': 'a', 'count': 1},
      );
      final Response r = await send(
        'POST',
        '/v1/records',
        headers: admin('k'),
        body: <String, Object?>{'name': 'b', 'count': 1},
      );
      expect(r.statusCode, 422);
      expect(sideEffects, 1);
    });

    test('a concurrent repeat is told it is in progress', () async {
      hold = Completer<void>();
      final Future<Response> first = send(
        'POST',
        '/v1/records',
        headers: admin('k'),
        body: <String, Object?>{'name': 'a', 'count': 1},
      );
      await Future<void>.delayed(Duration.zero);
      final Response second = await send(
        'POST',
        '/v1/records',
        headers: admin('k'),
        body: <String, Object?>{'name': 'a', 'count': 1},
      );
      expect(second.statusCode, 409);
      expect(second.headers['retry-after'], '2');
      hold!.complete();
      expect((await first).statusCode, 201);
      expect(sideEffects, 1);
    });

    test('a crash releases the key so the client can try again', () async {
      final Response crashed = await send(
        'POST',
        '/v1/records',
        headers: admin('k'),
        body: <String, Object?>{'name': 'explode', 'count': 1},
      );
      expect(crashed.statusCode, 500);
      final Response retried = await send(
        'POST',
        '/v1/records',
        headers: admin('k'),
        body: <String, Object?>{'name': 'explode', 'count': 1},
      );
      expect(retried.statusCode, 500, reason: 'acted on again, not replayed');
      expect(retried.headers['idempotent-replayed'], isNull);
    });

    test('a key is required', () async {
      final Response r = await send(
        'POST',
        '/v1/records',
        headers: <String, String>{
          'authorization': bearer(roles: <String>['admin']),
        },
        body: <String, Object?>{'name': 'a', 'count': 1},
      );
      expect(r.statusCode, 400);
    });

    test('keys are per person', () async {
      await send(
        'POST',
        '/v1/records',
        headers: admin('shared'),
        body: <String, Object?>{'name': 'a', 'count': 1},
      );
      final Response other = await send(
        'POST',
        '/v1/records',
        headers: <String, String>{
          'authorization': bearer(roles: <String>['admin'], sub: 'u2'),
          'idempotency-key': 'shared',
        },
        body: <String, Object?>{'name': 'a', 'count': 1},
      );
      expect(other.headers['idempotent-replayed'], isNull);
      expect(sideEffects, 2);
    });
  });

  group('CORS', () {
    test('an allowed origin gets a preflight and its header', () async {
      final Response pre = await send(
        'OPTIONS',
        '/v1/me',
        headers: <String, String>{
          'origin': 'https://app.example.com',
          'access-control-request-method': 'GET',
        },
      );
      expect(pre.statusCode, 204);
      expect(
        pre.headers['access-control-allow-origin'],
        'https://app.example.com',
      );
      expect(
        pre.headers['access-control-allow-headers'],
        contains('idempotency-key'),
      );
      final Response get = await send(
        'GET',
        '/health',
        headers: <String, String>{'origin': 'https://app.example.com'},
      );
      expect(
        get.headers['access-control-allow-origin'],
        'https://app.example.com',
      );
      expect(get.headers['vary'], 'Origin');
    });

    test('any other origin gets nothing', () async {
      final Response pre = await send(
        'OPTIONS',
        '/v1/me',
        headers: <String, String>{
          'origin': 'https://evil.example',
          'access-control-request-method': 'GET',
        },
      );
      expect(pre.statusCode, 403);
      expect(pre.headers['access-control-allow-origin'], isNull);
    });
  });
}
