import 'package:api/api.dart';
import 'package:api/ledger/ledger.dart';
import 'package:api/ledger/ledger_routes.dart';
import 'package:api/ledger/xero_ledger.dart';
import 'package:test/test.dart';

void main() {
  test('amounts convert to and from a ledger decimal exactly', () {
    expect(Amount.fromDecimal(12.3, 'SGD'), const Amount(1230, 'SGD'));
    expect(Amount.fromDecimal(0.1 + 0.2, 'SGD'), const Amount(30, 'SGD'));
    expect(const Amount(-1205, 'SGD').toDecimal(), -12.05);
    expect(const Amount(5, 'SGD').toDecimal(), 0.05);
    expect(const Amount(500, 'JPY').toDecimal(decimals: 0), 500);
  });

  test("Xero's two date forms", () {
    expect(xeroDate('/Date(1790380800000+0000)/'), DateTime.fromMillisecondsSinceEpoch(1790380800000, isUtc: true));
    expect(xeroDate('2026-10-27T00:00:00'), DateTime.utc(2026, 10, 27));
    expect(xeroDate(null), isNull);
  });

  test('validation messages from either shape', () {
    expect(
      validationMessages(<String, Object?>{
        'Elements': <Object?>[
          <String, Object?>{
            'ValidationErrors': <Object?>[<String, Object?>{'Message': 'Account code 999 is not a valid code.'}],
          },
        ],
      }),
      <String>['Account code 999 is not a valid code.'],
    );
    expect(validationMessages(<String, Object?>{'Message': 'Nope'}), <String>['Nope']);
  });

  group('parseInvoice refuses what it cannot use, saying what', () {
    Map<String, Object?> good() => <String, Object?>{
      'externalRef': 'job/42',
      'contact': <String, Object?>{'externalRef': 'cust-7', 'name': 'Ann'},
      'date': '2026-09-27',
      'dueDate': '2026-10-27',
      'lines': <Object?>[
        <String, Object?>{
          'description': 'Tuition, September',
          'quantity': 4,
          'unitAmount': <String, Object?>{'minor': 6000, 'currency': 'SGD'},
          'accountCode': '200',
        },
      ],
    };

    test('a good request', () {
      final InvoiceRequest r = parseInvoice(good());
      expect(r.currency, 'SGD');
      expect(r.lines.single.unitAmount, const Amount(6000, 'SGD'));
    });

    void refused(void Function(Map<String, Object?> m) change, String says) {
      final Map<String, Object?> m = good();
      change(m);
      expect(
        () => parseInvoice(m),
        throwsA(isA<Problem>().having((Problem p) => p.detail, 'detail', contains(says))),
      );
    }

    test('each problem', () {
      refused((Map<String, Object?> m) => m['externalRef'] = 'has space', 'reference');
      refused((Map<String, Object?> m) => m['externalRef'] = 'x"==""', 'reference');
      refused((Map<String, Object?> m) => m['dueDate'] = '2026-09-01', 'before');
      refused((Map<String, Object?> m) => m['date'] = '27/09/2026', 'YYYY-MM-DD');
      refused((Map<String, Object?> m) => m['lines'] = <Object?>[], 'between 1 and 200');
      refused(
        (Map<String, Object?> m) => ((m['lines']! as List<Object?>).first! as Map<String, Object?>)['unitAmount'] = 60.0,
        '{minor, currency}',
      );
      refused((Map<String, Object?> m) => m.remove('contact'), 'contact');
    });
  });
}
