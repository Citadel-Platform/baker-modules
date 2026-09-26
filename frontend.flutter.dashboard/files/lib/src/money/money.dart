import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

/// An amount of one currency, as a whole number of its smallest unit.
///
/// Never a `double`. 0.1 + 0.2 is not 0.3 in binary floating point, and an
/// invoice total that is off by a cent after a hundred lines is how a client
/// stops trusting every other number on the screen. Arithmetic here is exact;
/// only [format] converts, and only for display.
///
/// Mixing currencies is refused rather than converted: a conversion needs a
/// rate, a date and a source, none of which an addition has.
///
/// Written by hand rather than with freezed, unlike other data classes: the
/// currency is checked in every build, and a generated `copyWith` would be a
/// way round that check.
@immutable
final class Money implements Comparable<Money> {
  /// [minor] in the currency's smallest unit: cents for SGD, yen for JPY.
  Money({required this.minor, required this.currency}) {
    if (!isCurrencyCode(currency)) {
      throw ArgumentError.value(
        currency,
        'currency',
        'must be an ISO 4217 code, three capital letters',
      );
    }
  }

  final int minor;
  final String currency;

  @override
  bool operator ==(Object other) =>
      other is Money && other.minor == minor && other.currency == currency;

  @override
  int get hashCode => Object.hash(minor, currency);

  @override
  String toString() => '${toDecimalString()} $currency';

  factory Money.zero(String currency) => Money(minor: 0, currency: currency);

  /// Parses a decimal string exactly: "1234.5" SGD is 123450 cents.
  ///
  /// Refuses more decimal places than the currency has — "1.005" SGD is not an
  /// amount of money, it is a rounding decision somebody has not made — and
  /// anything that is not a plain number. Thousands separators are refused
  /// too: whether "1,234" is a thousand or one-point-two depends on the locale.
  factory Money.parse(String input, String currency) {
    final String text = input.trim();
    final RegExpMatch? match = _decimal.firstMatch(text);
    if (match == null) {
      throw FormatException('"$input" is not an amount.');
    }
    final int exponent = currencyExponent(currency);
    final String whole = match.group(2)!;
    final String fraction = match.group(3) ?? '';
    if (fraction.length > exponent) {
      throw FormatException(
        '$currency has $exponent decimal place${exponent == 1 ? '' : 's'}; '
        '"$input" has ${fraction.length}.',
      );
    }
    final String padded = fraction.padRight(exponent, '0');
    final BigInt minor =
        BigInt.parse(whole) * BigInt.from(10).pow(exponent) +
        BigInt.parse(padded.isEmpty ? '0' : padded);
    if (minor > _maxExact) {
      throw FormatException('"$input" is too large.');
    }
    final int value = minor.toInt();
    return Money(
      minor: match.group(1) == '-' ? -value : value,
      currency: currency,
    );
  }

  /// The largest whole number every platform holds exactly. On the web an
  /// `int` is a JavaScript number, exact to 2^53: ninety trillion in cents.
  static final BigInt _maxExact = BigInt.from(9007199254740991);

  static final RegExp _decimal = RegExp(r'^([-+]?)(\d+)(?:\.(\d+))?$');

  int get exponent => currencyExponent(currency);
  bool get isZero => minor == 0;
  bool get isNegative => minor < 0;

  Money operator +(Money other) =>
      Money(minor: minor + _same(other).minor, currency: currency);

  Money operator -(Money other) =>
      Money(minor: minor - _same(other).minor, currency: currency);

  Money operator -() => Money(minor: -minor, currency: currency);

  Money times(int factor) => Money(minor: minor * factor, currency: currency);

  /// A share in basis points (1% = 100), rounded half to even — the rounding
  /// that does not drift upward when applied across many amounts.
  Money portion(int basisPoints) {
    final int product = minor * basisPoints;
    return Money(minor: _divideHalfEven(product, 10000), currency: currency);
  }

