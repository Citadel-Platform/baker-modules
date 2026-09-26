@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:api/api.dart';
import 'package:api/ledger/ledger.dart';
import 'package:api/ledger/token_store.dart';
import 'package:api/ledger/xero_auth.dart';
import 'package:api/ledger/xero_ledger.dart';
import 'package:googleapis/firestore/v1.dart' as fs;
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '../test/ledger/fake_xero.dart';

/// The Xero ledger against the Firestore emulator (connection, OAuth state,
/// refresh lock) and a Xero that keeps Xero's rules.
///
///     firebase emulators:exec --only firestore --project demo-local \
///       "cd api && dart test test_emulator/ledger_test.dart"
void main() {
  final String host = Platform.environment['FIRESTORE_EMULATOR_HOST'] ?? '';
  late AppFirestore db;
  late FakeXero xero;
  late MemoryTokenStore tokens;
  late DateTime now;

  setUpAll(() => expect(host, isNotEmpty, reason: 'Run under firebase emulators:exec.'));

  setUp(() {
    db = AppFirestore(
      fs.FirestoreApi(_Owner(), rootUrl: 'http://$host/'),
      projectId: 'demo-ledger-${DateTime.now().microsecondsSinceEpoch}',
    );
    xero = FakeXero();
    tokens = MemoryTokenStore();
    now = DateTime.now().toUtc();
  });

  XeroAuth auth() => XeroAuth(
    client: xero.client,
    clientId: 'cid',
    clientSecret: 'secret',
    redirectUri: 'https://api.test/v1/ledger/xero/callback',
    tokens: tokens,
    db: db,
    clock: () => now,
  );

  Future<XeroAuth> connected() async {
    final XeroAuth a = auth();
    final Uri url = await a.authorizeUrl(uid: 'admin-1');
    await a.complete(code: 'good-code', state: url.queryParameters['state']!);
    return a;
  }

  InvoiceRequest request({String ref = 'job/42'}) => InvoiceRequest(
    externalRef: ref,
    contact: ContactRequest(externalRef: 'cust-7', name: 'Ann Tan', email: 'ann@example.com'),
    date: DateTime.utc(2026, 9, 27),
    dueDate: DateTime.utc(2026, 10, 27),
    lines: <InvoiceLine>[
      InvoiceLine(description: 'Tuition, September', quantity: 4, unitAmount: const Amount(6000, 'SGD'), accountCode: '200'),
    ],
  );

  group('connecting', () {
    test('the authorize link asks for offline access, with a one-use state', () async {
      final Uri url = await auth().authorizeUrl(uid: 'admin-1');
      expect(url.host, 'login.xero.com');
      expect(url.queryParameters['scope'], contains('offline_access'));
      expect(url.queryParameters['state']!.length, greaterThanOrEqualTo(40));

      final XeroAuth a = auth();
      final ({String tenantId, String tenantName, int organisations}) done =
          await a.complete(code: 'good-code', state: url.queryParameters['state']!);
      expect(done.tenantName, 'Acme Pte Ltd');
      expect(tokens.token, xero.validRefresh);
      expect((await db.get(XeroAuth.connection))!['connectedBy'], 'admin-1');

      await expectLater(
        a.complete(code: 'good-code', state: url.queryParameters['state']!),
        throwsA(isA<Problem>().having((Problem p) => p.code, 'code', 'bad_state')),
      );
    });

    test('an expired or invented state is refused', () async {
      final Uri url = await auth().authorizeUrl(uid: 'admin-1');
      now = now.add(const Duration(minutes: 11));
      await expectLater(
        auth().complete(code: 'good-code', state: url.queryParameters['state']!),
        throwsA(isA<Problem>()),
      );
      await expectLater(auth().complete(code: 'good-code', state: 'made-up'), throwsA(isA<Problem>()));
    });
  });

  group('tokens', () {
    test('a refresh rotates and stores the new token before use', () async {
      await connected();
      now = now.add(const Duration(minutes: 31));
      final XeroAuth fresh = auth();
      await fresh.accessToken();
      expect(xero.refreshes, 1);
      expect(tokens.token, xero.validRefresh, reason: 'the stored token is the one Xero now accepts');
    });

    test('two instances refreshing at once do not burn each other\'s token', () async {
      await connected();
      now = now.add(const Duration(minutes: 31));
      final List<String> got = await Future.wait(<Future<String>>[auth().accessToken(), auth().accessToken()]);
      expect(got, everyElement(startsWith('access-')));
      expect(tokens.token, xero.validRefresh);
    });

    test('a revoked connection reads as not connected, and is forgotten', () async {
      await connected();
      xero.validRefresh = 'revoked';
      now = now.add(const Duration(minutes: 31));
      await expectLater(auth().accessToken(), throwsA(isA<LedgerNotConnected>()));
      expect(tokens.token, isNull);
    });
  });

  group('writes', () {
    late XeroLedger ledger;
    setUp(() async {
      ledger = XeroLedger(client: xero.client, auth: await connected(), tenantId: 'tenant-1');
    });

    test('the same draft twice is one invoice and one contact', () async {
      final LedgerInvoice a = await ledger.draftInvoice(request());
      final LedgerInvoice b = await ledger.draftInvoice(request());
      expect(b.ledgerId, a.ledgerId);
      expect(a.state, InvoiceState.draft);
      expect(a.total, const Amount(24000, 'SGD'));
      expect(xero.invoices, hasLength(1));
      expect(xero.contacts, hasLength(1));
      expect(xero.contacts.values.single['ContactNumber'], 'citadel-cust-7');
      expect(xero.invoices.values.single['Status'], 'DRAFT', reason: 'never approved or sent');
      expect(xero.invoices.values.single['Reference'], 'job/42');
    });

    test('a refused token is refreshed once and the call repeated', () async {
      xero.failNextWith = 401;
      final LedgerInvoice i = await ledger.draftInvoice(request(ref: 'job/43'));
      expect(i.state, InvoiceState.draft);
      expect(xero.refreshes, 1);
    });

    test("Xero's rate limit is passed on with its wait", () async {
      xero.failNextWith = 429;
      await expectLater(
        ledger.draftInvoice(request(ref: 'job/44')),
        throwsA(isA<LedgerUnavailable>().having((LedgerUnavailable p) => p.headers['retry-after'], 'retry-after', '17')),
      );
    });

    test("Xero's validation message reaches the caller", () async {
      xero.rejectLineWith = 'Account code 999 is not a valid code for this document.';
      await expectLater(
        ledger.draftInvoice(request(ref: 'job/45')),
        throwsA(isA<Problem>().having((Problem p) => p.detail, 'detail', contains('Account code 999'))),
      );
    });

    test('receivables: approved, owed, oldest first, across pages', () async {
      // 250 invoices: 125 approved, so the approved ones span two of Xero's
      // 100-invoice pages.
      int expected = 0;
      for (int i = 0; i < 250; i++) {
        final bool approved = i.isEven;
        final bool owing = i % 4 != 0;
        if (approved && owing) expected++;
        xero.invoices['id-$i'] = <String, Object?>{
          'InvoiceID': 'id-$i',
          'Type': 'ACCREC',
          'Status': approved ? 'AUTHORISED' : 'DRAFT',
          'Total': 10,
          'AmountDue': owing ? 10 : 0,
          'CurrencyCode': 'SGD',
          'DueDateString': '2026-${(i % 9 + 1).toString().padLeft(2, '0')}-01T00:00:00',
        };
      }
      final List<LedgerInvoice> open = await ledger.openReceivables();
      expect(open, hasLength(expected));
      expect(open.every((LedgerInvoice i) => i.amountDue.minor > 0), isTrue);
      for (int i = 1; i < open.length; i++) {
        expect(open[i].dueDate!.isBefore(open[i - 1].dueDate!), isFalse);
      }
    });
  });
}

class _Owner extends http.BaseClient {
  final http.Client _inner = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['authorization'] = 'Bearer owner';
    return _inner.send(request);
  }
}
