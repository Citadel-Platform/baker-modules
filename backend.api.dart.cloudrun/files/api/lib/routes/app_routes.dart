import 'dart:convert';

import 'package:shelf/shelf.dart';

import '../api.dart';

/// What routes need from the environment.
class AppContext {
  const AppContext({required this.internalCaller});

  /// The service account Cloud Tasks and Scheduler call as; internal routes
  /// use `ApiAccess.service(context.internalCaller)`.
  final String internalCaller;
}

/// The application's routes. Add each with who may call it; the pipeline
/// refuses everything else. `openapi.yaml` lists the same routes, and
/// `test/openapi_test.dart` fails when the two disagree.
List<ApiRoute> appRoutes(AppContext context) => <ApiRoute>[
  ApiRoute(
    'GET',
    '/healthz',
    (_) async => Response.ok('ok'),
    access: const ApiAccess.public(),
    summary: 'Liveness, for Cloud Run.',
  ),
  ApiRoute(
    'GET',
    '/v1/me',
    (ApiCall call) async => json(<String, Object?>{
      'uid': call.signedIn.uid,
      'email': call.signedIn.email,
      'roles': (call.signedIn.roles.toList()..sort()),
    }),
    access: const ApiAccess.signedIn(),
    summary: 'Who the caller is, and their roles.',
  ),
];

/// A JSON response.
Response json(Object? body, {int status = 200}) => Response(
  status,
  body: jsonEncode(body),
  headers: <String, String>{'content-type': 'application/json'},
);
