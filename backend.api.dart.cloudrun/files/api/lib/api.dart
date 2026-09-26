import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shelf/shelf.dart';

import 'src/auth/google_oidc.dart';
import 'src/auth/revocation.dart';
import 'src/auth/token_verifier.dart';
import 'src/http/problem.dart';
import 'src/http/routes.dart';
import 'src/store/idempotency.dart';

export 'src/auth/google_oidc.dart';
export 'src/google/firestore.dart';
export 'src/google/tasks.dart';
export 'src/auth/revocation.dart';
export 'src/auth/token_verifier.dart';
export 'src/http/json_body.dart';
export 'src/http/problem.dart';
export 'src/http/routes.dart';
export 'src/store/idempotency.dart';

/// What the pipeline needs, gathered in one place so tests give fakes.
class ApiServices {
  const ApiServices({
    required this.tokens,
    required this.revocation,
    required this.idempotency,
    this.oidc,
  });

  final FirebaseTokenVerifier tokens;
  final RevocationCheck revocation;
  final IdempotencyStore idempotency;

  /// Null when no route is called by Google Cloud.
  final GoogleOidcVerifier? oidc;
}

/// Everything configurable about the pipeline itself.
class ApiConfig {
  const ApiConfig({
    this.allowedOrigins = const <String>{},
    this.maxBodyBytes = 256 * 1024,
  });

  /// Exact origins a browser may call from (`https://app.example.com`). No
  /// wildcard: a wildcard with credentials is refused by browsers, and without
  /// them it invites any site to use the API from a signed-in person's tab.
  final Set<String> allowedOrigins;

  /// The largest body accepted, counted on the stream as it arrives, so a
  /// client that lies in Content-Length or sends none is still stopped.
  final int maxBodyBytes;
}

/// The API: the pipeline around [routes].
Handler buildApi({
  required List<ApiRoute> routes,
  required ApiServices services,
  ApiConfig config = const ApiConfig(),
}) {
  return const Pipeline()
      .addMiddleware(_requestContext())
      .addMiddleware(_log())
      .addMiddleware(_securityHeaders())
      .addMiddleware(_cors(config.allowedOrigins))
      .addMiddleware(_problems())
      .addMiddleware(_bodyLimit(config.maxBodyBytes))
      .addHandler((Request request) => _dispatch(request, routes, services));
}

Future<Response> _dispatch(
  Request request,
  List<ApiRoute> routes,
  ApiServices services,
) async {
  final ({ApiRoute route, Map<String, String> parameters})? match = matchRoute(
    routes,
    request,
  );
  if (match == null) throw Problem.notFound;
  final ApiRoute route = match.route;
  final String requestId = request.context['requestId']! as String;

  VerifiedUser? user;
  switch (route.access) {
    case PublicApiAccess():
      break;
    case ServiceApiAccess(:final String serviceAccount):
      final GoogleOidcVerifier? oidc = services.oidc;
      if (oidc == null) throw Problem.unavailable;
      final String caller = await _authenticate(
        request,
        (String t) => oidc.verify(t),
      );
      if (caller != serviceAccount) throw Problem.notPermitted;
    case SignedInApiAccess(:final bool checkRevoked):
      user = await _signedIn(request, services, checkRevoked);
    case RoleApiAccess(:final Set<String> roles, :final bool checkRevoked):
      user = await _signedIn(request, services, checkRevoked);
      if (!roles.any(user.roles.contains)) throw Problem.notPermitted;
  }

  Future<Response> run(Request r) => route.handler(
    ApiCall(
      request: r,
      parameters: match.parameters,
      requestId: requestId,
      user: user,
    ),
  );

  if (!route.idempotent) return run(request);
  return _idempotent(request, route, user, services.idempotency, run);
}

Future<VerifiedUser> _signedIn(
  Request request,
  ApiServices services,
  bool checkRevoked,
) async {
  final VerifiedUser user = await _authenticate(
    request,
    services.tokens.verify,
  );
  if (checkRevoked) {
    try {
      await services.revocation.check(user);
    } on TokenRejected {
      throw Problem.unauthenticated;
    }
  }
  return user;
}

Future<T> _authenticate<T>(
  Request request,
  Future<T> Function(String token) verify,
) async {
  final String header = request.headers['authorization'] ?? '';
  if (!header.startsWith('Bearer ')) throw Problem.unauthenticated;
  try {
    return await verify(header.substring(7).trim());
  } on TokenRejected catch (error) {
    _logLine('NOTICE', 'refused a token: ${error.reason}', request);
    throw Problem.unauthenticated;
  }
}

