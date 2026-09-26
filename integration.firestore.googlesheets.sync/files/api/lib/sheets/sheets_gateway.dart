import 'dart:async';

import 'package:googleapis/sheets/v4.dart' as sheets;

/// The few things the sync does to a spreadsheet tab.
abstract interface class SheetsGateway {
  /// Every row from row 2 on, as the cells' plain values.
  Future<List<List<Object?>>> rows(String spreadsheetId, String tab);

  /// The header row.
  Future<List<Object?>> header(String spreadsheetId, String tab);

  /// Replaces row [row] (1-based) with [values].
  Future<void> writeRow(
    String spreadsheetId,
    String tab,
    int row,
    List<Object?> values,
  );

  /// Adds [values] as a new last row.
  Future<void> appendRow(
    String spreadsheetId,
    String tab,
    List<Object?> values,
  );

  /// Sets one cell, by column number (1-based).
  Future<void> writeCell(
    String spreadsheetId,
    String tab,
    int row,
    int column,
    Object? value,
  );
}

/// Google Sheets, as the application's service account (share each synced
/// spreadsheet with it). Writes are RAW: nothing the app stores becomes a
/// formula. A quota refusal (429) is retried with backoff before failing.
class GoogleSheetsGateway implements SheetsGateway {
  GoogleSheetsGateway(this.api, {this.pause = _sleep});

  final sheets.SheetsApi api;
  final Future<void> Function(Duration) pause;

  static Future<void> _sleep(Duration d) => Future<void>.delayed(d);

  @override
  Future<List<List<Object?>>> rows(String spreadsheetId, String tab) async {
    final sheets.ValueRange r = await _retry(
      () => api.spreadsheets.values.get(
        spreadsheetId,
        "'$tab'!A2:ZZ",
        valueRenderOption: 'UNFORMATTED_VALUE',
        dateTimeRenderOption: 'FORMATTED_STRING',
      ),
    );
    return <List<Object?>>[
      for (final List<Object?> row in r.values ?? const <List<Object?>>[]) row,
    ];
  }

  @override
  Future<List<Object?>> header(String spreadsheetId, String tab) async {
    final sheets.ValueRange r = await _retry(
      () => api.spreadsheets.values.get(spreadsheetId, "'$tab'!1:1"),
    );
    return (r.values?.isNotEmpty ?? false)
        ? r.values!.first
        : const <Object?>[];
  }

  @override
  Future<void> writeRow(
    String spreadsheetId,
    String tab,
    int row,
    List<Object?> values,
  ) => _retry(
    () => api.spreadsheets.values.update(
      sheets.ValueRange(values: <List<Object?>>[values]),
      spreadsheetId,
      "'$tab'!A$row",
      valueInputOption: 'RAW',
    ),
  );

  @override
  Future<void> appendRow(
    String spreadsheetId,
    String tab,
    List<Object?> values,
  ) => _retry(
    () => api.spreadsheets.values.append(
      sheets.ValueRange(values: <List<Object?>>[values]),
      spreadsheetId,
      "'$tab'!A1",
      valueInputOption: 'RAW',
      insertDataOption: 'INSERT_ROWS',
    ),
  );

  @override
  Future<void> writeCell(
    String spreadsheetId,
    String tab,
    int row,
    int column,
    Object? value,
  ) => _retry(
    () => api.spreadsheets.values.update(
      sheets.ValueRange(
        values: <List<Object?>>[
          <Object?>[value],
        ],
      ),
      spreadsheetId,
      "'$tab'!${columnLetters(column)}$row",
      valueInputOption: 'RAW',
    ),
  );

  Future<T> _retry<T>(Future<T> Function() call) async {
    Duration wait = const Duration(seconds: 2);
    for (int attempt = 1; ; attempt++) {
      try {
        return await call();
      } on sheets.DetailedApiRequestError catch (e) {
        if (e.status != 429 || attempt == 5) rethrow;
        await pause(wait);
        wait *= 2;
      }
    }
  }
}

/// 1 → A, 27 → AA.
String columnLetters(int column) {
  String s = '';
  int n = column;
  while (n > 0) {
    final int r = (n - 1) % 26;
    s = String.fromCharCode(65 + r) + s;
    n = (n - 1) ~/ 26;
  }
  return s;
}
