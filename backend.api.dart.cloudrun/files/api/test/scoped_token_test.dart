import 'dart:convert';

import 'package:api/api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test(
    'asks the metadata server for the scopes, and reuses the token',
    () async {
      DateTime now = DateTime(2026, 1, 1);
      final List<Uri> asked = <Uri>[];
      final List<String?> sentWith = <String?>[];
      final ScopedMetadataClient client = ScopedMetadataClient(
        MockClient((http.Request r) async {
          if (r.url.host == 'metadata.google.internal') {
            asked.add(r.url);
            expect(r.headers['Metadata-Flavor'], 'Google');
            return http.Response(
              jsonEncode(<String, Object?>{
                'access_token': 't${asked.length}',
                'expires_in': 3600,
              }),
              200,
            );
          }
          sentWith.add(r.headers['authorization']);
          return http.Response('{}', 200);
        }),
        scopes: <String>['https://www.googleapis.com/auth/spreadsheets'],
        clock: () => now,
      );
      await client.get(Uri.parse('https://sheets.googleapis.com/v4/x'));
      await client.get(Uri.parse('https://sheets.googleapis.com/v4/y'));
      expect(asked, hasLength(1));
      expect(
        asked.single.queryParameters['scopes'],
        'https://www.googleapis.com/auth/spreadsheets',
      );
      expect(sentWith, <String>['Bearer t1', 'Bearer t1']);

      now = now.add(const Duration(minutes: 59, seconds: 30));
      await client.get(Uri.parse('https://sheets.googleapis.com/v4/z'));
      expect(asked, hasLength(2), reason: 'refreshed a minute before expiry');
      expect(sentWith.last, 'Bearer t2');
    },
  );

  test(
    'a refused token request is an error, not an unauthenticated call',
    () async {
      final ScopedMetadataClient client = ScopedMetadataClient(
        MockClient((_) async => http.Response('', 404)),
        scopes: <String>['s'],
      );
      await expectLater(
        client.get(Uri.parse('https://x.test/')),
        throwsStateError,
      );
    },
  );
}
