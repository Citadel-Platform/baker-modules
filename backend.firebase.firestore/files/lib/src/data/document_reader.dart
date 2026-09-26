import 'package:cloud_firestore/cloud_firestore.dart';

import '../money/money.dart';
import 'firestore_failures.dart';

/// Reads a document's fields with their types checked.
///
/// A converter built on this fails with the field's name and the document's
/// path, instead of a cast error somewhere in a widget. Every required field
/// is required; an optional one says so.
class DocumentReader {
  DocumentReader(DocumentSnapshot<Map<String, dynamic>> snapshot)
    : path = snapshot.reference.path,
      id = snapshot.id,
      _data = snapshot.data() ?? const <String, dynamic>{};

  final String path;
  final String id;
  final Map<String, dynamic> _data;

  T _required<T>(String field) {
    final Object? value = _data[field];
    if (value is T) return value;
    throw InvalidRecord(
      path,
      value == null ? '$field is missing' : '$field is not a $T',
    );
  }

  T? _optional<T>(String field) {
    final Object? value = _data[field];
    if (value == null || value is T) return value as T?;
    throw InvalidRecord(path, '$field is not a $T');
  }

  String string(String field) => _required<String>(field);
  String? optionalString(String field) => _optional<String>(field);
  int integer(String field) => _required<int>(field);
  int? optionalInteger(String field) => _optional<int>(field);
  bool boolean(String field) => _required<bool>(field);
  List<String> strings(String field) {
    final List<Object?> list = _required<List<Object?>>(field);
    if (list.any((Object? v) => v is! String)) {
      throw InvalidRecord(path, '$field holds something that is not text');
    }
    return list.cast<String>();
  }

  DateTime timestamp(String field) => _required<Timestamp>(field).toDate();
  DateTime? optionalTimestamp(String field) =>
      _optional<Timestamp>(field)?.toDate();

  /// Money stored as `{minor, currency}`: see [moneyToFirestore].
  Money money(String field) {
    final Map<String, dynamic> m = _required<Map<String, dynamic>>(field);
    final Object? minor = m['minor'];
    final Object? currency = m['currency'];
    if (minor is! int || currency is! String) {
      throw InvalidRecord(path, '$field is not an amount of money');
    }
    try {
      return Money(minor: minor, currency: currency);
    } on ArgumentError {
      throw InvalidRecord(path, '$field has an unknown currency');
    }
  }
}

/// How [Money] is stored: whole minor units and the currency, never a float.
Map<String, Object> moneyToFirestore(Money m) => <String, Object>{
  'minor': m.minor,
  'currency': m.currency,
};
