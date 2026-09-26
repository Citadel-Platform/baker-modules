import 'dart:convert';

import 'package:shelf/shelf.dart';

import 'problem.dart';

/// A request's JSON body, read with its types checked.
///
/// Every field a handler reads is required unless read with an optional
/// method. Problems are collected and answered together, one per field, so a
/// client fixes a form in one round trip rather than one error at a time.
class JsonBody {
  JsonBody._(this._data);

  final Map<String, Object?> _data;
  final Map<String, String> _problems = <String, String>{};

  /// Parses [request]'s body. The size cap has already been enforced by the
  /// pipeline.
  static Future<JsonBody> read(Request request) async {
    final String type = request.headers['content-type'] ?? '';
    if (!type.startsWith('application/json')) {
      throw Problem.invalid('Send the body as application/json.');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(await request.readAsString());
    } on FormatException {
      throw Problem.invalid('The body is not valid JSON.');
    }
    if (decoded is! Map<String, Object?>) {
      throw Problem.invalid('The body must be a JSON object.');
    }
    return JsonBody._(decoded);
  }

  /// The whole object, for nested structures a handler checks itself.
  Map<String, Object?> get raw => _data;

  /// A body built in code, for tests.
  JsonBody.of(Map<String, Object?> data) : _data = data;

  T? _field<T>(String name, String what, {required bool required}) {
    final Object? value = _data[name];
    if (value == null) {
      if (required) _problems[name] = 'is required';
      return null;
    }
    if (value is T) return value as T;
    _problems[name] = 'must be $what';
    return null;
  }

  String string(String name, {int maxLength = 1000}) {
    final String? v = _field<String>(name, 'text', required: true);
    if (v != null && v.length > maxLength) {
      _problems[name] = 'must be at most $maxLength characters';
    }
    return v ?? '';
  }

  String? optionalString(String name, {int maxLength = 1000}) {
    final String? v = _field<String>(name, 'text', required: false);
    if (v != null && v.length > maxLength) {
      _problems[name] = 'must be at most $maxLength characters';
    }
    return v;
  }

  int integer(String name, {int? min, int? max}) {
    final int? v = _field<int>(name, 'a whole number', required: true);
    if (v != null && ((min != null && v < min) || (max != null && v > max))) {
      _problems[name] = 'must be between ${min ?? '-∞'} and ${max ?? '∞'}';
    }
    return v ?? 0;
  }

  bool boolean(String name) =>
      _field<bool>(name, 'true or false', required: true) ?? false;

  /// Throws one 400 naming every field that failed. Call after reading all
  /// fields and before acting on any of them.
  void check() {
    if (_problems.isEmpty) return;
    throw Problem.invalid(
      'Some fields are missing or wrong.',
      fields: Map<String, String>.unmodifiable(_problems),
    );
  }
}
