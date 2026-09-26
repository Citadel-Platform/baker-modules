import 'dart:async';

import 'package:{{baker.packageName}}/src/design/theme.dart';
import 'package:{{baker.packageName}}/src/foundation/failure.dart';
import 'package:{{baker.packageName}}/src/table/data_table_kit.dart';
import 'package:{{baker.packageName}}/src/table/table_query.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A source the test answers by hand, so ordering and failure are controlled.
class _Source extends PageSource<String> {
  _Source({this.sortsWhileSearching = true});

  @override
  final bool sortsWhileSearching;

  final List<
    ({TableQuery query, Object? cursor, Completer<TablePage<String>> reply})
  >
  calls =
      <
        ({TableQuery query, Object? cursor, Completer<TablePage<String>> reply})
      >[];

  @override
  Future<TablePage<String>> fetch(TableQuery query, {Object? cursor}) {
    final Completer<TablePage<String>> reply = Completer<TablePage<String>>();
    calls.add((query: query, cursor: cursor, reply: reply));
    return reply.future;
  }
}

List<String> _rows(String prefix, int n) => <String>[
  for (int i = 0; i < n; i++) '$prefix$i',
];

void main() {
  group('TableQuery in the URL', () {
    test('round-trips, leaving defaults out', () {
      const TableQuery q = TableQuery(
        search: 'ann',
        sortBy: 'name',
        descending: true,
        filters: <String, String>{'status': 'active'},
      );
      final Map<String, String> params = q.toParameters();
      expect(params, <String, String>{
        'q': 'ann',
        'sort': '-name',
        'f.status': 'active',
      });
      expect(
        TableQuery.fromParameters(
          params,
          sortable: <String>{'name'},
          filterable: <String>{'status'},
        ),
        q,
      );
      expect(const TableQuery().toParameters(), isEmpty);
    });

    test('drops what is not allowed and clamps the page size', () {
      final TableQuery q = TableQuery.fromParameters(
        <String, String>{
          'sort': '-password',
          'f.role': 'admin',
          'size': '100000',
        },
        sortable: <String>{'name'},
        filterable: <String>{'status'},
      );
      expect(q.sortBy, isNull);
      expect(q.descending, isFalse);
      expect(q.filters, isEmpty);
      expect(q.pageSize, TableQuery.maxPageSize);
    });

    test('sorting cycles ascending, descending, off', () {
      final TableQuery a = const TableQuery().toggleSort('name');
      expect((a.sortBy, a.descending), ('name', false));
      final TableQuery b = a.toggleSort('name');
      expect((b.sortBy, b.descending), ('name', true));
      expect(b.toggleSort('name').sortBy, isNull);
    });
  });

  group('DataTableKit', () {
    late _Source source;
    late TableQuery query;
    late List<List<String>> acted;

    setUp(() {
      source = _Source();
      query = const TableQuery();
      acted = <List<String>>[];
    });

    Widget table({bool bulk = false}) => MaterialApp(
      theme: appTheme(Brightness.light),
      home: Scaffold(
        body: StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) =>
              DataTableKit<String>(
                source: source,
                query: query,
                onQueryChanged: (TableQuery next) =>
                    setState(() => query = next),
                rowKey: (String r) => r,
                columns: <TableColumn<String>>[
                  TableColumn<String>(
                    id: 'name',
                    label: 'Name',
                    sortable: true,
                    cell: (_, String r) => Text(r),
                  ),
                ],
                bulkActions: bulk
                    ? <BulkAction<String>>[
                        BulkAction<String>(
                          label: 'Archive',
                          icon: Icons.archive_outlined,
                          reversible: false,
                          run: (List<String> rows) async => acted.add(rows),
                        ),
                      ]
                    : const <BulkAction<String>>[],
              ),
        ),
      ),
    );

    testWidgets('loading, then rows, and never invented ones', (
      WidgetTester t,
    ) async {
      await t.pumpWidget(table());
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      source.calls.single.reply.complete(
        TablePage<String>(items: _rows('r', 3)),
      );
      await t.pumpAndSettle();
      expect(find.text('r0'), findsOneWidget);
      expect(find.text('r2'), findsOneWidget);
    });

    testWidgets('empty and failed are different, and failure offers retry', (
      WidgetTester t,
    ) async {
      await t.pumpWidget(table());
      source.calls.single.reply.complete(
        const TablePage<String>(items: <String>[]),
      );
      await t.pumpAndSettle();
      expect(find.text('Nothing here yet'), findsOneWidget);

      await t.tap(find.text('Name'));
      await t.pump();
      source.calls.last.reply.completeError(
        const Unavailable('The records service'),
      );
      await t.pumpAndSettle();
      expect(find.text('Could not load'), findsOneWidget);
      expect(find.textContaining('did not respond'), findsOneWidget);
      await t.tap(find.text('Retry'));
      await t.pump();
      expect(source.calls, hasLength(3));
    });

    testWidgets('a slow answer to an old search does not replace a newer one', (
      WidgetTester t,
    ) async {
      await t.pumpWidget(table());
      source.calls.single.reply.complete(
        TablePage<String>(items: _rows('all', 2)),
      );
      await t.pumpAndSettle();

      await t.enterText(find.byType(TextField), 'an');
      await t.pump(const Duration(milliseconds: 350));
      await t.enterText(find.byType(TextField), 'ann');
      await t.pump(const Duration(milliseconds: 350));
      expect(source.calls, hasLength(3));
      expect(source.calls[2].query.search, 'ann');

      source.calls[2].reply.complete(
        TablePage<String>(items: <String>['ann-new']),
      );
      await t.pumpAndSettle();
      source.calls[1].reply.complete(
        TablePage<String>(items: <String>['an-stale']),
      );
      await t.pumpAndSettle();
      expect(find.text('ann-new'), findsOneWidget);
      expect(find.text('an-stale'), findsNothing);
    });

    testWidgets('typing is debounced into one query', (WidgetTester t) async {
      await t.pumpWidget(table());
      source.calls.single.reply.complete(
        const TablePage<String>(items: <String>[]),
      );
      await t.pumpAndSettle();
      for (final String partial in <String>['a', 'an', 'ann', 'anna']) {
        await t.enterText(find.byType(TextField), partial);
        await t.pump(const Duration(milliseconds: 100));
      }
      await t.pump(const Duration(milliseconds: 350));
      expect(source.calls, hasLength(2));
      expect(source.calls.last.query.search, 'anna');
    });

    testWidgets('scrolling near the end fetches the next page by cursor', (
      WidgetTester t,
    ) async {
      await t.pumpWidget(table());
      source.calls.single.reply.complete(
        TablePage<String>(items: _rows('p1-', 50), nextCursor: 'c1'),
      );
      await t.pumpAndSettle();
      await t.drag(find.byType(ListView), const Offset(0, -3000));
      await t.pump();
      expect(source.calls.last.cursor, 'c1');
      source.calls.last.reply.complete(
        TablePage<String>(items: _rows('p2-', 5)),
      );
      await t.pumpAndSettle();
      await t.drag(find.byType(ListView), const Offset(0, -3000));
      await t.pumpAndSettle();
      expect(find.text('p2-4'), findsOneWidget);
      expect(source.calls, hasLength(2), reason: 'no cursor, no further page');
    });

    testWidgets(
      'a bulk action asks first, states the count, and can be cancelled',
      (WidgetTester t) async {
        await t.pumpWidget(table(bulk: true));
        source.calls.single.reply.complete(
          TablePage<String>(items: _rows('r', 3)),
        );
        await t.pumpAndSettle();
        await t.tap(find.byType(Checkbox).at(1));
        await t.tap(find.byType(Checkbox).at(2));
        await t.pump();
        expect(find.text('2 selected'), findsOneWidget);

        await t.tap(find.widgetWithText(OutlinedButton, 'Archive'));
        await t.pumpAndSettle();
        expect(find.text('Archive (2)'), findsOneWidget);
        expect(find.text('This cannot be undone.'), findsOneWidget);
        await t.tap(find.text('Cancel'));
        await t.pumpAndSettle();
        expect(acted, isEmpty);

        await t.tap(find.widgetWithText(OutlinedButton, 'Archive'));
        await t.pumpAndSettle();
        await t.tap(find.widgetWithText(FilledButton, 'Archive'));
        await t.pump();
        expect(acted.single, <String>['r0', 'r1']);
        source.calls.last.reply.complete(
          TablePage<String>(items: _rows('r', 1)),
        );
        await t.pumpAndSettle();
        expect(find.text('2 selected'), findsNothing);
      },
    );
    testWidgets('a source that cannot sort while searching shows no sort arrow',
        (WidgetTester t) async {
      source = _Source(sortsWhileSearching: false);
      query = const TableQuery(sortBy: 'name', search: 'an');
      await t.pumpWidget(table());
      source.calls.single.reply.complete(TablePage<String>(items: _rows('an', 2)));
      await t.pumpAndSettle();
      expect(find.byIcon(Icons.arrow_upward), findsNothing);
      await t.tap(find.text('Name'));
      await t.pump();
      expect(source.calls, hasLength(1), reason: 'sorting is off while searching');
    });

    testWidgets('fits a phone, with bulk actions folded into a menu',
        (WidgetTester t) async {
      // The view, not just the surface: layout decisions read MediaQuery.
      t.view
        ..physicalSize = const Size(390, 800)
        ..devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(table(bulk: true));
      source.calls.single.reply.complete(TablePage<String>(items: _rows('r', 3)));
      await t.pumpAndSettle();
      await t.tap(find.byType(Checkbox).at(1));
      await t.pumpAndSettle();
      expect(find.byTooltip('Actions'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Archive'), findsNothing);
      expect(t.takeException(), isNull, reason: 'no layout overflow');
    });
  });
}
