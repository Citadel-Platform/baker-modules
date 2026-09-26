import 'package:shelf/shelf.dart';

import '../api.dart';
import '../routes/app_routes.dart';
import 'ledger.dart';
import 'ledger_service.dart';

/// The ledger's routes; added to `appRoutes` when the application is
/// bootstrapped.
///
/// People with [ledgerRole] (and Exigence, calling as `EXIGENCE_CALLER`, on
/// the `/service/` routes) may create contacts and **draft** invoices and
/// read invoices and receivables. Only [adminRole] may connect or disconnect
/// the organisation. Nothing here approves, sends, voids or pays.
List<ApiRoute> ledgerRoutes(
  AppContext context, {
  String ledgerRole = 'admin',
  String adminRole = 'admin',
  LedgerService? Function()? service,
}) {
  bool made = false;
  LedgerService? built;
  LedgerService? maybe() {
    if (!made) {
      built = (service ?? () => LedgerService.from(context))();
      made = true;
    }
    return built;
  }

  LedgerService svc() {
    final LedgerService? s = maybe();
    if (s == null) {
      throw const Problem(
        409,
        'ledger_not_configured',
        'No accounting system is configured for this application',
      );
    }
    return s;
  }

  final String exigence = context.environment['EXIGENCE_CALLER'] ?? '';

  Future<Response> contact(ApiCall call) async {
    final Map<String, Object?> b = await _object(call);
    final ContactRequest r = ContactRequest(
      externalRef: _str(b, 'externalRef'),
      name: _str(b, 'name'),
      email: b['email'] as String?,
    );
    return json(
      (await (await svc().ledger()).contact(r)).toJson(),
      status: 201,
    );
  }

  Future<Response> draft(ApiCall call) async {
    final InvoiceRequest r = parseInvoice(await _object(call));
    return json(
      (await (await svc().ledger()).draftInvoice(r)).toJson(),
      status: 201,
    );
  }

  Future<Response> receivables(ApiCall call) async {
    final DateTime asOf = DateTime.now().toUtc();
    final List<LedgerInvoice> open = await (await svc().ledger())
        .openReceivables(asOf: asOf);
    int band(LedgerInvoice i) {
      final int d = i.daysOverdue(asOf);
      return d == 0
          ? 0
          : d <= 30
          ? 1
          : d <= 60
          ? 2
          : d <= 90
          ? 3
          : 4;
    }

    const List<String> names = <String>[
      'current',
      '1-30',
      '31-60',
      '61-90',
      'over 90',
    ];
    final Map<String, Map<String, int>> totals = <String, Map<String, int>>{};
    for (final LedgerInvoice i in open) {
      final Map<String, int> byBand = totals[i.amountDue.currency] ??=
          <String, int>{for (final String n in names) n: 0};
      byBand[names[band(i)]] = byBand[names[band(i)]]! + i.amountDue.minor;
    }
    return json(<String, Object?>{
      'asOf': asOf.toIso8601String().substring(0, 10),
      'totals': totals,
      'invoices': <Object?>[
        for (final LedgerInvoice i in open) i.toJson(asOf: asOf),
      ],
    });
  }

  Future<Response> one(ApiCall call) async {
    final LedgerInvoice? i = await (await svc().ledger()).invoice(
      call.parameters['id']!,
    );
    if (i == null) throw Problem.notFound;
    return json(i.toJson(asOf: DateTime.now().toUtc()));
  }

  final ApiAccess people = ApiAccess.roles(<String>{ledgerRole});
  final ApiAccess admins = ApiAccess.roles(<String>{adminRole});
  final ApiAccess agent = ApiAccess.service(exigence);

  return <ApiRoute>[
    ApiRoute(
      'GET',
      '/v1/ledger/status',
      (_) async {
        final LedgerService? s = maybe();
        if (s == null) {
          return json(<String, Object?>{
            'status': LedgerStatus.notConfigured.name,
          });
        }
        final ({LedgerStatus status, String? organisation, String? detail}) st =
            await s.status();
        return json(<String, Object?>{
          'status': st.status.name,
          'provider': 'xero',
          'organisation': st.organisation,
          'detail': st.detail,
        });
      },
      access: admins,
      summary: 'Whether a ledger is configured, connected and answering.',
    ),
    ApiRoute(
      'POST',
      '/v1/ledger/xero/connect',
      (ApiCall call) async => json(<String, Object?>{
        'url': '${await svc().auth.authorizeUrl(uid: call.signedIn.uid)}',
      }),
      access: admins,
      summary: 'Where to send an administrator to connect a Xero organisation.',
    ),
    ApiRoute(
      'GET',
      '/v1/ledger/xero/callback',
      (ApiCall call) async {
        final Map<String, String> q = call.request.url.queryParameters;
        if (q['error'] != null) {
          return Response.ok(
            'Xero did not connect (${q['error']}). You can close this tab.',
          );
        }
        final ({String tenantId, String tenantName, int organisations}) done =
            await svc().auth.complete(
              code: q['code'] ?? '',
              state: q['state'] ?? '',
            );
        return Response.ok(
          'Connected to ${done.tenantName}.'
          '${done.organisations > 1 ? ' (${done.organisations} organisations were authorised; the first is used.)' : ''}'
          ' You can close this tab.',
        );
      },
      // Xero's redirect carries no sign-in; the one-use state issued to an
      // administrator in /connect is what authorises it.
      access: const ApiAccess.public(),
      summary: "Xero's redirect after an administrator connects.",
    ),
    ApiRoute(
      'DELETE',
      '/v1/ledger/xero',
      (_) async {
        await svc().auth.disconnect();
        return Response(204);
      },
      access: admins,
      summary: 'Disconnects the organisation. Nothing in the books changes.',
    ),
    ApiRoute(
      'POST',
      '/v1/ledger/contacts',
      contact,
      access: people,
      idempotent: true,
      summary: 'A customer, found by reference or created.',
    ),
    ApiRoute(
      'POST',
      '/v1/ledger/invoices',
      draft,
      access: people,
      idempotent: true,
      summary: 'A draft sales invoice, once per reference.',
    ),
    ApiRoute(
      'GET',
      '/v1/ledger/invoices/<id>',
      one,
      access: people,
      summary: 'One invoice as the ledger has it now.',
    ),
    ApiRoute(
      'GET',
      '/v1/ledger/receivables',
      receivables,
      access: people,
      summary: 'Money owed, by age.',
    ),
    ApiRoute(
      'POST',
      '/service/ledger/contacts',
      contact,
      access: agent,
      summary: 'The same, for Exigence.',
    ),
    ApiRoute(
      'POST',
      '/service/ledger/invoices',
      draft,
      access: agent,
      summary: 'The same, for Exigence.',
    ),
    ApiRoute(
      'GET',
      '/service/ledger/receivables',
      receivables,
      access: agent,
      summary: 'The same, for Exigence.',
    ),
  ];
}

