import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:googleapis/firestore/v1.dart' as fs;
import 'package:googleapis/sheets/v4.dart' as gsheets;
import 'package:http/http.dart' as http;

import '../api.dart';
import '../routes/app_routes.dart';
import 'sheets_codec.dart';
import 'sheets_config.dart';
import 'sheets_gateway.dart';

/// Two-way sync between Firestore collections and spreadsheet tabs.
///
/// Firestore is the source of truth. A change to a document queues a task
/// that writes the document's *current* state to its row, so duplicate or
/// out-of-order change events cannot leave a stale row. A person's edit in
/// the sheet arrives signed from Apps Script and is applied field by field,
/// only where the field still has the value the sheet last showed (its hash
/// in `_hashes`); otherwise the row says there is a conflict and nothing is
/// overwritten. A nightly reconcile repairs whatever drifted.
class SheetsSync {
  SheetsSync({
    required this.db,
    required this.tasks,
    required this.sheets,
    required this.mappings,
    required this.webhookSecrets,
    this.watched = const <String>{},
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// From the API's context:
  ///
  ///   SHEETS_WEBHOOK_SECRET   the Apps Script's signing secret; several,
  ///                           space-separated, during a rotation (secret)
  ///   SHEETS_COLLECTIONS      the collections Terraform's trigger watches
  factory SheetsSync.from(
    AppContext context,
    List<SheetMapping> mappings, {
    http.Client? client,
  }) => SheetsSync(
    db: context.db,
    tasks: context.queue,
    sheets: GoogleSheetsGateway(
      gsheets.SheetsApi(
        ScopedMetadataClient(
          client ?? http.Client(),
          scopes: <String>['https://www.googleapis.com/auth/spreadsheets'],
        ),
      ),
    ),
    mappings: mappings,
    webhookSecrets: context.setting('SHEETS_WEBHOOK_SECRET').split(' '),
    watched: <String>{
      for (final String c
          in (context.environment['SHEETS_COLLECTIONS'] ?? '').split(','))
        if (c.trim().isNotEmpty) c.trim(),
    },
  );

  final AppFirestore db;
  final TaskQueue tasks;
  final SheetsGateway sheets;
  final List<SheetMapping> mappings;
  final List<String> webhookSecrets;
  final Set<String> watched;
  final DateTime Function() _clock;

  static const String locks = '_sheets_locks';
  static const String nonces = '_sheets_nonces';

  SheetMapping? _forCollection(String c) {
    for (final SheetMapping m in mappings) {
      if (m.collection == c) return m;
    }
    return null;
  }

  /// A document changed (what the Firestore trigger reports): queue its sync.
  /// Changes within a few seconds share one task; the task reads the latest.
  Future<bool> changed(String documentPath) async {
    final List<String> parts = documentPath.split('/');
    if (parts.length != 2 || _forCollection(parts.first) == null) return false;
    final int bucket = _clock().millisecondsSinceEpoch ~/ 5000;
    await tasks.enqueue(
      name: 'sheets-${_hash(documentPath)}-$bucket',
      path: '/internal/sheets/sync',
      body: <String, Object?>{'path': documentPath},
    );
    return true;
  }

  /// Writes [documentPath]'s current state to its row: updated in place,
  /// appended when new, marked when the document is gone.
  Future<void> sync(String documentPath) async {
    final List<String> parts = documentPath.split('/');
    final SheetMapping? m = parts.length == 2
        ? _forCollection(parts.first)
        : null;
    if (m == null) return;
    final String id = parts.last;

    // One sync per document at a time: two concurrent syncs of a new
    // document would each append a row.
    final String lock = '$locks/${_hash(documentPath)}';
    await _takeLock(lock);
    try {
      final ({Map<String, Object?> data, String updateTime})? doc = await db
          .getVersioned(documentPath);
      await _ensureHeader(m);
      final List<List<Object?>> rows = await sheets.rows(
        m.spreadsheetId,
        m.tab,
      );
      final List<int> found = <int>[
        for (int i = 0; i < rows.length; i++)
          if (rows[i].isNotEmpty && '${rows[i].first}' == id) i + 2,
      ];
      if (doc == null) {
        for (final int row in found) {
          await sheets.writeCell(
            m.spreadsheetId,
            m.tab,
            row,
            m.headers.length - 2,
            'deleted in the app',
          );
        }
        return;
      }
      final List<Object?> values = rowFor(
        m,
        id,
        doc.data,
        doc.updateTime,
        status: 'ok',
      );
      if (found.isEmpty) {
        await sheets.appendRow(m.spreadsheetId, m.tab, values);
      } else {
        await sheets.writeRow(m.spreadsheetId, m.tab, found.first, values);
        for (final int extra in found.skip(1)) {
          await sheets.writeCell(
            m.spreadsheetId,
            m.tab,
            extra,
            m.headers.length - 2,
            'duplicate of row ${found.first}: delete this row',
          );
        }
      }
    } finally {
      await db.commit(<fs.Write>[db.delete(lock)]);
    }
  }

  /// Writes the mapping's header row into an empty tab.
  ///
  /// Row 1 is the header and rows are read from row 2, so without one the
  /// first row synced lands where no later sync looks. And an append finds
  /// the end of the table from row 1: on an empty tab, two documents synced at
  /// once both appended at A1 and one overwrote the other (seen live,
  /// 26/09/26). Writing the same header twice is harmless, so concurrent
  /// syncs need no lock for it. A header that differs is left alone for the
  /// nightly reconcile to report; this never writes over a person's row 1.
  Future<void> _ensureHeader(SheetMapping m) async {
    final List<Object?> head = await sheets.header(m.spreadsheetId, m.tab);
    if (head.every((Object? c) => '$c'.trim().isEmpty)) {
      await sheets.writeRow(m.spreadsheetId, m.tab, 1, m.headers);
    }
  }

  /// Claims [lock], taking over one left by a sync that died (older than two
  /// minutes) only if nobody else took it first.
  Future<void> _takeLock(String lock) async {
    final DateTime now = _clock().toUtc();
    final Map<String, Object?> claim = <String, Object?>{
      'at': now,
      'expireAt': now.add(const Duration(minutes: 2)),
    };
    try {
      await db.commit(<fs.Write>[db.set(lock, claim, mustNotExist: true)]);
      return;
    } on fs.DetailedApiRequestError catch (e) {
      if (e.status != 409) rethrow;
    }
    final ({Map<String, Object?> data, String updateTime})? held = await db
        .getVersioned(lock);
    final DateTime? at = held?.data['at'] as DateTime?;
    if (held != null &&
        at != null &&
        now.difference(at) > const Duration(minutes: 2)) {
      try {
        await db.commit(<fs.Write>[
          db.updateIfUnchanged(lock, claim, held.updateTime),
        ]);
        return;
      } on fs.DetailedApiRequestError catch (e) {
        if (e.status != 400 && e.status != 409) rethrow;
      }
    }
    throw const Problem(
      503,
      'sheets_busy',
      'Another sync of this row is running',
    );
  }

  /// The row for a document: id, the columns, status, version, hashes.
  static List<Object?> rowFor(
    SheetMapping m,
    String id,
    Map<String, Object?> data,
    String version, {
    required String status,
  }) => <Object?>[
    id,
    for (final SheetColumn c in m.columns) toCell(c.type, data[c.field]),
    status,
    version,
    jsonEncode(<String, String>{
      for (final SheetColumn c in m.columns) c.header: fieldHash(data[c.field]),
    }),
  ];

  /// A signed edit from the sheet's Apps Script. Returns what happened,
  /// which is also written to the row's status.
  Future<Map<String, Object?>> edit(
    List<int> raw,
    Map<String, String> headers,
  ) async {
    final String? problem = _signatureProblem(raw, headers);
    if (problem != null) {
      throw Problem(
        401,
        'bad_signature',
        'Signature not accepted',
        detail: problem,
      );
    }
    final String nonce = headers['x-sheets-nonce']!;
    try {
      await db.commit(<fs.Write>[
        db.set('$nonces/${_hash(nonce)}', <String, Object?>{
          'expireAt': _clock().toUtc().add(const Duration(minutes: 15)),
        }, mustNotExist: true),
      ]);
    } on fs.DetailedApiRequestError catch (e) {
      if (e.status == 409) {
        throw const Problem(409, 'replayed', 'This edit was already received');
      }
      rethrow;
    }

    final Map<String, Object?> body =
        jsonDecode(utf8.decode(raw)) as Map<String, Object?>;
    final String spreadsheetId = '${body['spreadsheetId']}';
    final String tab = '${body['tab']}';
    final int row = (body['row'] as int?) ?? 0;
    final String id = '${body['id'] ?? ''}';
    SheetMapping? m;
    for (final SheetMapping x in mappings) {
      if (x.spreadsheetId == spreadsheetId && x.tab == tab) m = x;
    }
    if (m == null) throw Problem.invalid('This tab is not synced.');
    final int statusColumn = m.headers.length - 2;

    Future<Map<String, Object?>> answer(
      String status,
      Map<String, Object?> detail,
    ) async {
      if (row >= 2) {
        await sheets.writeCell(spreadsheetId, tab, row, statusColumn, status);
      }
      return <String, Object?>{'status': status, ...detail};
    }

    if (id.isEmpty) {
      return answer(
        'rows are added in the app, not here',
        const <String, Object?>{},
      );
    }
    final String path = '${m.collection}/$id';
    final ({Map<String, Object?> data, String updateTime})? doc = await db
        .getVersioned(path);
    if (doc == null) {
      return answer('deleted in the app', const <String, Object?>{});
    }

    final Map<String, Object?> changes = <String, Object?>{};
    final List<String> refused = <String>[];
    final List<String> invalid = <String>[];
    final List<String> conflicts = <String>[];
    for (final Object? e
        in (body['edits'] as List<Object?>?) ?? const <Object?>[]) {
      final Map<String, Object?> edit = e! as Map<String, Object?>;
      final String header = '${edit['header']}';
      final SheetColumn? c = m.byHeader(header);
      if (c == null || !c.editable) {
        refused.add(header);
        continue;
      }
      final ({Object? value, String? problem}) parsed = fromCell(
        c.type,
        '${edit['value'] ?? ''}',
      );
      if (parsed.problem != null) {
        invalid.add('$header ${parsed.problem}');
        continue;
      }
      if (fieldHash(doc.data[c.field]) != '${edit['base']}') {
        conflicts.add(header);
        continue;
      }
      changes[c.field] = parsed.value;
    }

    if (changes.isNotEmpty) {
      try {
        await db.commit(<fs.Write>[
          withServerTime(
            db.updateIfUnchanged(path, <String, Object?>{
              ...changes,
              'updatedBy': 'sheets',
              'updatedAt': serverTimestamp,
            }, doc.updateTime),
            <String>['updatedAt'],
          ),
        ]);
      } on fs.DetailedApiRequestError catch (e) {
        // Changed in the app between reading and writing.
        if (e.status != 400 && e.status != 409) rethrow;
        conflicts.addAll(<String>[
          for (final SheetColumn c in m.columns)
            if (changes.containsKey(c.field)) c.header,
        ]);
        changes.clear();
      }
    }
    // Refresh the row either way: applied values get new hashes, refused
    // and conflicting ones are put back to what the app holds.
    await changed(path);

    final List<String> notes = <String>[
      if (conflicts.isNotEmpty)
        'conflict, changed in the app: ${conflicts.join(', ')}',
      if (invalid.isNotEmpty) 'not saved: ${invalid.join('; ')}',
      if (refused.isNotEmpty) 'read-only: ${refused.join(', ')}',
    ];
    return answer(
      notes.isEmpty
          ? (changes.isEmpty ? 'no change' : 'saved')
          : notes.join(' · '),
      <String, Object?>{
        'applied': changes.keys.toList(),
        'conflicts': conflicts,
        'invalid': invalid,
        'refused': refused,
      },
    );
  }

  /// Compares every mapped collection with its tab and repairs drift: queues
  /// a sync for any document whose row is missing or stale, and marks rows
  /// with no document. Also reports collections Terraform does not watch.
  Future<Map<String, Object?>> reconcile() async {
    final Map<String, Object?> report = <String, Object?>{};
    for (final SheetMapping m in mappings) {
      final Map<String, String> rowVersions = <String, String>{};
      final List<List<Object?>> rows = await sheets.rows(
        m.spreadsheetId,
        m.tab,
      );
      final int versionIndex = m.headers.length - 2;
      for (int i = 0; i < rows.length; i++) {
        final List<Object?> r = rows[i];
        if (r.isEmpty || '${r.first}'.isEmpty) continue;
        rowVersions['${r.first}'] = r.length > versionIndex
            ? '${r[versionIndex]}'
            : '';
      }
      int queued = 0;
      int documents = 0;
      final Set<String> seen = <String>{};
      String? after;
      do {
        final List<({String id, Map<String, Object?> data})> page = await db
            .query(m.collection, limit: 300, startAfterId: after);
        for (final ({String id, Map<String, Object?> data}) d in page) {
          documents++;
          seen.add(d.id);
          final ({Map<String, Object?> data, String updateTime})? v = await db
              .getVersioned('${m.collection}/${d.id}');
          if (v != null && rowVersions[d.id] != v.updateTime) {
            await changed('${m.collection}/${d.id}');
            queued++;
          }
        }
        after = page.length == 300 ? page.last.id : null;
      } while (after != null);
      int orphans = 0;
      for (int i = 0; i < rows.length; i++) {
        final String id = rows[i].isEmpty ? '' : '${rows[i].first}';
        if (id.isNotEmpty && !seen.contains(id)) {
          await sheets.writeCell(
            m.spreadsheetId,
            m.tab,
            i + 2,
            m.headers.length - 2,
            'deleted in the app',
          );
          orphans++;
        }
      }
      report[m.collection] = <String, Object?>{
        'documents': documents,
        'queued': queued,
        'orphanRows': orphans,
        'watched': watched.contains(m.collection),
      };
    }
    return report;
  }

  String? _signatureProblem(List<int> raw, Map<String, String> headers) {
    final String? ts = headers['x-sheets-timestamp'];
    final String? nonce = headers['x-sheets-nonce'];
    final String? sig = headers['x-sheets-signature'];
    if (ts == null || nonce == null || sig == null || nonce.length < 16) {
      return 'missing headers';
    }
    final int? t = int.tryParse(ts);
    if (t == null) return 'malformed timestamp';
    final DateTime sent = DateTime.fromMillisecondsSinceEpoch(
      t * 1000,
      isUtc: true,
    );
    if (_clock().toUtc().difference(sent).abs() > const Duration(minutes: 5)) {
      return 'timestamp outside the window';
    }
    final List<int> signed = <int>[...utf8.encode('$ts.$nonce.'), ...raw];
    final List<int> offered;
    try {
      offered = base64.decode(sig);
    } on FormatException {
      return 'malformed signature';
    }
    for (final String secret in webhookSecrets) {
      if (secret.isEmpty) continue;
      final List<int> expected = Hmac(
        sha256,
        utf8.encode(secret),
      ).convert(signed).bytes;
      if (_equal(expected, offered)) return null;
    }
    return 'no signature matches';
  }

  static bool _equal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    int d = 0;
    for (int i = 0; i < a.length; i++) {
      d |= a[i] ^ b[i];
    }
    return d == 0;
  }

  static String _hash(String s) =>
      sha256.convert(utf8.encode(s)).toString().substring(0, 32);
}
