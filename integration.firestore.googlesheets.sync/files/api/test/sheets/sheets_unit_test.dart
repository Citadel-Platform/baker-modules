import 'dart:convert';

import 'package:api/sheets/sheets_codec.dart';
import 'package:api/sheets/sheets_config.dart';
import 'package:api/sheets/sheets_gateway.dart';
import 'package:api/sheets/sheets_sync.dart';
import 'package:test/test.dart';

void main() {
  group('cells', () {
    test('values become plain cells; formulas stay text', () {
      expect(
        toCell(SheetType.text, '=IMPORTXML("http://x","//a")'),
        '=IMPORTXML("http://x","//a")',
      );
      expect(toCell(SheetType.integer, 3), 3);
      expect(
        toCell(SheetType.date, DateTime.utc(2026, 9, 27, 13)),
        '2026-09-27',
      );
      expect(
        toCell(const SheetType.money('SGD'), <String, Object?>{
          'minor': -1205,
          'currency': 'SGD',
        }),
        '-12.05',
      );
      expect(
        toCell(const SheetType.money('JPY', decimals: 0), <String, Object?>{
          'minor': 500,
          'currency': 'JPY',
        }),
        '500',
      );
      expect(toCell(SheetType.text, null), '');
    });

    test('typed cells are read exactly, and refused with a reason', () {
      expect(
        fromCell(const SheetType.money('SGD'), '1,234.5').value,
        <String, Object?>{'minor': 123450, 'currency': 'SGD'},
      );
      expect(
        fromCell(const SheetType.money('SGD'), '1.005').problem,
        contains('2 decimal'),
      );
      expect(fromCell(SheetType.integer, '12').value, 12);
      expect(fromCell(SheetType.integer, '1.5').problem, isNotNull);
      expect(fromCell(SheetType.boolean, 'TRUE').value, true);
      expect(fromCell(SheetType.boolean, 'yes').problem, isNotNull);
      expect(
        fromCell(SheetType.date, '2026-09-27').value,
        DateTime.utc(2026, 9, 27),
      );
      expect(
        fromCell(SheetType.date, '27/09/2026').problem,
        contains('YYYY-MM-DD'),
      );
      expect(
        fromCell(SheetType.text, '').value,
        isNull,
        reason: 'an empty cell clears the field',
      );
    });

    test('a field hash depends on the value, not on map order', () {
      expect(
        fieldHash(<String, Object?>{'a': 1, 'b': 2}),
        fieldHash(<String, Object?>{'b': 2, 'a': 1}),
      );
      expect(fieldHash('x'), isNot(fieldHash('y')));
      expect(fieldHash(null), fieldHash(null));
    });

    test('column letters', () {
      expect(
        <String>[
          for (final int c in <int>[1, 26, 27, 52, 53, 702, 703])
            columnLetters(c),
        ],
        <String>['A', 'Z', 'AA', 'AZ', 'BA', 'ZZ', 'AAA'],
      );
    });
  });

  test('a row is id, columns, status, version and hashes', () {
    const SheetMapping m = SheetMapping(
      collection: 'students',
      spreadsheetId: 's',
      tab: 'Students',
      columns: <SheetColumn>[
        SheetColumn('name', 'Name', SheetType.text, editable: true),
        SheetColumn('fee', 'Fee', SheetType.money('SGD')),
      ],
    );
    expect(m.headers, <String>[
      '_id',
      'Name',
      'Fee',
      '_status',
      '_version',
      '_hashes',
    ]);
    final List<Object?> row = SheetsSync.rowFor(
      m,
      'a1',
      <String, Object?>{
        'name': 'Ann',
        'fee': <String, Object?>{'minor': 100, 'currency': 'SGD'},
      },
      'v1',
      status: 'ok',
    );
    expect(row.take(5), <Object?>['a1', 'Ann', '1.00', 'ok', 'v1']);
    expect(
      (jsonDecode(row[5]! as String) as Map<String, Object?>)['Name'],
      fieldHash('Ann'),
    );
  });
}
