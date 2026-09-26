import 'package:{{baker.packageName}}/src/data/audit.dart';
import 'package:{{baker.packageName}}/src/data/document_reader.dart';
import 'package:{{baker.packageName}}/src/data/firestore_failures.dart';
import 'package:{{baker.packageName}}/src/data/firestore_page_source.dart';
import 'package:{{baker.packageName}}/src/foundation/failure.dart';
import 'package:{{baker.packageName}}/src/money/money.dart';
import 'package:{{baker.packageName}}/src/table/table_query.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

class _Row {
  const _Row(this.id, this.name, this.total);
  final String id;
  final String name;
  final Money total;
}

void main() {
  late FakeFirebaseFirestore db;

  CollectionReference<_Row> rows() => db
      .collection('records')
      .withConverter<_Row>(
        fromFirestore: (DocumentSnapshot<Map<String, dynamic>> s, _) {
          final DocumentReader r = DocumentReader(s);
          return _Row(r.id, r.string('name'), r.money('total'));
        },
        toFirestore: (_Row row, _) => <String, Object?>{
          'name': row.name,
          'nameLower': row.name.toLowerCase(),
          'total': moneyToFirestore(row.total),
        },
      );

  FirestorePageSource<_Row> source() => FirestorePageSource<_Row>(
    query: rows,
    sortFields: <String, String>{'name': 'name'},
    defaultSort: 'name',
    filterFields: <String, String>{'status': 'status'},
    searchField: 'nameLower',
  );

  setUp(() async {
    db = FakeFirebaseFirestore();
    for (final String name in <String>['Cara', 'Ann', 'Bea', 'Anton', 'Dev']) {
      await rows().doc(name.toLowerCase()).set(
        _Row(name, name, Money(minor: 100, currency: 'SGD')),
      );
    }
  });

  test('pages by cursor, in order, with nothing skipped or repeated', () async {
    final List<String> seen = <String>[];
    Object? cursor;
    int pages = 0;
    do {
      final TablePage<_Row> page = await source().fetch(
        const TableQuery(pageSize: 2),
        cursor: cursor,
      );
      seen.addAll(page.items.map((_Row r) => r.name));
      cursor = page.nextCursor;
      pages++;
    } while (cursor != null && pages < 10);
    expect(seen, <String>['Ann', 'Anton', 'Bea', 'Cara', 'Dev']);
  });

  test('sorts descending when asked', () async {
    final TablePage<_Row> page = await source().fetch(
      const TableQuery(sortBy: 'name', descending: true),
    );
    expect(page.items.first.name, 'Dev');
    expect(page.nextCursor, isNull, reason: 'fewer rows than a page');
  });

  test('searches by prefix, case-insensitively', () async {
    final TablePage<_Row> page = await source().fetch(const TableQuery(search: 'AN'));
    expect(page.items.map((_Row r) => r.name), <String>['Ann', 'Anton']);
  });

  test('a record with the wrong shape is named, not half-shown', () async {
    await db.collection('records').doc('broken').set(<String, Object?>{
      'name': 'Eve',
      'total': 12.5,
    });
    await expectLater(
      source().fetch(const TableQuery(sortBy: 'name', descending: true)),
      throwsA(
        isA<InvalidRecord>().having(
          (InvalidRecord f) => f.message,
          'message',
          allOf(contains('records/broken'), contains('total')),
        ),
      ),
    );
  });

  test('money round-trips as whole minor units', () async {
    final Money m = Money.parse('1234.56', 'SGD');
    await rows().doc('m').set(_Row('m', 'Money', m));
    final Map<String, dynamic> raw = (await db.doc('records/m').get()).data()!;
    expect(raw['total'], <String, Object?>{'minor': 123456, 'currency': 'SGD'});
    expect((await rows().doc('m').get()).data()!.total, m);
  });

  test('stamps name the person and use the server clock', () {
    final Map<String, Object> created = stampCreate('u1');
    expect(created['createdBy'], 'u1');
    expect(created['updatedBy'], 'u1');
    expect(created['createdAt'], isA<FieldValue>());
    expect(stampUpdate('u2').keys, <String>['updatedBy', 'updatedAt']);
  });

  test('Firestore errors read as sentences', () {
    AppFailure f(String code) =>
        firestoreFailure(FirebaseException(plugin: 'cloud_firestore', code: code));
    expect(f('permission-denied'), isA<NotPermitted>());
    expect(f('unavailable').retryable, isTrue);
    expect(f('failed-precondition'), isA<NotConfigured>());
    expect(f('something-new').message, isNot(contains('something-new')));
  });
}
