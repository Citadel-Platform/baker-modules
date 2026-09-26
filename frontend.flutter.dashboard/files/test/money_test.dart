import 'package:{{baker.packageName}}/src/money/chart_scale.dart';
import 'package:{{baker.packageName}}/src/money/money.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Money sgd(int cents) => Money(minor: cents, currency: 'SGD');

  group('Money', () {
    test('parses exactly, with no floating point on the way', () {
      expect(Money.parse('0.1', 'SGD') + Money.parse('0.2', 'SGD'), sgd(30));
      expect(Money.parse('1234.5', 'SGD').minor, 123450);
      expect(Money.parse('-7', 'SGD').minor, -700);
      expect(Money.parse('500', 'JPY').minor, 500);
      expect(Money.parse('1.234', 'KWD').minor, 1234);
    });

    test('refuses what is not an amount, or has too many places', () {
      for (final String bad in <String>[
        '',
        'abc',
        '1,234.00',
        '1.2.3',
        '1e5',
        ' . ',
      ]) {
        expect(
          () => Money.parse(bad, 'SGD'),
          throwsFormatException,
          reason: bad,
        );
      }
      expect(() => Money.parse('1.005', 'SGD'), throwsFormatException);
      expect(() => Money.parse('1.5', 'JPY'), throwsFormatException);
      expect(
        () => Money.parse('99999999999999999999', 'SGD'),
        throwsFormatException,
      );
    });

    test('will not combine currencies', () {
      expect(
        () => sgd(100) + Money(minor: 100, currency: 'USD'),
        throwsArgumentError,
      );
      expect(
        () => sgd(100).compareTo(Money(minor: 100, currency: 'USD')),
        throwsArgumentError,
      );
    });

    test('allocation never gains or loses a cent', () {
      expect(sgd(10000).allocate(<int>[1, 1, 1]), <Money>[
        sgd(3334),
        sgd(3333),
        sgd(3333),
      ]);
      for (final int amount in <int>[1, 7, 99, 10001, -10000]) {
        for (final List<int> ratios in <List<int>>[
          <int>[1, 1, 1],
          <int>[3, 7],
          <int>[1, 0, 2],
          <int>[5],
        ]) {
          final List<Money> parts = sgd(amount).allocate(ratios);
          expect(
            sumMoney(parts, 'SGD'),
            sgd(amount),
            reason: '$amount $ratios',
          );
        }
      }
      expect(() => sgd(1).allocate(<int>[]), throwsArgumentError);
      expect(() => sgd(1).allocate(<int>[0, 0]), throwsArgumentError);
    });

    test('portions round half to even', () {
      // 9% of 150 cents is 13.5 → 14 (even); of 250 cents, 22.5 → 22.
      expect(sgd(150).portion(900), sgd(14));
      expect(sgd(250).portion(900), sgd(22));
      expect(sgd(-150).portion(900), sgd(-14));
      expect(sgd(10000).portion(825), sgd(825));
    });

    test('decimal strings are exact and keep their places', () {
      expect(sgd(123450).toDecimalString(), '1234.50');
      expect(sgd(-5).toDecimalString(), '-0.05');
      expect(Money(minor: 500, currency: 'JPY').toDecimalString(), '500');
      expect(Money(minor: 1, currency: 'KWD').toDecimalString(), '0.001');
    });

    test('formats in the locale, with the currency\'s places', () {
      expect(sgd(123450).format(locale: 'en_SG'), contains('1,234.50'));
      expect(
        Money(minor: 1500, currency: 'JPY').format(locale: 'en_US'),
        contains('1,500'),
      );
    });

    test('a malformed currency code is refused', () {
      expect(() => Money(minor: 1, currency: 'sgd'), throwsArgumentError);
    });
  });

  group('NiceScale', () {
    test('rounds an axis to readable steps from zero', () {
      final NiceScale s = NiceScale.of(12, 947);
      expect(s.min, 0);
      // 947 over at most five intervals: a step of 200 reaches 1000 in five.
      expect(s.step, 200);
      expect(s.max, 1000);
      expect(s.ticks, <double>[0, 200, 400, 600, 800, 1000]);
      expect(NiceScale.of(0, 2300).step, 500);
    });

    test('holds negative data, and a flat series still has an axis', () {
      final NiceScale s = NiceScale.of(-320, 480);
      expect(s.min, lessThanOrEqualTo(-320));
      expect(s.max, greaterThanOrEqualTo(480));
      expect(NiceScale.of(0, 0).max, greaterThan(0));
      expect(NiceScale.of(50, 50).max, greaterThanOrEqualTo(50));
    });

    test('ticks do not accumulate rounding error', () {
      final NiceScale s = NiceScale.of(0, 0.7);
      expect(s.ticks.last, s.max);
    });

    test('compact labels', () {
      expect(compactAxisLabel(1500), '1.5K');
      expect(compactAxisLabel(2000000), '2M');
      expect(compactAxisLabel(-250), '-250');
    });
  });
}
