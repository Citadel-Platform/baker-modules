import 'dart:convert';

import 'package:shelf/shelf.dart';

/// A refusal or failure, as RFC 9457 problem details.
///
/// One shape for every error from every route, so a client reads errors one
/// way. `code` is stable and meant for programs; `title` and `detail` are for
/// people. Nothing internal (a stack, an exception's text, a query) is ever
/// put in one: that goes to the log, keyed by the request id.
class Problem implements Exception {
  const Problem(
    this.status,
    this.code,
    this.title, {
    this.detail,
    this.headers = const <String, String>{},
    this.extra = const <String, Object?>{},
  });

  final int status;

  /// Stable and machine-readable: `invalid_body`, `not_permitted`.
  final String code;
  final String title;
  final String? detail;
  final Map<String, String> headers;

  /// Further members, such as the fields that failed validation.
  final Map<String, Object?> extra;

  static const Problem unauthenticated = Problem(
    401,
    'unauthenticated',
    'Sign-in required',
    headers: <String, String>{'www-authenticate': 'Bearer'},
  );
  static const Problem notPermitted = Problem(
    403,
    'not_permitted',
    'Not allowed',
    detail: 'Your account does not have access to this.',
  );
  static const Problem notFound = Problem(404, 'not_found', 'Not found');
  static const Problem tooLarge = Problem(
    413,
    'body_too_large',
    'Request too large',
  );
  static const Problem unavailable = Problem(
    503,
    'unavailable',
    'Temporarily unavailable',
    detail: 'Try again shortly.',
  );

  static Problem methodNotAllowed(Iterable<String> allowed) => Problem(
    405,
    'method_not_allowed',
    'Method not allowed',
    headers: <String, String>{'allow': allowed.join(', ')},
  );

  static Problem invalid(String detail, {Map<String, String>? fields}) =>
      Problem(
        400,
        'invalid_body',
        'The request was not valid',
        detail: detail,
        extra: <String, Object?>{'fields': ?fields},
      );

  Response toResponse({String? requestId}) => Response(
    status,
    body: jsonEncode(<String, Object?>{
      'type': 'about:blank',
      'status': status,
      'code': code,
      'title': title,
      'detail': ?detail,
      'requestId': ?requestId,
      ...extra,
    }),
    headers: <String, String>{
      'content-type': 'application/problem+json',
      ...headers,
    },
  );

  @override
  String toString() => 'Problem($status $code)';
}
