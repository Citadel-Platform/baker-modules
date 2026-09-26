import 'dart:convert';

import 'package:api/api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  // A real certificate is needed to parse; these tests are about when keys
  // are fetched, so an empty set stands in for Google's.
  test('keys are cached for max-age, then fetched again', () async {
    int fetches = 0;
    DateTime now = DateTime(2026, 1, 1);
    final GoogleOidcKeys keys = GoogleOidcKeys(
      MockClient((http.Request r) async {
        fetches++;
        return http.Response(
          jsonEncode(<String, Object?>{'keys': <Object?>[]}),
          200,
          headers: <String, String>{'cache-control': 'public, max-age=600'},
        );
      }),
      clock: () => now,
    );
    await keys.current();
    await keys.current();
    expect(fetches, 1);
    now = now.add(const Duration(minutes: 11));
    await keys.current();
    expect(fetches, 2);
  });

  test('an unknown key id refetches early, at most once a minute', () async {
    int fetches = 0;
    DateTime now = DateTime(2026, 1, 1);
    final GoogleOidcKeys keys = GoogleOidcKeys(
      MockClient((_) async {
        fetches++;
        return http.Response(
          '{"keys":[]}',
          200,
          headers: <String, String>{'cache-control': 'max-age=3600'},
        );
      }),
      clock: () => now,
    );
    await keys.current();
    now = now.add(const Duration(seconds: 30));
    await keys.current(unknownKeyId: true);
    expect(fetches, 1, reason: 'junk key ids cannot force a fetch each');
    now = now.add(const Duration(seconds: 61));
    await keys.current(unknownKeyId: true);
    expect(fetches, 2);
  });

  test('a failed fetch is an error, not an empty key set', () async {
    final GoogleOidcKeys keys = GoogleOidcKeys(
      MockClient((_) async => http.Response('', 503)),
    );
    await expectLater(keys.current(), throwsStateError);
  });
}
