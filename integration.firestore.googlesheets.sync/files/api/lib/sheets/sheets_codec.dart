import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'sheets_config.dart';

/// A field's value as a cell. Always a plain value: text is written RAW, so a
/// stored `=IMPORTXML(…)` shows as text and never becomes a formula.
Object? toCell(SheetType type, Object? value) {
  if (value == null) return '';
  return switch (type) {
    TextType() => '$value',
    IntegerType() => value is int ? value : '$value',
    BooleanType() => value is bool ? value : '$value',
    DateType() =>
      value is DateTime
          ? value.toUtc().toIso8601String().substring(0, 10)
          : '$value',
    MoneyType(:final String currency, :final int decimals) =>
      value is Map && value['currency'] == currency && value['minor'] is int
          ? _decimal(value['minor']! as int, decimals)
          : '$value',
  };
}

/// A cell typed by a person, as a field value, or why it cannot be.
({Object? value, String? problem}) fromCell(SheetType type, String cell) {
  final String t = cell.trim();
  if (t.isEmpty) return (value: null, problem: null);
  switch (type) {
    case TextType():
      return (value: cell, problem: null);
    case IntegerType():
      final int? i = int.tryParse(t.replaceAll(',', ''));
      return i == null
          ? (value: null, problem: 'must be a whole number')
          : (value: i, problem: null);
    case BooleanType():
      final String l = t.toLowerCase();
      if (l == 'true') return (value: true, problem: null);
      if (l == 'false') return (value: false, problem: null);
      return (value: null, problem: 'must be TRUE or FALSE');
    case DateType():
      final DateTime? d = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(t)
          ? DateTime.tryParse('${t}T00:00:00Z')
          : null;
      return d == null
          ? (value: null, problem: 'must be a date as YYYY-MM-DD')
          : (value: d, problem: null);
    case MoneyType(:final String currency, :final int decimals):
      final RegExpMatch? m = RegExp(
        r'^(-?)(\d+)(?:\.(\d+))?$',
      ).firstMatch(t.replaceAll(',', ''));
      if (m == null || (m.group(3)?.length ?? 0) > decimals) {
        return (
          value: null,
          problem: 'must be an amount with at most $decimals decimal places',
        );
      }
      final String fraction = (m.group(3) ?? '').padRight(decimals, '0');
      final int minor =
          int.parse(m.group(2)!) * _pow10(decimals) +
          (fraction.isEmpty ? 0 : int.parse(fraction));
      return (
        value: <String, Object?>{
          'minor': m.group(1) == '-' ? -minor : minor,
          'currency': currency,
        },
        problem: null,
      );
  }
}

/// A short fingerprint of a field's stored value: what the sheet last saw.
/// An edit carries it back, and is applied only if the field still has it.
String fieldHash(Object? value) => sha256
    .convert(utf8.encode(jsonEncode(_canonical(value))))
    .toString()
    .substring(0, 16);

Object? _canonical(Object? v) {
  if (v is DateTime) return v.toUtc().toIso8601String();
  if (v is Map) {
    final List<String> keys = <String>[for (final Object? k in v.keys) '$k']
      ..sort();
    return <String, Object?>{for (final String k in keys) k: _canonical(v[k])};
  }
  if (v is List) return <Object?>[for (final Object? x in v) _canonical(x)];
  return v;
}

String _decimal(int minor, int decimals) {
  if (decimals == 0) return '$minor';
  final String digits = minor.abs().toString().padLeft(decimals + 1, '0');
  final int cut = digits.length - decimals;
  return '${minor < 0 ? '-' : ''}${digits.substring(0, cut)}.${digits.substring(cut)}';
}

int _pow10(int n) {
  int v = 1;
  for (int i = 0; i < n; i++) {
    v *= 10;
  }
  return v;
}
