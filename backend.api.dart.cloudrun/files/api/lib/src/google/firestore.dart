import 'package:googleapis/firestore/v1.dart' as fs;

/// Firestore for API routes: the typed REST client, with paths relative to
/// the database and values converted to and from plain Dart.
///
/// A commit takes several writes and applies all or none, which is how a
/// route changes business data and queues its side effects (mail, a sync)
/// together: a message is never sent for a change that did not happen, and
/// never lost for one that did.
class AppFirestore {
  AppFirestore(this.api, {required this.projectId, this.database = '(default)'});

  final fs.FirestoreApi api;
  final String projectId;
  final String database;

  String get databaseName => 'projects/$projectId/databases/$database';
  String get _root => '$databaseName/documents';

  /// The full name of the document at [path] (`records/abc`).
  String name(String path) => '$_root/$path';

  Future<Map<String, Object?>?> get(String path) async {
    try {
      final fs.Document d = await api.projects.databases.documents.get(name(path));
      return decodeFields(d.fields);
    } on fs.DetailedApiRequestError catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  /// Applies [writes] atomically.
  Future<void> commit(List<fs.Write> writes) async {
    await api.projects.databases.documents.commit(
      fs.CommitRequest(writes: writes),
      databaseName,
    );
  }

  /// A write setting [path] to [data]; with [mustNotExist], only if new.
  fs.Write set(
    String path,
    Map<String, Object?> data, {
    bool mustNotExist = false,
  }) => fs.Write(
    update: fs.Document(name: name(path), fields: encodeFields(data)),
    currentDocument: mustNotExist ? fs.Precondition(exists: false) : null,
  );

  /// A write changing only [data]'s fields of an existing document.
  fs.Write update(String path, Map<String, Object?> data) => fs.Write(
    update: fs.Document(name: name(path), fields: encodeFields(data)),
    updateMask: fs.DocumentMask(fieldPaths: data.keys.toList()),
    currentDocument: fs.Precondition(exists: true),
  );

  fs.Write delete(String path) => fs.Write(delete: name(path));

  /// Documents in [collection] where every field in [equals] matches,
  /// ordered by [orderBy] (and then by id), at most [limit].
  Future<List<({String id, Map<String, Object?> data})>> query(
    String collection, {
    Map<String, Object?> equals = const <String, Object?>{},
    ({String field, String op, Object? value})? range,
    String? orderBy,
    int limit = 100,
  }) async {
    final List<fs.Filter> filters = <fs.Filter>[
      for (final MapEntry<String, Object?> e in equals.entries)
        fs.Filter(
          fieldFilter: fs.FieldFilter(
            field: fs.FieldReference(fieldPath: e.key),
            op: 'EQUAL',
            value: encodeValue(e.value),
          ),
        ),
      if (range != null)
        fs.Filter(
          fieldFilter: fs.FieldFilter(
            field: fs.FieldReference(fieldPath: range.field),
            op: range.op,
            value: encodeValue(range.value),
          ),
        ),
    ];
    final List<fs.RunQueryResponseElement> rows = await api
        .projects
        .databases
        .documents
        .runQuery(
          fs.RunQueryRequest(
            structuredQuery: fs.StructuredQuery(
              from: <fs.CollectionSelector>[
                fs.CollectionSelector(collectionId: collection),
              ],
              where: filters.isEmpty
                  ? null
                  : filters.length == 1
                  ? filters.single
                  : fs.Filter(
                      compositeFilter: fs.CompositeFilter(
                        op: 'AND',
                        filters: filters,
                      ),
                    ),
              orderBy: <fs.Order>[
                if (orderBy != null)
                  fs.Order(field: fs.FieldReference(fieldPath: orderBy)),
                fs.Order(field: fs.FieldReference(fieldPath: '__name__')),
              ],
              limit: limit,
            ),
          ),
          _root,
        );
    return <({String id, Map<String, Object?> data})>[
      for (final fs.RunQueryResponseElement r in rows)
        if (r.document case final fs.Document d)
          (id: d.name!.split('/').last, data: decodeFields(d.fields)),
    ];
  }
}

/// The server's clock, as a value to write (`request.time` in rules).
const Object serverTimestamp = _ServerTimestamp();

class _ServerTimestamp {
  const _ServerTimestamp();
}

Map<String, fs.Value> encodeFields(Map<String, Object?> data) =>
    <String, fs.Value>{
      for (final MapEntry<String, Object?> e in data.entries)
        if (!identical(e.value, serverTimestamp)) e.key: encodeValue(e.value),
    };

fs.Value encodeValue(Object? v) => switch (v) {
  null => fs.Value(nullValue: 'NULL_VALUE'),
  final bool b => fs.Value(booleanValue: b),
  final int i => fs.Value(integerValue: '$i'),
  final double d => fs.Value(doubleValue: d),
  final String s => fs.Value(stringValue: s),
  final DateTime t => fs.Value(timestampValue: t.toUtc().toIso8601String()),
  final List<Object?> l => fs.Value(
    arrayValue: fs.ArrayValue(values: <fs.Value>[for (final Object? x in l) encodeValue(x)]),
  ),
  final Map<String, Object?> m => fs.Value(
    mapValue: fs.MapValue(fields: encodeFields(m)),
  ),
  _ => throw ArgumentError('Cannot store a ${v.runtimeType} in Firestore'),
};

Map<String, Object?> decodeFields(Map<String, fs.Value>? fields) =>
    <String, Object?>{
      for (final MapEntry<String, fs.Value> e
          in (fields ?? const <String, fs.Value>{}).entries)
        e.key: decodeValue(e.value),
    };

Object? decodeValue(fs.Value v) {
  if (v.stringValue != null) return v.stringValue;
  if (v.integerValue != null) return int.parse(v.integerValue!);
  if (v.booleanValue != null) return v.booleanValue;
  if (v.doubleValue != null) return v.doubleValue;
  if (v.timestampValue != null) return DateTime.parse(v.timestampValue!);
  if (v.arrayValue != null) {
    return <Object?>[
      for (final fs.Value x in v.arrayValue!.values ?? const <fs.Value>[])
        decodeValue(x),
    ];
  }
  if (v.mapValue != null) return decodeFields(v.mapValue!.fields);
  return null;
}

/// Writes [path]'s [fields] as the server's clock, alongside a write.
fs.Write withServerTime(fs.Write write, List<String> fields) => write
  ..updateTransforms = <fs.FieldTransform>[
    ...?write.updateTransforms,
    for (final String f in fields)
      fs.FieldTransform(fieldPath: f, setToServerValue: 'REQUEST_TIME'),
  ];
