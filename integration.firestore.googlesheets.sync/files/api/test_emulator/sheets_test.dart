@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:api/api.dart';
import 'package:api/sheets/sheets_codec.dart';
import 'package:api/sheets/sheets_config.dart';
import 'package:api/sheets/sheets_gateway.dart';
import 'package:api/sheets/sheets_sync.dart';
import 'package:crypto/crypto.dart';
import 'package:googleapis/firestore/v1.dart' as fs;
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// Sheets sync against the Firestore emulator, with the spreadsheet in memory.
///
///     firebase emulators:exec --only firestore --project demo-local \
///       "cd api && dart test test_emulator/sheets_test.dart"
void main() {
  final String host = Platform.environment['FIRESTORE_EMULATOR_HOST'] ?? '';
  const String secret = 'test-secret-for-vectors';
  const SheetMapping students = SheetMapping(
    collection: 'students',
    spreadsheetId: 's1',
    tab: 'Students',
    columns: <SheetColumn>[
      SheetColumn('name', 'Name', SheetType.text, editable: true),
      SheetColumn('fee', 'Fee', SheetType.money('SGD'), editable: true),
      SheetColumn('joined', 'Joined', SheetType.date),
    ],
  );
  late AppFirestore db;
  late MemoryTaskQueue tasks;
  late _Sheet sheet;
  late SheetsSync sync;
  late DateTime now;

  setUpAll(
    () =>
        expect(host, isNotEmpty, reason: 'Run under firebase emulators:exec.'),
  );

  setUp(() {
    db = AppFirestore(
      fs.FirestoreApi(_Owner(), rootUrl: 'http://$host/'),
      projectId: 'demo-sheets-${DateTime.now().microsecondsSinceEpoch}',
    );
    tasks = MemoryTaskQueue();
    sheet = _Sheet(students.headers);
    now = DateTime.now().toUtc();
    sync = SheetsSync(
      db: db,
      tasks: tasks,
      sheets: sheet,
      mappings: const <SheetMapping>[students],
      webhookSecrets: const <String>['old-secret', secret],
      watched: const <String>{'students'},
      clock: () => now,
    );
  });

  Future<void> put(String id, Map<String, Object?> data) =>
      db.commit(<fs.Write>[db.set('students/$id', data)]);

  test('a change queues one sync; unmapped collections are ignored', () async {
    expect(await sync.changed('students/a1'), isTrue);
    expect(await sync.changed('students/a1'), isTrue);
    expect(
      tasks.queued,
      hasLength(1),
      reason: 'changes close together share a task',
    );
    expect(await sync.changed('invoices/x'), isFalse);
    expect(await sync.changed('students/a1/notes/n1'), isFalse);
  });

  test('new, updated, deleted and duplicated rows', () async {
    await put('a1', <String, Object?>{
      'name': 'Ann',
      'fee': <String, Object?>{'minor': 12000, 'currency': 'SGD'},
      'joined': DateTime.utc(2026, 1, 5),
    });
    await sync.sync('students/a1');
    expect(sheet.data, hasLength(1));
    expect(sheet.data.single.take(5), <Object?>[
      'a1',
      'Ann',
      '120.00',
      '2026-01-05',
      'ok',
    ]);

    await db.commit(<fs.Write>[
      db.update('students/a1', <String, Object?>{'name': 'Ann Lee'}),
    ]);
    await sync.sync('students/a1');
    expect(sheet.data, hasLength(1), reason: 'updated in place, not appended');
    expect(sheet.data.single[1], 'Ann Lee');

    sheet.data.add(List<Object?>.of(sheet.data.single));
    await sync.sync('students/a1');
    expect(sheet.data[1][4], contains('duplicate of row 2'));

    await db.commit(<fs.Write>[db.delete('students/a1')]);
    await sync.sync('students/a1');
    expect(sheet.data.first[4], 'deleted in the app');
  });

  test('a sync of the same row already running makes the task retry', () async {
    await put('a1', <String, Object?>{'name': 'Ann'});
    await db.commit(<fs.Write>[
      db.set('${SheetsSync.locks}/${_hash('students/a1')}', <String, Object?>{
        'at': now,
      }),
    ]);
    await expectLater(
      sync.sync('students/a1'),
      throwsA(isA<Problem>().having((Problem p) => p.status, 'status', 503)),
    );
    now = now.add(const Duration(minutes: 3));
    await sync.sync('students/a1');
    expect(sheet.data, hasLength(1), reason: 'a stale lock is taken over');
  });

  group('edits from the sheet', () {
    Future<Map<String, Object?>> edit(
      List<Map<String, Object?>> edits, {
      String id = 'a1',
      String? sign,
    }) {
      final List<int> raw = utf8.encode(
        jsonEncode(<String, Object?>{
          'spreadsheetId': 's1',
          'tab': 'Students',
          'row': 2,
          'id': id,
          'edits': edits,
        }),
      );
      final String ts = '${now.millisecondsSinceEpoch ~/ 1000}';
      final String nonce =
          'n-${now.microsecondsSinceEpoch}-${edits.length}-$id';
      final String sig =
          sign ??
          base64.encode(
            Hmac(
              sha256,
              utf8.encode(secret),
            ).convert(<int>[...utf8.encode('$ts.$nonce.'), ...raw]).bytes,
          );
      return sync.edit(raw, <String, String>{
        'x-sheets-timestamp': ts,
        'x-sheets-nonce': nonce,
        'x-sheets-signature': sig,
      });
    }

    setUp(() async {
      await put('a1', <String, Object?>{
        'name': 'Ann',
        'fee': <String, Object?>{'minor': 12000, 'currency': 'SGD'},
        'joined': DateTime.utc(2026, 1, 5),
      });
      await sync.sync('students/a1');
    });

    test(
      'an edit to a value the sheet saw is applied, and the row refreshed',
      () async {
        final Map<String, Object?> r = await edit(<Map<String, Object?>>[
          <String, Object?>{
            'header': 'Fee',
            'value': '150',
            'base': fieldHash(<String, Object?>{
              'minor': 12000,
              'currency': 'SGD',
            }),
          },
        ]);
        expect(r['applied'], <String>['fee']);
        final Map<String, Object?> doc = (await db.get('students/a1'))!;
        expect(doc['fee'], <String, Object?>{
          'minor': 15000,
          'currency': 'SGD',
        });
        expect(doc['updatedBy'], 'sheets');
        expect(doc['updatedAt'], isA<DateTime>());
        expect(sheet.data.single[4], 'saved');
        expect(tasks.queued.single.body, <String, Object?>{
          'path': 'students/a1',
        });
      },
    );

    test(
      'changed in the app since the sheet saw it: a conflict, nothing overwritten',
      () async {
        final String seen = fieldHash('Ann');
        await db.commit(<fs.Write>[
          db.update('students/a1', <String, Object?>{'name': 'Ann (app)'}),
        ]);
        final Map<String, Object?> r = await edit(<Map<String, Object?>>[
          <String, Object?>{
            'header': 'Name',
            'value': 'Ann (sheet)',
            'base': seen,
          },
        ]);
        expect(r['conflicts'], <String>['Name']);
        expect((await db.get('students/a1'))!['name'], 'Ann (app)');
        expect(sheet.data.single[4], contains('conflict'));
      },
    );

    test(
      'invalid values and read-only columns are refused, each named',
      () async {
        final Map<String, Object?> r = await edit(<Map<String, Object?>>[
          <String, Object?>{'header': 'Fee', 'value': 'lots', 'base': ''},
          <String, Object?>{
            'header': 'Joined',
            'value': '2026-02-01',
            'base': '',
          },
        ]);
        expect(r['invalid'], <String>[
          'Fee must be an amount with at most 2 decimal places',
        ]);
        expect(r['refused'], <String>['Joined']);
        expect(
          (await db.get('students/a1'))!['joined'],
          DateTime.utc(2026, 1, 5),
        );
      },
    );

    test('a forged, stale or replayed edit changes nothing', () async {
      await expectLater(
        edit(<Map<String, Object?>>[
          <String, Object?>{
            'header': 'Name',
            'value': 'x',
            'base': fieldHash('Ann'),
          },
        ], sign: 'AAAA'),
        throwsA(isA<Problem>().having((Problem p) => p.status, 'status', 401)),
      );
      final List<int> raw = utf8.encode(
        '{"spreadsheetId":"s1","tab":"Students","row":2,"id":"a1","edits":[]}',
      );
      final String ts = '${now.millisecondsSinceEpoch ~/ 1000}';
      Map<String, String> signedWith(String nonce, String t) =>
          <String, String>{
            'x-sheets-timestamp': t,
            'x-sheets-nonce': nonce,
            'x-sheets-signature': base64.encode(
              Hmac(
                sha256,
                utf8.encode(secret),
              ).convert(<int>[...utf8.encode('$t.$nonce.'), ...raw]).bytes,
            ),
          };
      await sync.edit(raw, signedWith('replayed-nonce-0001', ts));
      await expectLater(
        sync.edit(raw, signedWith('replayed-nonce-0001', ts)),
        throwsA(isA<Problem>().having((Problem p) => p.status, 'status', 409)),
      );
      final String old =
          '${now.subtract(const Duration(minutes: 10)).millisecondsSinceEpoch ~/ 1000}';
      await expectLater(
        sync.edit(raw, signedWith('stale-nonce-00000001', old)),
        throwsA(isA<Problem>().having((Problem p) => p.status, 'status', 401)),
      );
      expect((await db.get('students/a1'))!['name'], 'Ann');
    });

    test(
      'the Apps Script signature (made by Node, as Apps Script makes it) verifies',
      () async {
        // From Node's crypto: HMAC-SHA256 over "ts.nonce.body", UTF-8, base64.
        const String body =
            '{"spreadsheetId":"s1","tab":"Students","row":2,"id":"a1","edits":[{"header":"Name","value":"Zoë Tan","base":"x"}]}';
        now = DateTime.fromMillisecondsSinceEpoch(
          1790400000 * 1000,
          isUtc: true,
        );
        final Map<String, Object?> r = await sync
            .edit(utf8.encode(body), <String, String>{
              'x-sheets-timestamp': '1790400000',
              'x-sheets-nonce': '3f1c2b8e-8d6a-4c55-9d7e-0a1b2c3d4e5f',
              'x-sheets-signature':
                  'QKethHpneX5fGl+qUrvJKv8AO09WLtHJPfFQ3q/VIhk=',
            });
        expect(r['conflicts'], <String>[
          'Name',
        ], reason: 'accepted, then judged: base "x" is stale');
      },
    );
  });

  test('reconcile repairs stale and missing rows and marks orphans', () async {
    await put('a1', <String, Object?>{'name': 'Ann'});
    await put('b2', <String, Object?>{'name': 'Bo'});
    await sync.sync('students/a1');
    await db.commit(<fs.Write>[
      db.update('students/a1', <String, Object?>{'name': 'Ann Lee'}),
    ]);
    sheet.data.add(<Object?>['gone', 'Ghost', '', '', 'ok', 'v', '{}']);
    final Map<String, Object?> report = await sync.reconcile();
    expect(report['students'], <String, Object?>{
      'documents': 2,
      'queued': 2,
      'orphanRows': 1,
      'watched': true,
    });
    expect(sheet.data.last[4], 'deleted in the app');
  });
}

class _Sheet implements SheetsGateway {
  _Sheet(this.headers);
  final List<String> headers;
  final List<List<Object?>> data = <List<Object?>>[];

  @override
  Future<List<Object?>> header(String s, String t) async => headers;
  @override
  Future<List<List<Object?>>> rows(String s, String t) async => <List<Object?>>[
    for (final List<Object?> r in data) List<Object?>.of(r),
  ];
  @override
  Future<void> appendRow(String s, String t, List<Object?> v) async =>
      data.add(List<Object?>.of(v));
  @override
  Future<void> writeRow(String s, String t, int row, List<Object?> v) async =>
      data[row - 2] = List<Object?>.of(v);
  @override
  Future<void> writeCell(
    String s,
    String t,
    int row,
    int column,
    Object? v,
  ) async {
    final List<Object?> r = data[row - 2];
    while (r.length < column) {
      r.add('');
    }
    r[column - 1] = v;
  }
}

class _Owner extends http.BaseClient {
  final http.Client _inner = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['authorization'] = 'Bearer owner';
    return _inner.send(request);
  }
}

String _hash(String s) =>
    sha256.convert(utf8.encode(s)).toString().substring(0, 32);
