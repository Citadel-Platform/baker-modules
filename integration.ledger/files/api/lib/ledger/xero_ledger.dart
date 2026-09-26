import 'dart:convert';

import 'package:http/http.dart' as http;

import '../api.dart';
import 'ledger.dart';
import 'xero_auth.dart';

/// [Ledger] on Xero's Accounting API (`api.xero.com/api.xro/2.0`).
///
/// Written against Xero's published OpenAPI description (v19, September
/// 2026). Idempotent twice over: before creating, it looks for a document
/// already carrying the Citadel reference (a contact's `ContactNumber`, an
/// invoice's `Reference`); the create itself carries Xero's
/// `Idempotency-Key`, derived from the reference, for the window in which a
/// retry could race the first attempt.
class XeroLedger implements Ledger {
  XeroLedger({
    required this.client,
    required this.auth,
    required this.tenantId,
    Uri? api,
  }) : api = api ?? Uri.parse('https://api.xero.com/api.xro/2.0/');

  final http.Client client;
  final XeroAuth auth;
  final String tenantId;
  final Uri api;

  static const String contactPrefix = 'citadel-';

  @override
  Future<LedgerContact> contact(ContactRequest c) async {
    final String number = '$contactPrefix${c.externalRef}';
    final Map<String, Object?> found = await _call(
      'GET',
      'Contacts',
      query: <String, String>{'where': 'ContactNumber=="$number"'},
    );
    final List<Object?> existing =
        (found['Contacts'] as List<Object?>?) ?? const <Object?>[];
    if (existing.isNotEmpty) {
      final Map<String, Object?> x = existing.first! as Map<String, Object?>;
      return LedgerContact(
        ledgerId: '${x['ContactID']}',
        name: '${x['Name']}',
        externalRef: c.externalRef,
      );
    }
    final Map<String, Object?> made = await _call(
      'PUT',
      'Contacts',
      idempotencyKey: writeKey('contact', c.externalRef).substring(0, 64),
      body: <String, Object?>{
        'Contacts': <Object?>[
          <String, Object?>{
            'Name': c.name,
            'ContactNumber': number,
            'EmailAddress': ?c.email,
          },
        ],
      },
    );
    final Map<String, Object?> x =
        (made['Contacts']! as List<Object?>).first! as Map<String, Object?>;
    return LedgerContact(
      ledgerId: '${x['ContactID']}',
      name: '${x['Name']}',
      externalRef: c.externalRef,
    );
  }

  @override
  Future<LedgerInvoice> draftInvoice(InvoiceRequest r) async {
    final LedgerInvoice? existing = await _byReference(r.externalRef);
    if (existing != null) return existing;
    final LedgerContact who = await contact(r.contact);
    final Map<String, Object?> made = await _call(
      'PUT',
      'Invoices',
      idempotencyKey: writeKey('invoice', r.externalRef).substring(0, 64),
      body: <String, Object?>{
        'Invoices': <Object?>[
          <String, Object?>{
            'Type': 'ACCREC',
            'Status': 'DRAFT',
            'Contact': <String, Object?>{'ContactID': who.ledgerId},
            'Reference': r.externalRef,
            'Date': _day(r.date),
            'DueDate': _day(r.dueDate),
            'CurrencyCode': r.currency,
            'LineAmountTypes': switch (r.tax) {
              TaxTreatment.exclusive => 'Exclusive',
              TaxTreatment.inclusive => 'Inclusive',
              TaxTreatment.noTax => 'NoTax',
            },
            'LineItems': <Object?>[
              for (final InvoiceLine l in r.lines)
                <String, Object?>{
                  'Description': l.description,
                  'Quantity': l.quantity,
                  'UnitAmount': l.unitAmount.toDecimal(),
                  'AccountCode': l.accountCode,
                  'TaxType': ?l.taxType,
                },
            ],
          },
        ],
      },
    );
    return _invoice(
      (made['Invoices']! as List<Object?>).first! as Map<String, Object?>,
    );
  }

  @override
  Future<LedgerInvoice?> invoice(String ledgerId) async {
    if (!RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(ledgerId)) {
      throw Problem.invalid('Not a Xero invoice id.');
    }
    try {
      final Map<String, Object?> r = await _call('GET', 'Invoices/$ledgerId');
      final List<Object?> list =
          (r['Invoices'] as List<Object?>?) ?? const <Object?>[];
      return list.isEmpty
          ? null
          : _invoice(list.first! as Map<String, Object?>);
    } on Problem catch (p) {
      if (p.status == 404) return null;
      rethrow;
    }
  }

  @override
  Future<List<LedgerInvoice>> openReceivables({DateTime? asOf}) async {
    final List<LedgerInvoice> open = <LedgerInvoice>[];
    for (int page = 1; page <= 50; page++) {
      final Map<String, Object?> r = await _call(
        'GET',
        'Invoices',
        // One condition per filter, as Xero's description shows them; the
        // rest is filtered here.
        query: <String, String>{
          'Statuses': 'AUTHORISED',
          'where': 'Type=="ACCREC"',
          'page': '$page',
        },
      );
      final List<Object?> batch =
          (r['Invoices'] as List<Object?>?) ?? const <Object?>[];
      for (final Object? i in batch) {
        final LedgerInvoice inv = _invoice(i! as Map<String, Object?>);
        if (inv.amountDue.minor > 0) open.add(inv);
      }
      // Xero pages by 100.
      if (batch.length < 100) break;
    }
    open.sort(
      (LedgerInvoice a, LedgerInvoice b) =>
          (a.dueDate ?? DateTime(9999)).compareTo(b.dueDate ?? DateTime(9999)),
    );
    return open;
  }

