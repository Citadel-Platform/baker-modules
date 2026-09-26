import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A Xero that keeps Xero's rules: refresh tokens rotate and the old one
/// stops working; creates honour Idempotency-Key; filters are one condition.
class FakeXero {
  int refreshes = 0;
  int puts = 0;
  String validRefresh = 'refresh-0';
  int accessSerial = 0;
  final Set<String> validAccess = <String>{};
  final Map<String, Map<String, Object?>> contacts = <String, Map<String, Object?>>{};
  final Map<String, Map<String, Object?>> invoices = <String, Map<String, Object?>>{};
  final Map<String, Object?> seenKeys = <String, Object?>{};
  int failNextWith = 0;
  String? rejectLineWith;

  late final http.Client client = MockClient(_handle);

  Future<http.Response> _handle(http.Request r) async {
    if (r.url.host == 'identity.xero.com' && r.url.path == '/connect/token') {
      final String expected = 'Basic ${base64.encode(utf8.encode('cid:secret'))}';
      if (r.headers['authorization'] != expected) return http.Response('{"error":"invalid_client"}', 401);
      final Map<String, String> form = Uri.splitQueryString(r.body);
      if (form['grant_type'] == 'refresh_token' && form['refresh_token'] != validRefresh) {
        return http.Response('{"error":"invalid_grant"}', 400);
      }
      if (form['grant_type'] == 'authorization_code' && form['code'] != 'good-code') {
        return http.Response('{"error":"invalid_grant"}', 400);
      }
      if (form['grant_type'] == 'refresh_token') refreshes++;
      validRefresh = 'refresh-${refreshes + 1}-${DateTime.now().microsecondsSinceEpoch}';
      final String access = 'access-${++accessSerial}';
      validAccess.add(access);
      return http.Response(
        jsonEncode(<String, Object?>{
          'access_token': access,
          'refresh_token': validRefresh,
          'expires_in': 1800,
          'token_type': 'Bearer',
        }),
        200,
      );
    }
    final String bearer = (r.headers['authorization'] ?? '').replaceFirst('Bearer ', '');
    if (!validAccess.contains(bearer)) return http.Response('{"Title":"Unauthorized"}', 401);
    if (r.url.path == '/connections') {
      return http.Response(
        jsonEncode(<Object?>[
          <String, Object?>{'id': 'conn-1', 'tenantId': 'tenant-1', 'tenantName': 'Acme Pte Ltd', 'tenantType': 'ORGANISATION'},
        ]),
        200,
      );
    }
    if (failNextWith != 0) {
      final int code = failNextWith;
      failNextWith = 0;
      if (code == 401) validAccess.remove(bearer);
      return http.Response('{}', code, headers: <String, String>{if (code == 429) 'retry-after': '17'});
    }
    if (r.headers['xero-tenant-id'] != 'tenant-1') return http.Response('{}', 403);
    final String path = r.url.path.replaceFirst('/api.xro/2.0/', '');
    final String? key = r.headers['idempotency-key'];
    if (key != null && key.length > 128) return http.Response('{"Message":"key too long"}', 400);
    if (key != null && seenKeys.containsKey(key)) return http.Response(jsonEncode(seenKeys[key]), 200);
    final String where = r.url.queryParameters['where'] ?? '';
    if (where.contains(' AND ')) return http.Response('{"Message":"unsupported filter in fake"}', 400);
    String? eq(String field) => RegExp('^$field=="(.*)"\$').firstMatch(where)?.group(1);

    if (path == 'Contacts' && r.method == 'GET') {
      final String? n = eq('ContactNumber');
      return _ok(<String, Object?>{
        'Contacts': <Object?>[for (final Map<String, Object?> c in contacts.values) if (c['ContactNumber'] == n) c],
      });
    }
    if (path == 'Contacts' && r.method == 'PUT') {
      puts++;
      final Map<String, Object?> c = Map<String, Object?>.of(
        ((jsonDecode(r.body) as Map<String, Object?>)['Contacts']! as List<Object?>).first! as Map<String, Object?>,
      );
      c['ContactID'] = '00000000-0000-0000-0000-${(contacts.length + 1).toString().padLeft(12, '0')}';
      contacts['${c['ContactID']}'] = c;
      final Map<String, Object?> body = <String, Object?>{'Contacts': <Object?>[c]};
      if (key != null) seenKeys[key] = body;
      return _ok(body);
    }
    if (path == 'Invoices' && r.method == 'PUT') {
      puts++;
      final Map<String, Object?> i = Map<String, Object?>.of(
        ((jsonDecode(r.body) as Map<String, Object?>)['Invoices']! as List<Object?>).first! as Map<String, Object?>,
      );
      final List<Object?> lines = i['LineItems']! as List<Object?>;
      if (rejectLineWith != null) {
        return http.Response(
          jsonEncode(<String, Object?>{
            'Elements': <Object?>[
              <String, Object?>{
                'ValidationErrors': <Object?>[<String, Object?>{'Message': rejectLineWith}],
              },
            ],
          }),
          400,
        );
      }
      num total = 0;
      for (final Object? l in lines) {
        total += ((l! as Map<String, Object?>)['UnitAmount']! as num) * ((l as Map<String, Object?>)['Quantity']! as num);
      }
      i['InvoiceID'] = '11111111-0000-0000-0000-${(invoices.length + 1).toString().padLeft(12, '0')}';
      i['InvoiceNumber'] = 'INV-${invoices.length + 1}';
      i['Total'] = total;
      i['AmountDue'] = total;
      i['DueDateString'] = '${i['DueDate']}T00:00:00';
      i['Contact'] = <String, Object?>{...(i['Contact']! as Map<String, Object?>), 'Name': 'Customer'};
      invoices['${i['InvoiceID']}'] = i;
      final Map<String, Object?> body = <String, Object?>{'Invoices': <Object?>[i]};
      if (key != null) seenKeys[key] = body;
      return _ok(body);
    }
    if (path == 'Invoices' && r.method == 'GET') {
      final String? ref = eq('Reference');
      final String? type = eq('Type');
      final String? statuses = r.url.queryParameters['Statuses'];
      final List<Map<String, Object?>> all = <Map<String, Object?>>[
        for (final Map<String, Object?> i in invoices.values)
          if ((ref == null || i['Reference'] == ref) &&
              (type == null || i['Type'] == type) &&
              (statuses == null || statuses.split(',').contains(i['Status'])))
            i,
      ];
      final int page = int.tryParse(r.url.queryParameters['page'] ?? '') ?? 0;
      final List<Map<String, Object?>> slice = page == 0
          ? all
          : all.skip((page - 1) * 100).take(100).toList();
      return _ok(<String, Object?>{'Invoices': slice});
    }
    if (path.startsWith('Invoices/') && r.method == 'GET') {
      final Map<String, Object?>? i = invoices[path.substring('Invoices/'.length)];
      return i == null ? http.Response('', 404) : _ok(<String, Object?>{'Invoices': <Object?>[i]});
    }
    return http.Response('{"Message":"not in fake"}', 400);
  }

  http.Response _ok(Object? body) =>
      http.Response(jsonEncode(body), 200, headers: <String, String>{'content-type': 'application/json'});
}
