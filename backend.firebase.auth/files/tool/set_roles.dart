import 'dart:io';

import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;

import 'src/roles_admin.dart';

/// Shows or sets a person's roles.
///
///     dart run tool/set_roles.dart --project <id> --email a@b.com
///     dart run tool/set_roles.dart --project <id> --email a@b.com --roles admin,staff
///     dart run tool/set_roles.dart --project <id> --email a@b.com --roles admin,staff --apply
///     dart run tool/set_roles.dart --project <id> --uid <uid> --roles "" --apply
///
/// Without --apply nothing is written: it prints what would change. Runs as
/// your Application Default Credentials (`gcloud auth application-default
/// login`), which need permission to manage the project's users; no key file.
/// With FIREBASE_AUTH_EMULATOR_HOST set it talks to the emulator instead.
///
/// A person's app picks up new roles when their token next refreshes (within
/// the hour), or at once if they sign out and in again.
Future<void> main(List<String> args) async {
  final Map<String, String> o = _options(args);
  final String? project = o['project'];
  if (project == null || (o['email'] == null) == (o['uid'] == null)) {
    stderr.writeln('Give --project, and one of --email or --uid.');
    exitCode = 64;
    return;
  }
  final String? emulator = Platform.environment['FIREBASE_AUTH_EMULATOR_HOST'];
  final bool apply = args.contains('--apply');

  final http.Client client;
  final Uri? endpoint;
  if (emulator != null && emulator.isNotEmpty) {
    stdout.writeln('Emulator at $emulator.');
    client = _EmulatorClient();
    endpoint = Uri.parse('http://$emulator/identitytoolkit.googleapis.com/v1/');
  } else {
    if (project.startsWith('demo-')) {
      stderr.writeln(
        '$project is an emulator-only project; start the emulator.',
      );
      exitCode = 64;
      return;
    }
    client = await clientViaApplicationDefaultCredentials(
      scopes: <String>['https://www.googleapis.com/auth/cloud-platform'],
    );
    endpoint = null;
  }

  try {
    final RolesAdmin admin = RolesAdmin(
      _QuotaProject(client, project),
      projectId: project,
      endpoint: endpoint,
    );
    final Account? account = await admin.find(email: o['email'], uid: o['uid']);
    if (account == null) {
      stderr.writeln('No account for ${o['email'] ?? o['uid']} in $project.');
      exitCode = 1;
      return;
    }
    final String who = account.email.isEmpty ? account.uid : account.email;
    stdout.writeln(
      '$who (${account.uid})${account.disabled ? ', disabled' : ''}',
    );
    stdout.writeln('  roles now: ${_show(account.roles)}');
    final String? given = o['roles'];
    if (given == null) return;

    final Set<String> next = <String>{
      for (final String r in given.split(','))
        if (r.trim().isNotEmpty) r.trim(),
    };
    RolesAdmin.claimsWith(account.claims, next);
    stdout.writeln('  roles after: ${_show(next)}');
    if (!apply) {
      stdout.writeln('Nothing written. Add --apply to set them.');
      return;
    }
    await admin.setRoles(account, next);
    final Account? after = await admin.find(uid: account.uid);
    stdout.writeln(
      'Set. Read back: ${_show(after?.roles ?? const <String>{})}',
    );
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 65;
  } on RolesAdminException catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  } finally {
    client.close();
  }
}

String _show(Set<String> roles) =>
    roles.isEmpty ? '(none)' : (roles.toList()..sort()).join(', ');

Map<String, String> _options(List<String> args) {
  final Map<String, String> o = <String, String>{};
  for (int i = 0; i < args.length - 1; i++) {
    if (args[i].startsWith('--') && !args[i + 1].startsWith('--')) {
      o[args[i].substring(2)] = args[i + 1];
    }
  }
  return o;
}

/// The emulator accepts `owner` as an administrator token.
class _EmulatorClient extends http.BaseClient {
  final http.Client _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['authorization'] = 'Bearer owner';
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

/// Bills the call to [project]. User credentials from `gcloud auth
/// application-default login` otherwise have no project to bill, and the API
/// refuses them.
class _QuotaProject extends http.BaseClient {
  _QuotaProject(this._inner, this._project);
  final http.Client _inner;
  final String _project;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['x-goog-user-project'] = _project;
    return _inner.send(request);
  }
}
