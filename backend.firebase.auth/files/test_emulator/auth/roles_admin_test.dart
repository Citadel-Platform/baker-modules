@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../../tool/src/roles_admin.dart';

/// Against the Auth emulator: the same REST surface as production.
///
///     firebase emulators:exec --only auth --project demo-local \
///       "flutter test test_emulator/auth"
void main() {
  final String host = Platform.environment['FIREBASE_AUTH_EMULATOR_HOST'] ?? '';
  const String project = 'demo-local';
  final Uri base = Uri.parse('http://$host/identitytoolkit.googleapis.com/v1/');
  late http.Client client;
  late RolesAdmin admin;

  setUpAll(() {
    // A failure, not a skip: "never ran" must not read as "passed".
    expect(
      host,
      isNotEmpty,
      reason:
          'Run under firebase emulators:exec; FIREBASE_AUTH_EMULATOR_HOST is unset.',
    );
    client = _Owner();
    admin = RolesAdmin(client, projectId: project, endpoint: base);
  });
  tearDownAll(() => client.close());

  Future<String> signUp(String email) async {
    final http.Response r = await http.post(
      Uri.parse(
        'http://$host/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake',
      ),
      headers: <String, String>{'content-type': 'application/json'},
      body: jsonEncode(<String, Object?>{
        'email': email,
        'password': 'emulator-only',
      }),
    );
    expect(r.statusCode, 200, reason: r.body);
    return (jsonDecode(r.body) as Map<String, Object?>)['localId']! as String;
  }

  test('sets roles, reads them back, and keeps other claims', () async {
    final String email =
        'staff-${DateTime.now().microsecondsSinceEpoch}@example.com';
    final String uid = await signUp(email);
    Account account = (await admin.find(email: email))!;
    expect(account.uid, uid);
    expect(account.roles, isEmpty);

    await http.post(
      base.resolve('projects/$project/accounts:update'),
      headers: <String, String>{
        'content-type': 'application/json',
        'authorization': 'Bearer owner',
      },
      body: jsonEncode(<String, Object?>{
        'localId': uid,
        'customAttributes': jsonEncode(<String, Object?>{'tenant': 't1'}),
      }),
    );
    account = (await admin.find(uid: uid))!;
    await admin.setRoles(account, <String>{'staff', 'admin'});
    account = (await admin.find(uid: uid))!;
    expect(account.roles, <String>{'admin', 'staff'});
    expect(account.claims['tenant'], 't1');

    await admin.setRoles(account, <String>{});
    account = (await admin.find(uid: uid))!;
    expect(account.roles, isEmpty);
    expect(account.claims, <String, Object?>{'tenant': 't1'});
  });

  test('an unknown person is null, not an error', () async {
    expect(
      await admin.find(
        email: 'nobody-${DateTime.now().microsecondsSinceEpoch}@example.com',
      ),
      isNull,
    );
  });

  test('the command line writes nothing without --apply', () async {
    final String email =
        'cli-${DateTime.now().microsecondsSinceEpoch}@example.com';
    final String uid = await signUp(email);
    Future<ProcessResult> run(List<String> extra) =>
        Process.run('dart', <String>[
          'run',
          'tool/set_roles.dart',
          '--project',
          project,
          '--email',
          email,
          ...extra,
        ]);

    final ProcessResult dry = await run(<String>['--roles', 'admin']);
    expect(dry.exitCode, 0, reason: '${dry.stdout}${dry.stderr}');
    expect('${dry.stdout}', contains('Nothing written'));
    expect((await admin.find(uid: uid))!.roles, isEmpty);

    final ProcessResult bad = await run(<String>[
      '--roles',
      'Admin',
      '--apply',
    ]);
    expect(bad.exitCode, 65);
    expect((await admin.find(uid: uid))!.roles, isEmpty);

    final ProcessResult applied = await run(<String>[
      '--roles',
      'admin',
      '--apply',
    ]);
    expect(applied.exitCode, 0, reason: '${applied.stdout}${applied.stderr}');
    expect('${applied.stdout}', contains('Read back: admin'));
    expect((await admin.find(uid: uid))!.roles, <String>{'admin'});
  });
}

class _Owner extends http.BaseClient {
  final http.Client _inner = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['authorization'] = 'Bearer owner';
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
