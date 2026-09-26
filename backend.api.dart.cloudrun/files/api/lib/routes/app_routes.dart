import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:shelf/shelf.dart';

import '../api.dart';
// baker:imports

/// What routes are given: the database, the work queue, and settings.
///
/// A feature's routes are built from this; feature modules add theirs to
/// [appRoutes] at its `baker:routes` line when the application is
/// bootstrapped.
class AppContext {
  const AppContext({
    required this.internalCaller,
    this.firestore,
    this.tasks,
    this.google,
    this.environment = const <String, String>{},
  });

  /// The service account Cloud Tasks and Scheduler call as; internal routes
  /// use `ApiAccess.service(context.internalCaller)`.
  final String internalCaller;

  /// Null only in tests that do not touch data.
  final AppFirestore? firestore;

  /// Null only in tests that queue nothing.
  final TaskQueue? tasks;

  /// An HTTP client authorised as the service (`cloud-platform`), for Google
  /// APIs a feature calls directly (Secret Manager). Null in tests.
  final http.Client? google;

  /// Settings Terraform passes (`api_env`) and secrets (`api_env_secrets`).
  final Map<String, String> environment;

  AppFirestore get db =>
      firestore ?? (throw StateError('This route needs Firestore.'));
  TaskQueue get queue =>
      tasks ?? (throw StateError('This route needs the work queue.'));
  http.Client get googleClient =>
      google ?? (throw StateError('This route needs a Google API client.'));

  /// A setting that must be present. A missing one fails, naming it, the
  /// first request that needs it: a 500 with the name in the log, never a
  /// half-configured success.
  String setting(String name) {
    final String? v = environment[name];
    if (v == null || v.isEmpty) {
      throw StateError('$name is not set.');
    }
    return v;
  }
}

/// The application's routes. Add each with who may call it; the pipeline
/// refuses everything else. `openapi.yaml` lists the same routes, and
/// `test/openapi_test.dart` fails when the two disagree.
List<ApiRoute> appRoutes(AppContext context) => <ApiRoute>[
  // baker:routes
  ApiRoute(
    'GET',
    // Not /healthz: Cloud Run reserves some paths ending in "z" at its front
    // end, so a check from outside never reaches the container.
    '/health',
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
