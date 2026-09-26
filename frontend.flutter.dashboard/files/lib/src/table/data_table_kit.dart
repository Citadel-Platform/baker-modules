import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../design/dialogs.dart';
import '../design/primitives.dart';
import '../design/states.dart';
import '../design/tokens.dart';
import '../foundation/failure.dart';
import '../foundation/layout.dart';
import 'table_query.dart';

/// One column: a header, and how to show a row's value in it.
class TableColumn<T> {
  const TableColumn({
    required this.id,
    required this.label,
    required this.cell,
    this.flex = 1,
    this.sortable = false,
    this.numeric = false,
  });

  /// The field name sorting uses, and the column's stable identity.
  final String id;
  final String label;
  final Widget Function(BuildContext context, T row) cell;
  final int flex;
  final bool sortable;

  /// Right-aligned, as figures are, so digits line up.
  final bool numeric;
}

/// An action on the selected rows.
class BulkAction<T> {
  const BulkAction({
    required this.label,
    required this.icon,
    required this.run,
    this.reversible = true,
    this.detail,
  });

  final String label;
  final IconData icon;

  /// Performs the action. Throws an `AppFailure` to explain a refusal.
  final Future<void> Function(List<T> rows) run;

  /// False for deletes and sends: the confirmation says it cannot be undone.
  final bool reversible;
  final String? detail;
}

/// A table over a [PageSource], for collections of any size.
///
/// - Loads a page at a time by cursor, and the next when scrolled near the end.
/// - Builds only the rows on screen (fixed row height), so ten thousand rows
///   scroll like ten.
/// - Search, sort and filters live in [query], which the page keeps in the URL;
///   see [TableQueryRoute].
/// - A response to an older query is discarded, so fast typing cannot leave
///   the table showing results for a search that is no longer in the box.
/// - Loading, empty, failed and not-configured are distinct states.
class DataTableKit<T> extends StatefulWidget {
  const DataTableKit({
    required this.source,
    required this.columns,
    required this.query,
    required this.onQueryChanged,
    required this.rowKey,
    this.onRowTap,
    this.bulkActions = const <Never>[],
    this.searchHint = 'Search',
    this.emptyTitle = 'Nothing here yet',
    this.toolbar = const <Widget>[],
    super.key,
  });

  final PageSource<T> source;
  final List<TableColumn<T>> columns;
  final TableQuery query;
  final ValueChanged<TableQuery> onQueryChanged;

  /// A stable id per row; selection survives paging by it.
  final String Function(T row) rowKey;
  final ValueChanged<T>? onRowTap;
  final List<BulkAction<T>> bulkActions;
  final String searchHint;
  final String emptyTitle;
  final List<Widget> toolbar;

  @override
  State<DataTableKit<T>> createState() => _DataTableKitState<T>();
}

class _DataTableKitState<T> extends State<DataTableKit<T>> {
  final ScrollController _scroll = ScrollController();
  final Debouncer _debounce = Debouncer();
  late final TextEditingController _search = TextEditingController(
    text: widget.query.search,
  );

