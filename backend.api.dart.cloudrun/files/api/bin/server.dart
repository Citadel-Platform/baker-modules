import 'dart:async';
import 'dart:io';

import 'package:api/api.dart';
import 'package:api/routes/app_routes.dart';
import 'package:googleapis/cloudtasks/v2.dart' as ct;
import 'package:googleapis/firestore/v1.dart' as fs;
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf_io.dart' as io;

/// Configuration, all from the environment Terraform sets:
///
///   FIREBASE_PROJECT_ID   the project whose sign-ins are accepted
///   ALLOWED_ORIGINS       comma-separated browser origins
///   FIRESTORE_DATABASE    for idempotency records; `(default)` if unset
///   OIDC_AUDIENCE         what Cloud Tasks and Scheduler put in `aud`
///   INTERNAL_CALLER       the service account they call as
///   TASKS_QUEUE           the work queue, projects/P/locations/L/queues/Q
///   API_URL               this service's own address, which tasks call
///
/// With FIREBASE_AUTH_EMULATOR_HOST and FIRESTORE_EMULATOR_HOST set it runs
/// against the emulators, and refuses to start that way on Cloud Run.
Future<void> main() async {
  final Map<String, String> env = Platform.environment;
  final String project = _required(env, 'FIREBASE_PROJECT_ID');
  final String? authEmulator = env['FIREBASE_AUTH_EMULATOR_HOST'];
  final String? storeEmulator = env['FIRESTORE_EMULATOR_HOST'];
  final bool emulated = authEmulator != null || storeEmulator != null;
  if (emulated && env['K_SERVICE'] != null) {
    stderr.writeln('Emulator settings on Cloud Run: refusing to start.');
    exit(78);
  }

  final http.Client plain = http.Client();
  final http.Client google = emulated
      ? _Owner(plain)
      : await clientViaApplicationDefaultCredentials(
          scopes: <String>['https://www.googleapis.com/auth/cloud-platform'],
        );

  final ApiServices services = ApiServices(
    tokens: FirebaseTokenVerifier(
      projectId: project,
      keys: GoogleSigningKeys(plain),
      allowUnsigned: authEmulator != null,
    ),
    revocation: IdentityToolkitRevocation(
      google,
      projectId: project,
      endpoint: authEmulator == null
          ? null
          : Uri.parse(
              'http://$authEmulator/identitytoolkit.googleapis.com/v1/',
            ),
    ),
    idempotency: FirestoreIdempotencyStore(
      google,
      projectId: project,
      database: env['FIRESTORE_DATABASE'] ?? '(default)',
      endpoint: storeEmulator == null
          ? null
          : Uri.parse('http://$storeEmulator/v1/'),
    ),
    oidc: env['OIDC_AUDIENCE'] == null
        ? null
        : GoogleOidcVerifier(
            audience: env['OIDC_AUDIENCE']!,
            keys: GoogleOidcKeys(plain),
            alsoAccept: <String>{?env['API_URL']},
          ),
  );

  final int port = int.tryParse(env['PORT'] ?? '') ?? 8080;
  final HttpServer server = await io.serve(
    buildApi(
      routes: appRoutes(
        AppContext(
          internalCaller: env['INTERNAL_CALLER'] ?? '',
          firestore: AppFirestore(
            storeEmulator == null
                ? fs.FirestoreApi(google)
                : fs.FirestoreApi(google, rootUrl: 'http://$storeEmulator/'),
            projectId: project,
            database: env['FIRESTORE_DATABASE'] ?? '(default)',
          ),
          tasks: env['TASKS_QUEUE'] == null
              ? null
              : CloudTasksQueue(
                  ct.CloudTasksApi(google),
                  queue: env['TASKS_QUEUE']!,
                  apiUrl: _required(env, 'API_URL'),
                  caller: _required(env, 'INTERNAL_CALLER'),
                  audience: _required(env, 'OIDC_AUDIENCE'),
                ),
          google: google,
          environment: env,
        ),
      ),
      services: services,
      config: ApiConfig(
        allowedOrigins: <String>{
          for (final String o in (env['ALLOWED_ORIGINS'] ?? '').split(','))
            if (o.trim().isNotEmpty) o.trim(),
        },
      ),
    ),
    InternetAddress.anyIPv4,
    port,
  );
  stdout.writeln('{"severity":"INFO","message":"api on $port"}');

  late final StreamSubscription<ProcessSignal> sigterm;
  sigterm = ProcessSignal.sigterm.watch().listen((_) async {
    await sigterm.cancel();
    await server.close();
    google.close();
    plain.close();
    exit(0);
  });
}

String _required(Map<String, String> env, String name) {
  final String? v = env[name];
  if (v == null || v.isEmpty) {
    stderr.writeln('$name is not set.');
    exit(78);
  }
  return v;
}

/// The emulators accept `owner` as an administrator.
class _Owner extends http.BaseClient {
  _Owner(this._inner);
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['authorization'] = 'Bearer owner';
    return _inner.send(request);
  }
}
