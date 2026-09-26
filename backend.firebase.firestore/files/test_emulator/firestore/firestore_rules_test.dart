@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// `firestore.rules` against the Firestore emulator.
///
/// The helpers are tested as written: the real file is loaded, and test
/// collections are put where a client's collections go (between the
/// "collections" markers). Requests carry unsigned tokens, which the emulator
/// accepts, as Firebase's own rules-testing library does.
///
///     firebase emulators:exec --only firestore --project demo-local \
///       "flutter test test_emulator/firestore"
void main() {
  final String host = Platform.environment['FIRESTORE_EMULATOR_HOST'] ?? '';
  const String project = 'demo-local';
  final String docs =
      'http://$host/v1/projects/$project/databases/(default)/documents';

  setUpAll(() async {
    expect(
      host,
      isNotEmpty,
      reason:
          'Run under firebase emulators:exec; FIRESTORE_EMULATOR_HOST is unset.',
    );
    final String rules = File('firestore.rules').readAsStringSync();
    const String marker = '// ---- end of collections ----';
    expect(
      rules,
      contains(marker),
      reason: 'the collections marker was removed',
    );
    final String withTests = rules.replaceFirst(marker, '''
    match /t_role/{id} { allow read: if hasRole('admin'); }
    match /t_any/{id} { allow read: if hasAnyRole(['staff', 'admin']); }
    match /t_signed/{id} { allow read: if signedIn(); }
    match /t_stamped/{id} {
      allow create: if stampedCreate() && onlyKeys(['name', 'createdAt', 'createdBy', 'updatedAt', 'updatedBy']);
      allow update: if stampedUpdate();
    }
    $marker''');
    final http.Response put = await http.put(
      Uri.parse('http://$host/emulator/v1/projects/$project:securityRules'),
      body: jsonEncode(<String, Object?>{
        'rules': <String, Object?>{
          'files': <Object?>[
            <String, Object?>{'name': 'firestore.rules', 'content': withTests},
          ],
        },
      }),
    );
    expect(put.statusCode, 200, reason: put.body);
  });

  setUp(() async {
    await http.delete(Uri.parse(docs.replaceFirst('/v1/', '/emulator/v1/')));
    // Seed as the administrator, which rules do not apply to.
    for (final String c in <String>['t_role', 't_any', 't_signed', 'other']) {
      await _write('$docs/$c?documentId=d1', 'owner', <String, Object?>{
        'fields': <String, Object?>{
          'name': <String, Object?>{'stringValue': 'x'},
        },
      });
    }
  });

  Future<int> read(String path, String? token) async => (await http.get(
    Uri.parse('$docs/$path'),
    headers: <String, String>{
      if (token != null) 'authorization': 'Bearer $token',
    },
  )).statusCode;

  test('anything not listed is refused, even to a signed-in admin', () async {
    expect(await read('other/d1', null), 403);
    expect(await read('other/d1', _token('u1', <String>['admin'])), 403);
  });

  test('signedIn: a person, not a visitor', () async {
    expect(await read('t_signed/d1', null), 403);
    expect(await read('t_signed/d1', _token('u1', <String>[])), 200);
  });

  test('hasRole: that role only, and only from the token', () async {
    expect(await read('t_role/d1', _token('u1', <String>['admin'])), 200);
    expect(await read('t_role/d1', _token('u1', <String>['staff'])), 403);
    expect(await read('t_role/d1', _token('u1', null)), 403);
    expect(
      await read('t_role/d1', _token('u1', 'admin')),
      403,
      reason: 'a roles claim that is not a list grants nothing',
    );
  });

  test('hasAnyRole: any one of them', () async {
    expect(await read('t_any/d1', _token('u1', <String>['staff'])), 200);
    expect(await read('t_any/d1', _token('u1', <String>['viewer'])), 403);
  });

  test('stamps must be the person and the server clock', () async {
    Map<String, Object?> commit(
      String name,
      String createdBy, {
      bool serverTime = true,
    }) => <String, Object?>{
      'writes': <Object?>[
        <String, Object?>{
          'update': <String, Object?>{
            'name':
                'projects/$project/databases/(default)/documents/t_stamped/$name',
            'fields': <String, Object?>{
              'name': <String, Object?>{'stringValue': name},
              'createdBy': <String, Object?>{'stringValue': createdBy},
              'updatedBy': <String, Object?>{'stringValue': createdBy},
              if (!serverTime) ...<String, Object?>{
                'createdAt': <String, Object?>{
                  'timestampValue': '2020-01-01T00:00:00Z',
                },
                'updatedAt': <String, Object?>{
                  'timestampValue': '2020-01-01T00:00:00Z',
                },
              },
            },
          },
          if (serverTime)
            'updateTransforms': <Object?>[
              <String, Object?>{
                'fieldPath': 'createdAt',
                'setToServerValue': 'REQUEST_TIME',
              },
              <String, Object?>{
                'fieldPath': 'updatedAt',
                'setToServerValue': 'REQUEST_TIME',
              },
            ],
        },
      ],
    };
    final String me = _token('u1', <String>[]);
    expect(await _commit(docs, me, commit('ok', 'u1')), 200);
    expect(
      await _commit(docs, me, commit('forged', 'u2')),
      403,
      reason: 'createdBy is somebody else',
    );
    expect(
      await _commit(docs, me, commit('backdated', 'u1', serverTime: false)),
      403,
      reason: 'the device clock, not the server\'s',
    );
  });
}

Future<void> _write(String url, String token, Map<String, Object?> body) async {
  final http.Response r = await http.post(
    Uri.parse(url),
    headers: <String, String>{'authorization': 'Bearer $token'},
    body: jsonEncode(body),
  );
  expect(r.statusCode, 200, reason: r.body);
}

Future<int> _commit(
  String docs,
  String token,
  Map<String, Object?> body,
) async => (await http.post(
  Uri.parse('$docs:commit'),
  headers: <String, String>{'authorization': 'Bearer $token'},
  body: jsonEncode(body),
)).statusCode;

/// An unsigned ID token for [uid], with [roles] as the `roles` claim (or no
/// claim when null, or a malformed one when not a list).
String _token(String uid, Object? roles) {
  String b64(Map<String, Object?> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final int now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return '${b64(<String, Object?>{'alg': 'none', 'typ': 'JWT'})}.'
      '${b64(<String, Object?>{
        'iss': 'https://securetoken.google.com/demo-local',
        'aud': 'demo-local',
        'iat': now,
        'exp': now + 3600,
        'auth_time': now,
        'sub': uid,
        'user_id': uid,
        'firebase': <String, Object?>{'sign_in_provider': 'custom', 'identities': <String, Object?>{}},
        'roles': ?roles,
      })}.';
}
