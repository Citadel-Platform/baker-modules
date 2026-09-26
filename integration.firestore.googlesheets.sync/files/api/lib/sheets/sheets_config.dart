/// Which collections sync to which spreadsheet tabs.
///
/// Empty until the application names its own. For example:
///
///     SheetMapping(
///       collection: 'students',
///       spreadsheetId: '1AbC…',   // share the sheet with the app's service account
///       tab: 'Students',
///       columns: <SheetColumn>[
///         SheetColumn('name', 'Name', SheetType.text, editable: true),
///         SheetColumn('fee', 'Fee', SheetType.money('SGD'), editable: true),
///         SheetColumn('joined', 'Joined', SheetType.date),
///       ],
///     ),
///
/// Each collection must also be listed in `sheets_collections` in Terraform,
/// which creates the trigger that notices its changes; the nightly reconcile
/// reports any that are not.
const List<SheetMapping> sheetMappings = <SheetMapping>[];

class SheetMapping {
  const SheetMapping({
    required this.collection,
    required this.spreadsheetId,
    required this.tab,
    required this.columns,
  });

  /// A top-level collection.
  final String collection;
  final String spreadsheetId;
  final String tab;
  final List<SheetColumn> columns;

  /// The header row: the id, the data columns, then the control columns the
  /// sync keeps (hide and protect them; `install()` in the Apps Script does).
  List<String> get headers => <String>[
    idHeader,
    for (final SheetColumn c in columns) c.header,
    statusHeader,
    versionHeader,
    hashesHeader,
  ];

  SheetColumn? byHeader(String header) {
    for (final SheetColumn c in columns) {
      if (c.header == header) return c;
    }
    return null;
  }

  static const String idHeader = '_id';
  static const String statusHeader = '_status';
  static const String versionHeader = '_version';
  static const String hashesHeader = '_hashes';
}

class SheetColumn {
  const SheetColumn(
    this.field,
    this.header,
    this.type, {
    this.editable = false,
  });

  /// The document field.
  final String field;
  final String header;
  final SheetType type;

  /// Whether a person may change it in the sheet. Everything else is
  /// display: an edit to it is refused and the cell put back.
  final bool editable;
}

/// How a field is shown in a cell and read back from one.
sealed class SheetType {
  const SheetType();
  static const SheetType text = TextType();
  static const SheetType integer = IntegerType();
  static const SheetType date = DateType();
  static const SheetType boolean = BooleanType();

  /// Stored as `{minor, currency}`; shown as a decimal in that currency.
  const factory SheetType.money(String currency, {int decimals}) = MoneyType;
}

final class TextType extends SheetType {
  const TextType();
}

final class IntegerType extends SheetType {
  const IntegerType();
}

final class DateType extends SheetType {
  const DateType();
}

final class BooleanType extends SheetType {
  const BooleanType();
}

final class MoneyType extends SheetType {
  const MoneyType(this.currency, {this.decimals = 2});
  final String currency;
  final int decimals;
}