  List<T> _rows = <T>[];
  Object? _cursor;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  bool _acting = false;
  Object? _error;
  int _request = 0;
  final Map<String, T> _selected = <String, T>{};

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(DataTableKit<T> old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query || old.source != widget.source) {
      if (_search.text != widget.query.search) {
        _search.text = widget.query.search;
      }
      _selected.clear();
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _debounce.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final int request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final TablePage<T> page = await widget.source.fetch(widget.query);
      if (!mounted || request != _request) return;
      setState(() {
        _rows = page.items;
        _cursor = page.nextCursor;
        _hasMore = page.nextCursor != null;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading) return;
    final int request = _request;
    setState(() => _loadingMore = true);
    try {
      final TablePage<T> page = await widget.source.fetch(
        widget.query,
        cursor: _cursor,
      );
      if (!mounted || request != _request) return;
      setState(() {
        _rows = <T>[..._rows, ...page.items];
        _cursor = page.nextCursor;
        _hasMore = page.nextCursor != null;
      });
    } on Object catch (error) {
      if (mounted && request == _request) {
        showFeedback(context, describeFailure(error), tone: Tone.danger);
      }
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    final ScrollPosition p = _scroll.position;
    if (p.pixels >= p.maxScrollExtent - AppTokens.rowHeight * 10) {
      unawaited(_loadMore());
    }
  }

  Future<void> _runBulk(BulkAction<T> action) async {
    final List<T> rows = _selected.values.toList();
    final bool confirmed = await confirmAction(
      context,
      title: action.label,
      confirmLabel: action.label,
      detail: action.detail,
      count: rows.length,
      reversible: action.reversible,
    );
    if (!confirmed || !mounted) return;
    setState(() => _acting = true);
    try {
      await action.run(rows);
      if (!mounted) return;
      showFeedback(context, '${action.label}: ${rows.length} done');
      _selected.clear();
      await _load();
    } on Object catch (error) {
      if (mounted) {
        showFeedback(context, describeFailure(error), tone: Tone.danger);
      }
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _toolbar(context),
        const SizedBox(height: AppTokens.space3),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.of(context).surface,
              border: Border.all(color: AppColors.of(context).border),
              borderRadius: BorderRadius.circular(AppTokens.radiusLg),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppTokens.radiusLg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _header(context),
                  const Divider(height: 1),
                  Expanded(child: _body(context)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _toolbar(BuildContext context) {
    if (_selected.isNotEmpty) {
      return SizedBox(
        height: AppTokens.controlHeight,
        child: Row(
          children: <Widget>[
            Text(
              '${_selected.length} selected',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(width: AppTokens.space3),
            TextButton(
              onPressed: _acting ? null : () => setState(_selected.clear),
              child: const Text('Clear'),
            ),
            const Spacer(),
            // On a phone the actions fold into a menu rather than overflow.
            if (WindowSize.of(context) == WindowSize.compact)
              PopupMenuButton<BulkAction<T>>(
                enabled: !_acting,
                tooltip: 'Actions',
                icon: const Icon(Icons.more_vert),
                onSelected: _runBulk,
                itemBuilder: (_) => <PopupMenuEntry<BulkAction<T>>>[
                  for (final BulkAction<T> action in widget.bulkActions)
                    PopupMenuItem<BulkAction<T>>(
                      value: action,
                      child: Text(action.label),
                    ),
                ],
              )
            else
              for (final BulkAction<T> action
                  in widget.bulkActions) ...<Widget>[
                const SizedBox(width: AppTokens.space2),
                OutlinedButton.icon(
                  onPressed: _acting ? null : () => _runBulk(action),
                  icon: Icon(action.icon, size: 18),
                  label: Text(action.label),
                ),
              ],
          ],
        ),
      );
    }
    return SizedBox(
      height: AppTokens.controlHeight,
      child: Row(
        children: <Widget>[
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: TextField(
                controller: _search,
                decoration: InputDecoration(
                  hintText: widget.searchHint,
                  prefixIcon: const Icon(Icons.search, size: 18),
                ),
                textInputAction: TextInputAction.search,
                onChanged: (String value) => _debounce.run(
                  () => widget.onQueryChanged(
                    widget.query.copyWith(search: value.trim()),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: AppTokens.space2),
          ...widget.toolbar,
        ],
      ),
    );
  }

  bool get _selectable => widget.bulkActions.isNotEmpty;

  /// Sorting means nothing while the source searches in its own order.
  bool get _sortShown =>
      widget.query.search.isEmpty || widget.source.sortsWhileSearching;

  Widget _header(BuildContext context) {
    final TextStyle? style = Theme.of(context).textTheme.labelMedium;
    final bool allSelected =
        _rows.isNotEmpty &&
        _rows.every((T r) => _selected.containsKey(widget.rowKey(r)));
    return SizedBox(
      height: AppTokens.rowHeight,
      child: Row(
        children: <Widget>[
          if (_selectable)
            SizedBox(
              width: 48,
              child: Checkbox(
                value: allSelected,
                onChanged: _rows.isEmpty || _acting
                    ? null
                    : (bool? on) => setState(() {
                        for (final T r in _rows) {
                          if (on ?? false) {
                            _selected[widget.rowKey(r)] = r;
                          } else {
                            _selected.remove(widget.rowKey(r));
                          }
                        }
                      }),
              ),
            )
          else
            const SizedBox(width: AppTokens.space4),
          for (final TableColumn<T> column in widget.columns)
            Expanded(
              flex: column.flex,
              child: _HeaderCell(
                label: column.label,
                style: style,
                numeric: column.numeric,
                sorted: _sortShown && widget.query.sortBy == column.id
                    ? (widget.query.descending ? -1 : 1)
                    : 0,
                onTap: column.sortable && _sortShown
                    ? () => widget.onQueryChanged(
                        widget.query.toggleSort(column.id),
                      )
                    : null,
              ),
            ),
          const SizedBox(width: AppTokens.space4),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading && _rows.isEmpty) return const LoadingState();
    if (_error != null) return FailureState(error: _error!, onRetry: _load);
    if (_rows.isEmpty) {
      return EmptyState(
        title: widget.query.search.isEmpty && widget.query.filters.isEmpty
            ? widget.emptyTitle
            : 'No matches',
      );
    }
    return Stack(
      children: <Widget>[
        ListView.builder(
          controller: _scroll,
          itemExtent: AppTokens.rowHeight,
          itemCount: _rows.length + (_hasMore ? 1 : 0),
          itemBuilder: (BuildContext context, int index) {
            if (index >= _rows.length) {
              return const Center(
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              );
            }
            return _row(context, _rows[index]);
          },
        ),
        // A refresh over rows already shown keeps them up, with a thin bar.
        if (_loading)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }

  Widget _row(BuildContext context, T row) {
    final String key = widget.rowKey(row);
    final bool selected = _selected.containsKey(key);
    final AppColors c = AppColors.of(context);
    return Material(
      color: selected ? c.accentSoft : Colors.transparent,
      child: InkWell(
        onTap: widget.onRowTap == null ? null : () => widget.onRowTap!(row),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: c.border)),
          ),
          child: Row(
            children: <Widget>[
              if (_selectable)
                SizedBox(
                  width: 48,
                  child: Checkbox(
                    value: selected,
                    onChanged: _acting
                        ? null
                        : (bool? on) => setState(() {
                            if (on ?? false) {
                              _selected[key] = row;
                            } else {
                              _selected.remove(key);
                            }
                          }),
                  ),
                )
              else
                const SizedBox(width: AppTokens.space4),
              for (final TableColumn<T> column in widget.columns)
                Expanded(
                  flex: column.flex,
                  child: Align(
                    alignment: column.numeric
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppTokens.space2,
                      ),
                      child: DefaultTextStyle.merge(
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        child: column.cell(context, row),
                      ),
                    ),
                  ),
                ),
              const SizedBox(width: AppTokens.space4),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell({
    required this.label,
    required this.style,
    required this.numeric,
    required this.sorted,
    required this.onTap,
  });

  final String label;
  final TextStyle? style;
  final bool numeric;

  /// 1 ascending, -1 descending, 0 not sorted.
  final int sorted;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Widget text = Row(
      mainAxisAlignment: numeric
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      children: <Widget>[
        Flexible(
          child: Text(label, style: style, overflow: TextOverflow.ellipsis),
        ),
        if (sorted != 0)
          Icon(
            sorted > 0 ? Icons.arrow_upward : Icons.arrow_downward,
            size: 14,
          ),
      ],
    );
    final Widget padded = Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppTokens.space2),
      child: text,
    );
    if (onTap == null) return padded;
    return Semantics(
      button: true,
      label: 'Sort by $label',
      child: InkWell(
        onTap: onTap,
        child: SizedBox.expand(
          child: Align(
            alignment: numeric ? Alignment.centerRight : Alignment.centerLeft,
            child: padded,
          ),
        ),
      ),
    );
  }
}

/// Keeps a table's [TableQuery] in the page's URL.
///
///     final route = TableQueryRoute.of(context, sortable: {'name'});
///     DataTableKit(query: route.query, onQueryChanged: route.update, …)
class TableQueryRoute {
  TableQueryRoute._(this._context, this._uri, this.query);

  factory TableQueryRoute.of(
    BuildContext context, {
    Set<String> sortable = const <String>{},
    Set<String> filterable = const <String>{},
  }) {
    final Uri uri = GoRouterState.of(context).uri;
    return TableQueryRoute._(
      context,
      uri,
      TableQuery.fromParameters(
        uri.queryParameters,
        sortable: sortable,
        filterable: filterable,
      ),
    );
  }

  final BuildContext _context;
  final Uri _uri;
  final TableQuery query;

  /// Replaces the URL's query with [next]. `go`, not `push`: changing a
  /// filter is not a page to come back to with the Back button.
  void update(TableQuery next) {
    final Map<String, String> parameters = next.toParameters();
    _context.go(
      Uri(
        path: _uri.path,
        queryParameters: parameters.isEmpty ? null : parameters,
      ).toString(),
    );
  }
}