/// An invoice request from JSON, each problem named.
InvoiceRequest parseInvoice(Map<String, Object?> b) {
  final Map<String, Object?> c = b['contact'] is Map<String, Object?>
      ? b['contact']! as Map<String, Object?>
      : throw Problem.invalid(
          'contact is required: {externalRef, name, email?}.',
        );
  final List<Object?> lines = b['lines'] is List<Object?>
      ? b['lines']! as List<Object?>
      : throw Problem.invalid('lines is required.');
  return InvoiceRequest(
    externalRef: _str(b, 'externalRef'),
    contact: ContactRequest(
      externalRef: _str(c, 'externalRef'),
      name: _str(c, 'name'),
      email: c['email'] as String?,
    ),
    date: _date(b, 'date'),
    dueDate: _date(b, 'dueDate'),
    tax: switch (b['tax'] ?? 'exclusive') {
      'exclusive' => TaxTreatment.exclusive,
      'inclusive' => TaxTreatment.inclusive,
      'noTax' => TaxTreatment.noTax,
      _ => throw Problem.invalid('tax is exclusive, inclusive or noTax.'),
    },
    lines: <InvoiceLine>[
      for (final Object? l in lines)
        if (l is Map<String, Object?>)
          InvoiceLine(
            description: _str(l, 'description'),
            quantity: l['quantity'] is num
                ? l['quantity']! as num
                : throw Problem.invalid('quantity is a number.'),
            unitAmount: _amount(l, 'unitAmount'),
            accountCode: _str(l, 'accountCode'),
            taxType: l['taxType'] as String?,
          )
        else
          throw Problem.invalid('Each line is an object.'),
    ],
  );
}

Future<Map<String, Object?>> _object(ApiCall call) async {
  final Object? d = await JsonBody.read(
    call.request,
  ).then((JsonBody b) => b.raw);
  return d! as Map<String, Object?>;
}

String _str(Map<String, Object?> m, String k) {
  final Object? v = m[k];
  if (v is String && v.trim().isNotEmpty) return v;
  throw Problem.invalid('$k is required.');
}

DateTime _date(Map<String, Object?> m, String k) {
  final String s = _str(m, k);
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s)) {
    throw Problem.invalid('$k is YYYY-MM-DD.');
  }
  return DateTime.parse('${s}T00:00:00Z');
}

Amount _amount(Map<String, Object?> m, String k) {
  final Object? v = m[k];
  if (v is Map &&
      v['minor'] is int &&
      v['currency'] is String &&
      RegExp(r'^[A-Z]{3}$').hasMatch(v['currency']! as String)) {
    return Amount(v['minor']! as int, v['currency']! as String);
  }
  throw Problem.invalid(
    '$k is {minor, currency}, e.g. {"minor": 12050, "currency": "SGD"}.',
  );
}