  /// Splits into parts in proportion to [ratios], summing exactly to this.
  ///
  /// Largest remainder: every part gets its floor, and the cents left over go
  /// one each to the parts with the largest remainders. Splitting $100 three
  /// ways is 33.34, 33.33, 33.33 — never three 33.33s and a lost cent.
  List<Money> allocate(List<int> ratios) {
    if (ratios.isEmpty || ratios.any((int r) => r < 0)) {
      throw ArgumentError.value(
        ratios,
        'ratios',
        'must be non-negative, and at least one',
      );
    }
    final int total = ratios.fold(0, (int a, int b) => a + b);
    if (total == 0) {
      throw ArgumentError.value(ratios, 'ratios', 'must not all be zero');
    }
    final int sign = minor < 0 ? -1 : 1;
    final int amount = minor.abs();
    final List<int> parts = <int>[
      for (final int r in ratios) amount * r ~/ total,
    ];
    final List<int> order = List<int>.generate(ratios.length, (int i) => i)
      ..sort((int a, int b) {
        final int byRemainder = (amount * ratios[b] % total).compareTo(
          amount * ratios[a] % total,
        );
        return byRemainder != 0 ? byRemainder : a.compareTo(b);
      });
    int left = amount - parts.fold(0, (int a, int b) => a + b);
    for (final int i in order) {
      if (left == 0) break;
      parts[i] += 1;
      left -= 1;
    }
    return <Money>[
      for (final int p in parts) Money(minor: sign * p, currency: currency),
    ];
  }

  /// For display only, in [locale]'s conventions: "S$1,234.50".
  String format({String? locale, bool symbol = true}) {
    final NumberFormat f = symbol
        ? NumberFormat.simpleCurrency(
            locale: locale,
            name: currency,
            decimalDigits: exponent,
          )
        : NumberFormat.currency(
            locale: locale,
            name: currency,
            symbol: '',
            decimalDigits: exponent,
          );
    return f.format(minor / _pow10(exponent)).trim();
  }

  /// The exact decimal, for storage and export: "1234.50".
  String toDecimalString() {
    if (exponent == 0) return '$minor';
    final String digits = minor.abs().toString().padLeft(exponent + 1, '0');
    final int cut = digits.length - exponent;
    return '${minor < 0 ? '-' : ''}${digits.substring(0, cut)}.${digits.substring(cut)}';
  }

  @override
  int compareTo(Money other) => minor.compareTo(_same(other).minor);

  bool operator <(Money other) => compareTo(other) < 0;
  bool operator >(Money other) => compareTo(other) > 0;

  Money _same(Money other) {
    if (other.currency != currency) {
      throw ArgumentError(
        'Cannot combine $currency with ${other.currency} without a rate.',
      );
    }
    return other;
  }
}

/// Sums [amounts], which must all be in [currency]. Empty is zero.
Money sumMoney(Iterable<Money> amounts, String currency) =>
    amounts.fold(Money.zero(currency), (Money a, Money b) => a + b);

bool isCurrencyCode(String code) => RegExp(r'^[A-Z]{3}$').hasMatch(code);

/// Decimal places of [currency], per ISO 4217. Two unless listed.
int currencyExponent(String currency) {
  if (_zeroDecimal.contains(currency)) return 0;
  if (_threeDecimal.contains(currency)) return 3;
  return 2;
}

const Set<String> _zeroDecimal = <String>{
  'BIF', 'CLP', 'DJF', 'GNF', 'ISK', 'JPY', 'KMF', 'KRW', 'PYG', 'RWF', //
  'UGX', 'UYI', 'VND', 'VUV', 'XAF', 'XOF', 'XPF',
};

const Set<String> _threeDecimal = <String>{
  'BHD',
  'IQD',
  'JOD',
  'KWD',
  'LYD',
  'OMR',
  'TND',
};

int _pow10(int n) {
  int v = 1;
  for (int i = 0; i < n; i++) {
    v *= 10;
  }
  return v;
}

int _divideHalfEven(int numerator, int denominator) {
  final int quotient = numerator ~/ denominator;
  final int remainder = numerator.remainder(denominator);
  final int twice = remainder.abs() * 2;
  if (twice < denominator) return quotient;
  final int away = quotient + (numerator.sign * denominator.sign);
  if (twice > denominator) return away;
  return quotient.isEven ? quotient : away;
}
