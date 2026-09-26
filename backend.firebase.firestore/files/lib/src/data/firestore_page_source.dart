import 'package:cloud_firestore/cloud_firestore.dart';

import '../table/table_query.dart';
import 'firestore_failures.dart';

/// A [PageSource] over a Firestore collection, for `DataTableKit`.
///
/// - Pages by cursor (`startAfterDocument`), so a page costs its own reads and
///   no more, however deep it is.
/// - Every order ends with the document id, so two records sorting equal still
///   have a fixed order and a cursor never skips or repeats one.
/// - Sorts and filters only by the fields named here. The table's query comes
///   from the URL; anything else in it was dropped before it got here.
/// - Search is a prefix match on [searchField], which must hold a lower-cased
///   copy of whatever is searched (Firestore has no full-text search). While
///   searching, results are in that field's order: Firestore requires the
///   first sort to be the field compared.
class FirestorePageSource<T> extends PageSource<T> {
  FirestorePageSource({
    required this.query,
    required this.sortFields,
    required this.defaultSort,
    this.defaultDescending = false,
    this.filterFields = const <String, String>{},
    this.searchField,
  }) : assert(
         sortFields.containsKey(defaultSort),
         'defaultSort must be sortable',
       );

  /// The collection (or query) with its converter, e.g.
  /// `db.collection('records').withConverter(...)`.
  final Query<T> Function() query;

  /// Column id to field path, for the columns a person may sort by.
  final Map<String, String> sortFields;
  final String defaultSort;
  final bool defaultDescending;

  /// Filter name to field path, compared for equality.
  final Map<String, String> filterFields;
  final String? searchField;

  /// Search results come back in [searchField]'s order: Firestore requires
  /// a range query's first sort to be the field it compares.
  @override
  bool get sortsWhileSearching => searchField == null;

  /// The sortable and filterable names, for `TableQueryRoute.of`.
  Set<String> get sortable => sortFields.keys.toSet();
  Set<String> get filterable => filterFields.keys.toSet();

  @override
  Future<TablePage<T>> fetch(TableQuery table, {Object? cursor}) async {
    Query<T> q = query();
    for (final MapEntry<String, String> f in table.filters.entries) {
      final String? field = filterFields[f.key];
      if (field != null) q = q.where(field, isEqualTo: f.value);
    }
    final String search = table.search.trim().toLowerCase();
    if (search.isNotEmpty && searchField != null) {
      q = q
          .where(searchField!, isGreaterThanOrEqualTo: search)
          .where(searchField!, isLessThan: '$search')
          .orderBy(searchField!);
    } else {
      final String sort =
          sortFields[table.sortBy ?? defaultSort] ?? sortFields[defaultSort]!;
      q = q.orderBy(
        sort,
        descending: table.sortBy == null ? defaultDescending : table.descending,
      );
    }
    q = q.orderBy(FieldPath.documentId);
    if (cursor != null) {
      if (cursor is! DocumentSnapshot) {
        throw ArgumentError.value(cursor, 'cursor', 'not a Firestore cursor');
      }
      q = q.startAfterDocument(cursor);
    }
    // Cursor, then limit. Firestore itself does not mind the order, but the
    // in-memory fake the tests use applies them as written.
    q = q.limit(table.pageSize);
    try {
      final QuerySnapshot<T> snapshot = await q.get();
      return TablePage<T>(
        items: <T>[
          for (final QueryDocumentSnapshot<T> d in snapshot.docs) d.data(),
        ],
        nextCursor: snapshot.docs.length == table.pageSize
            ? snapshot.docs.last
            : null,
      );
    } on FirebaseException catch (error) {
      throw firestoreFailure(error);
    }
  }
}
