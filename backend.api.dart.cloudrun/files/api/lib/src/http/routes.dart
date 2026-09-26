import 'package:shelf/shelf.dart';

import '../auth/token_verifier.dart';
import 'problem.dart';

/// Who may call a route. Every route states one; there is no default.
sealed class ApiAccess {
  const ApiAccess();

  /// Anyone. Health checks and webhooks that verify their own signatures.
  const factory ApiAccess.public() = PublicApiAccess;

  /// Any signed-in person.
  const factory ApiAccess.signedIn({bool checkRevoked}) = SignedInApiAccess;

  /// A signed-in person holding one of [roles].
  const factory ApiAccess.roles(Set<String> roles, {bool checkRevoked}) =
      RoleApiAccess;

  /// Google Cloud itself (Cloud Tasks, Cloud Scheduler), by OIDC token for
  /// [serviceAccount]. For work the platform triggers, never a person.
  const factory ApiAccess.service(String serviceAccount) = ServiceApiAccess;
}

final class PublicApiAccess extends ApiAccess {
  const PublicApiAccess();
}

final class SignedInApiAccess extends ApiAccess {
  /// [checkRevoked] asks Firebase whether the sign-in was revoked or the
  /// account disabled since the token was issued: one extra lookup (cached
  /// briefly), worth it on routes that change data.
  const SignedInApiAccess({this.checkRevoked = false});
  final bool checkRevoked;
}

final class RoleApiAccess extends ApiAccess {
  const RoleApiAccess(this.roles, {this.checkRevoked = true});
  final Set<String> roles;
  final bool checkRevoked;
}

final class ServiceApiAccess extends ApiAccess {
  const ServiceApiAccess(this.serviceAccount);
  final String serviceAccount;
}

/// One route: method, path, who may call it, and what it does.
///
/// Paths are literal segments and `<name>` parameters: `/v1/records/<id>`.
class ApiRoute {
  const ApiRoute(
    this.method,
    this.path,
    this.handler, {
    required this.access,
    this.idempotent = false,
    this.summary = '',
  });

  final String method;
  final String path;
  final ApiAccess access;

  /// Requires an `Idempotency-Key` header, and answers a repeat of the same
  /// key with the first answer instead of acting twice.
  final bool idempotent;
  final String summary;
  final Future<Response> Function(ApiCall call) handler;

  List<String> get segments =>
      path.split('/').where((String s) => s.isNotEmpty).toList();
}

/// What a handler is given.
class ApiCall {
  const ApiCall({
    required this.request,
    required this.parameters,
    required this.requestId,
    this.user,
  });

  final Request request;
  final Map<String, String> parameters;
  final String requestId;

  /// Null only on public and service routes.
  final VerifiedUser? user;

  VerifiedUser get signedIn {
    final VerifiedUser? u = user;
    if (u == null) throw Problem.unauthenticated;
    return u;
  }
}

/// Finds the route for a request: a match, a 405 naming the methods the path
/// does have, or a 404.
({ApiRoute route, Map<String, String> parameters})? matchRoute(
  List<ApiRoute> routes,
  Request request,
) {
  final List<String> path = request.url.pathSegments
      .where((String s) => s.isNotEmpty)
      .toList();
  final Set<String> methodsHere = <String>{};
  for (final ApiRoute route in routes) {
    final Map<String, String>? parameters = _match(route.segments, path);
    if (parameters == null) continue;
    if (route.method == request.method) {
      return (route: route, parameters: parameters);
    }
    methodsHere.add(route.method);
  }
  if (methodsHere.isNotEmpty) throw Problem.methodNotAllowed(methodsHere);
  return null;
}

Map<String, String>? _match(List<String> pattern, List<String> path) {
  if (pattern.length != path.length) return null;
  final Map<String, String> parameters = <String, String>{};
  for (int i = 0; i < pattern.length; i++) {
    final String p = pattern[i];
    if (p.startsWith('<') && p.endsWith('>')) {
      parameters[p.substring(1, p.length - 1)] = path[i];
    } else if (p != path[i]) {
      return null;
    }
  }
  return parameters;
}
