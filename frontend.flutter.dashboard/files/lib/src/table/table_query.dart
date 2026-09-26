import 'package:freezed_annotation/freezed_annotation.dart';

part 'table_query.freezed.dart';

/// What a table is showing: search, sort, filters and page size.
///
/// Held in the URL, not in widget state, so a filtered view can be linked,
/// bookmarked and survives a reload — "look at the overdue ones" becomes a
/// link rather than instructions.
@freezed
abstract class TableQuery with _$TableQuery {
  const TableQuery._();

  const factory TableQuery({
    @Default('') String search,
    String? sortBy,
    @Default(false) bool descending,
    @Default(<String, String>{}) Map<String, String> filters,
    @Default(TableQuery.defaultPageSize) int pageSize,
  }) = _TableQuery;

  static const int defaultPageSize = 50;
  static const int maxPageSize = 200;

  static const String _search = 'q';
  static const String _sort = 'sort';
  static const String _size = 'size';
  static const String _filterPrefix = 'f.';

  /// Reads a query from URL parameters, keeping only what [sortable] and
  /// [filterable] allow.
  ///
  /// The URL is typed by anybody, so it is validated like any input: an
  /// unknown sort column or filter is dropped, not passed to a database that
  /// may reject it, index-miss on it, or worse. A page size is clamped.
  factory TableQuery.fromParameters(
    Map<String, String> parameters, {
    Set<String> sortable = const <String>{},
    Set<String> filterable = const <String>{},
  }) {
    final String sortParam = parameters[_sort] ?? '';
    final bool descending = sortParam.startsWith('-');
    final String sortField = descending ? sortParam.substring(1) : sortParam;
    final int? size = int.tryParse(parameters[_size] ?? '');
    return TableQuery(
      search: (parameters[_search] ?? '').trim(),
      sortBy: sortable.contains(sortField) ? sortField : null,
      descending: sortable.contains(sortField) && descending,
      filters: <String, String>{
        for (final MapEntry<String, String> e in parameters.entries)
          if (e.key.startsWith(_filterPrefix) &&
              filterable.contains(e.key.substring(_filterPrefix.length)) &&
              e.value.isNotEmpty)
            e.key.substring(_filterPrefix.length): e.value,
      },
      pageSize: size == null ? defaultPageSize : size.clamp(1, maxPageSize),
    );
  }

  /// The URL parameters for this query. Defaults are left out, so the plain
  /// view has a plain address.
  Map<String, String> toParameters() => <String, String>{
    if (search.isNotEmpty) _search: search,
    if (sortBy != null) _sort: '${descending ? '-' : ''}$sortBy',
    if (pageSize != defaultPageSize) _size: '$pageSize',
    for (final MapEntry<String, String> e in filters.entries)
      '$_filterPrefix${e.key}': e.value,
  };

  /// Sorting by [field]: ascending first, then descending, then off.
  TableQuery toggleSort(String field) {
    if (sortBy != field) return copyWith(sortBy: field, descending: false);
    if (!descending) return copyWith(descending: true);
    return copyWith(sortBy: null, descending: false);
  }
}

/// One page of results, and where the next one starts.
///
/// A cursor, not a page number: "page 3" moves when a record is added above
/// it, and skipping N rows is billed for every one skipped. Firestore's
/// `startAfterDocument` and SQL keyset pagination both fit this.
class TablePage<T> {
  const TablePage({required this.items, this.nextCursor});

  final List<T> items;

  /// Null when this is the last page.
  final Object? nextCursor;
}

/// Where a table's rows come from. Extended once per collection.
abstract class PageSource<T> {
  const PageSource();

  /// The page after [cursor] (the first page when null) for [query].
  ///
  /// Throws an `AppFailure` for anything the table should explain.
  Future<TablePage<T>> fetch(TableQuery query, {Object? cursor});

  /// Whether a sort still applies while searching. False for a source that
  /// can only return search results in its own order: the table then hides
  /// the sort arrow rather than claim an order the rows are not in.
  bool get sortsWhileSearching => true;
}