  Future<LedgerInvoice?> _byReference(String ref) async {
    final Map<String, Object?> r = await _call(
      'GET',
      'Invoices',
      query: <String, String>{'where': 'Reference=="$ref"'},
    );
    final List<Object?> list =
        (r['Invoices'] as List<Object?>?) ?? const <Object?>[];
    for (final Object? i in list) {
      if ((i! as Map<String, Object?>)['Type'] != 'ACCREC') continue;
      final LedgerInvoice inv = _invoice(i as Map<String, Object?>);
      // A deleted or voided draft does not count as made.
      if (inv.state != InvoiceState.deleted && inv.state != InvoiceState.voided) {
        return inv;
      }
    }
    return null;
  }

  LedgerInvoice _invoice(Map<String, Object?> x) {
    final String currency = '${x['CurrencyCode'] ?? 'SGD'}';
    return LedgerInvoice(
      ledgerId: '${x['InvoiceID']}',
      number: x['InvoiceNumber'] as String?,
      state: switch ('${x['Status']}') {
        'DRAFT' => InvoiceState.draft,
        'SUBMITTED' => InvoiceState.submitted,
        'AUTHORISED' => InvoiceState.authorised,
        'PAID' => InvoiceState.paid,
        'VOIDED' => InvoiceState.voided,
        'DELETED' => InvoiceState.deleted,
        _ => InvoiceState.unknown,
      },
      total: Amount.fromDecimal((x['Total'] as num?) ?? 0, currency),
      amountDue: Amount.fromDecimal((x['AmountDue'] as num?) ?? 0, currency),
      contactName: (x['Contact'] as Map<String, Object?>?)?['Name'] as String?,
      dueDate: xeroDate(x['DueDateString'] ?? x['DueDate']),
      externalRef: x['Reference'] as String?,
    );
  }

  Future<Map<String, Object?>> _call(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    String? idempotencyKey,
    bool retried = false,
  }) async {
    final Uri uri = api.resolve(path).replace(queryParameters: query);
    final http.Request request = http.Request(method, uri)
      ..headers.addAll(<String, String>{
        'authorization': 'Bearer ${await auth.accessToken()}',
        'xero-tenant-id': tenantId,
        'accept': 'application/json',
        if (body != null) 'content-type': 'application/json',
        'Idempotency-Key': ?idempotencyKey,
      });
    if (body != null) request.body = jsonEncode(body);
    final http.Response r;
    try {
      r = await http.Response.fromStream(
        await client.send(request),
      ).timeout(const Duration(seconds: 30));
    } on Exception catch (e) {
      throw LedgerUnavailable('no answer from Xero (${e.runtimeType})');
    }
    if (r.statusCode == 401 && !retried) {
      auth.forget();
      return _call(
        method,
        path,
        query: query,
        body: body,
        idempotencyKey: idempotencyKey,
        retried: true,
      );
    }
    if (r.statusCode == 429) {
      throw LedgerUnavailable(
        'Xero rate limit',
        retryAfterSeconds: int.tryParse(r.headers['retry-after'] ?? '') ?? 60,
      );
    }
    if (r.statusCode >= 500 || r.statusCode == 401) {
      throw LedgerUnavailable('Xero answered ${r.statusCode}');
    }
    if (r.statusCode == 404) throw Problem.notFound;
    final Object? decoded = r.body.isEmpty ? null : jsonDecode(r.body);
    if (r.statusCode >= 400) {
      final List<String> said = validationMessages(decoded);
      throw Problem(
        422,
        'ledger_refused',
        'The accounting system refused it',
        detail: said.isEmpty
            ? 'Xero answered ${r.statusCode}.'
            : said.join(' '),
      );
    }
    return decoded is Map<String, Object?>
        ? decoded
        : const <String, Object?>{};
  }

  String _day(DateTime d) => d.toUtc().toIso8601String().substring(0, 10);
}

/// Xero's validation messages, from `Elements[].ValidationErrors[].Message`
/// or a top-level `Message`.
List<String> validationMessages(Object? body) {
  if (body is! Map) return const <String>[];
  final List<String> out = <String>[
    for (final Object? e
        in (body['Elements'] as List<Object?>?) ?? const <Object?>[])
      if (e is Map)
        for (final Object? v
            in (e['ValidationErrors'] as List<Object?>?) ?? const <Object?>[])
          if (v is Map && v['Message'] is String) v['Message']! as String,
  ];
  if (out.isEmpty && body['Message'] is String) {
    out.add(body['Message']! as String);
  }
  return out;
}

/// Xero's two date forms: `2026-10-27T00:00:00` and `/Date(1790000000000+0000)/`.
DateTime? xeroDate(Object? v) {
  if (v is! String) return null;
  final RegExpMatch? ms = RegExp(r'/Date\((-?\d+)').firstMatch(v);
  if (ms != null) {
    return DateTime.fromMillisecondsSinceEpoch(
      int.parse(ms.group(1)!),
      isUtc: true,
    );
  }
  final DateTime? d = DateTime.tryParse(v);
  return d == null ? null : DateTime.utc(d.year, d.month, d.day);
}