Future<Response> _idempotent(
  Request request,
  ApiRoute route,
  VerifiedUser? user,
  IdempotencyStore store,
  Future<Response> Function(Request) run,
) async {
  final String? key = request.headers['idempotency-key'];
  if (key == null || key.isEmpty || key.length > 255) {
    throw Problem.invalid(
      'Send an Idempotency-Key header (at most 255 characters).',
    );
  }
  final List<int> body = await request.read().fold(
    <int>[],
    (List<int> a, List<int> b) => a..addAll(b),
  );
  final String id = idempotencyId(
    user?.uid ?? '-',
    '${route.method} ${route.path}',
    key,
  );
  final String fingerprint = requestFingerprint(
    request.method,
    request.url.path,
    body,
  );
  switch (await store.claim(id, fingerprint)) {
    case Answered(:final StoredAnswer answer):
      return Response(
        answer.status,
        body: answer.body,
        headers: <String, String>{
          'content-type': answer.contentType,
          'idempotent-replayed': 'true',
        },
      );
    case InProgress():
      throw const Problem(
        409,
        'in_progress',
        'Already in progress',
        detail: 'A request with this Idempotency-Key is still running.',
        headers: <String, String>{'retry-after': '2'},
      );
    case Reused():
      throw const Problem(
        422,
        'idempotency_key_reused',
        'Idempotency-Key reused',
        detail: 'This key was used for a different request.',
      );
    case Claimed():
      break;
  }

  final Response response;
  try {
    response = await run(request.change(body: body));
  } on Problem catch (problem) {
    if (problem.status >= 500) {
      await store.release(id);
      rethrow;
    }
    // A refusal is an answer: the same request would be refused again.
    final Response refused = problem.toResponse(
      requestId: request.context['requestId'] as String?,
    );
    await store.complete(
      id,
      StoredAnswer(
        status: refused.statusCode,
        body: await refused.readAsString(),
        contentType: 'application/problem+json',
      ),
    );
    rethrow;
  } catch (_) {
    // Nothing was answered: let the client try again.
    await store.release(id);
    rethrow;
  }
  if (response.statusCode >= 500) {
    await store.release(id);
    return response;
  }
  final String text = await response.readAsString();
  await store.complete(
    id,
    StoredAnswer(
      status: response.statusCode,
      body: text,
      contentType: response.headers['content-type'] ?? 'application/json',
    ),
  );
  return response.change(body: text);
}

Middleware _requestContext() =>
    (Handler inner) => (Request request) {
      final String trace =
          request.headers['x-cloud-trace-context']?.split('/').first ?? '';
      final String id = trace.isNotEmpty
          ? trace
          : List<String>.generate(
              16,
              (_) => Random.secure().nextInt(16).toRadixString(16),
            ).join();
      return inner(request.change(context: <String, Object>{'requestId': id}));
    };

Middleware _log() =>
    (Handler inner) => (Request request) async {
      final Stopwatch watch = Stopwatch()..start();
      final Response response = await inner(request);
      stdout.writeln(
        jsonEncode(<String, Object?>{
          'severity': response.statusCode >= 500 ? 'ERROR' : 'INFO',
          'httpRequest': <String, Object?>{
            'requestMethod': request.method,
            // The path only: query strings and headers can carry tokens.
            'requestUrl': '/${request.url.path}',
            'status': response.statusCode,
            'latency': '${watch.elapsedMicroseconds / 1e6}s',
          },
          'requestId': request.context['requestId'],
        }),
      );
      return response;
    };

void _logLine(String severity, String message, Request request) {
  stdout.writeln(
    jsonEncode(<String, Object?>{
      'severity': severity,
      'message': message,
      'requestId': request.context['requestId'],
    }),
  );
}

/// Headers for an API: nothing it returns is a page, may be cached or framed.
Middleware _securityHeaders() =>
    (Handler inner) => (Request request) async {
      final Response response = await inner(request);
      return response.change(
        headers: <String, String>{
          'x-content-type-options': 'nosniff',
          'cache-control': 'no-store',
          'content-security-policy':
              "default-src 'none'; frame-ancestors 'none'",
          'referrer-policy': 'no-referrer',
          'strict-transport-security': 'max-age=31536000; includeSubDomains',
          'x-request-id': '${request.context['requestId']}',
        },
      );
    };

Middleware _cors(Set<String> allowed) =>
    (Handler inner) => (Request request) async {
      final String? origin = request.headers['origin'];
      final bool ok = origin != null && allowed.contains(origin);
      final Map<String, String> headers = <String, String>{
        'vary': 'Origin',
        if (ok) 'access-control-allow-origin': origin,
      };
      if (request.method == 'OPTIONS' &&
          request.headers.containsKey('access-control-request-method')) {
        // A preflight is answered here, for allowed origins only.
        return Response(
          ok ? 204 : 403,
          headers: <String, String>{
            ...headers,
            if (ok) ...<String, String>{
              'access-control-allow-methods': 'GET, POST, PUT, PATCH, DELETE',
              'access-control-allow-headers':
                  'authorization, content-type, idempotency-key',
              'access-control-max-age': '600',
            },
          },
        );
      }
      final Response response = await inner(request);
      return response.change(headers: headers);
    };

/// Every error becomes a problem response; anything unexpected is logged in
/// full and answered with nothing but the request id.
Middleware _problems() =>
    (Handler inner) => (Request request) async {
      final String? id = request.context['requestId'] as String?;
      try {
        return await inner(request);
      } on Problem catch (problem) {
        return problem.toResponse(requestId: id);
      } catch (error, stack) {
        stdout.writeln(
          jsonEncode(<String, Object?>{
            'severity': 'ERROR',
            'message': '$error',
            'stack_trace': '$stack',
            'requestId': id,
          }),
        );
        return const Problem(
          500,
          'internal',
          'Something went wrong',
        ).toResponse(requestId: id);
      }
    };

Middleware _bodyLimit(int max) =>
    (Handler inner) => (Request request) {
      final int? declared = request.contentLength;
      if (declared != null && declared > max) throw Problem.tooLarge;
      int seen = 0;
      final Stream<List<int>> counted = request.read().map((List<int> chunk) {
        seen += chunk.length;
        if (seen > max) throw Problem.tooLarge;
        return chunk;
      });
      return inner(request.change(body: counted));
    };
