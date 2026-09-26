import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../api.dart';

/// The ledger contract: what the application and Exigence may ask of a
/// client's accounting system, whichever one it is.
///
/// Deliberately narrow. Citadel wraps the ledger; it never becomes one:
/// - only documents it created (by [externalRef]) or was asked about;
/// - invoices are created as **drafts**. Approving and sending one is a
///   decision for a person (or an approved Exigence run), not this module;
/// - every write carries a Citadel reference and an idempotency key, so the
///   same request twice makes one document.
abstract interface class Ledger {
  /// The customer for [contact], created if no contact carries its reference.
  Future<LedgerContact> contact(ContactRequest contact);

  /// A draft sales invoice, or the one already made for the same reference.
  Future<LedgerInvoice> draftInvoice(InvoiceRequest invoice);

  Future<LedgerInvoice?> invoice(String ledgerId);

  /// Approved sales invoices with money still owed, oldest first.
  Future<List<LedgerInvoice>> openReceivables({DateTime? asOf});
}

/// An amount in the smallest unit of [currency].
class Amount {
  const Amount(this.minor, this.currency);
  final int minor;
  final String currency;

  Map<String, Object?> toJson() => <String, Object?>{
    'minor': minor,
    'currency': currency,
  };

  /// A ledger's decimal (`12.3`), exactly, for a currency with [decimals].
  static Amount fromDecimal(num value, String currency, {int decimals = 2}) {
    final String s = value.toStringAsFixed(decimals);
    return Amount(int.parse(s.replaceAll('.', '')), currency);
  }

  /// The decimal a ledger's API expects.
  num toDecimal({int decimals = 2}) {
    if (decimals == 0) return minor;
    final String digits = minor.abs().toString().padLeft(decimals + 1, '0');
    final int cut = digits.length - decimals;
    return num.parse(
      '${minor < 0 ? '-' : ''}${digits.substring(0, cut)}.${digits.substring(cut)}',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Amount && other.minor == minor && other.currency == currency;
  @override
  int get hashCode => Object.hash(minor, currency);
  @override
  String toString() => '$minor $currency';
}

class ContactRequest {
  ContactRequest({required this.externalRef, required this.name, this.email}) {
    checkRef(externalRef);
    if (name.trim().isEmpty || name.length > 255) {
      throw Problem.invalid(
        'A contact needs a name of at most 255 characters.',
      );
    }
  }
  final String externalRef;
  final String name;
  final String? email;
}

class LedgerContact {
  const LedgerContact({
    required this.ledgerId,
    required this.name,
    required this.externalRef,
  });
  final String ledgerId;
  final String name;
  final String externalRef;

  Map<String, Object?> toJson() => <String, Object?>{
    'ledgerId': ledgerId,
    'name': name,
    'externalRef': externalRef,
  };
}

class InvoiceLine {
  InvoiceLine({
    required this.description,
    required this.quantity,
    required this.unitAmount,
    required this.accountCode,
    this.taxType,
  }) {
    if (description.trim().isEmpty || description.length > 4000) {
      throw Problem.invalid('Every line needs a description.');
    }
    if (quantity <= 0 || quantity > 1000000) {
      throw Problem.invalid('A quantity must be above 0.');
    }
  }
  final String description;
  final num quantity;
  final Amount unitAmount;

  /// The ledger's revenue account for the line: the client's chart of
  /// accounts, never guessed.
  final String accountCode;
  final String? taxType;
}

enum TaxTreatment { exclusive, inclusive, noTax }

class InvoiceRequest {
  InvoiceRequest({
    required this.externalRef,
    required this.contact,
    required this.lines,
    required this.date,
    required this.dueDate,
    this.tax = TaxTreatment.exclusive,
    this.reference,
  }) {
    checkRef(externalRef);
    if (lines.isEmpty || lines.length > 200) {
      throw Problem.invalid('An invoice needs between 1 and 200 lines.');
    }
    final Set<String> currencies = <String>{
      for (final InvoiceLine l in lines) l.unitAmount.currency,
    };
    if (currencies.length != 1) {
      throw Problem.invalid('Every line must be in one currency.');
    }
    if (dueDate.isBefore(date)) {
      throw Problem.invalid('The due date is before the invoice date.');
    }
  }
  final String externalRef;
  final ContactRequest contact;
  final List<InvoiceLine> lines;
  final DateTime date;
  final DateTime dueDate;
  final TaxTreatment tax;

  /// Shown to the customer; the Citadel reference is added to it.
  final String? reference;

  String get currency => lines.first.unitAmount.currency;
}

enum InvoiceState {
  draft,
  submitted,
  authorised,
  paid,
  voided,
  deleted,
  unknown,
}

class LedgerInvoice {
  const LedgerInvoice({
    required this.ledgerId,
    required this.state,
    required this.total,
    required this.amountDue,
    this.number,
    this.contactName,
    this.dueDate,
    this.externalRef,
  });
  final String ledgerId;
  final String? number;
  final InvoiceState state;
  final Amount total;
  final Amount amountDue;
  final String? contactName;
  final DateTime? dueDate;
  final String? externalRef;

  /// Days past due on [asOf]; 0 when not yet due.
  int daysOverdue(DateTime asOf) {
    final DateTime? due = dueDate;
    if (due == null) return 0;
    final int d = asOf.difference(due).inDays;
    return d > 0 ? d : 0;
  }

  Map<String, Object?> toJson({DateTime? asOf}) => <String, Object?>{
    'ledgerId': ledgerId,
    'number': number,
    'state': state.name,
    'total': total.toJson(),
    'amountDue': amountDue.toJson(),
    'contactName': contactName,
    'dueDate': dueDate?.toIso8601String().substring(0, 10),
    'externalRef': externalRef,
    if (asOf != null) 'daysOverdue': daysOverdue(asOf),
  };
}

/// Citadel's references: short, and safe inside a ledger's text fields and
/// its filter expressions.
void checkRef(String ref) {
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_./-]{0,59}$').hasMatch(ref)) {
    throw Problem.invalid(
      'A reference is up to 60 letters, digits and _ . / -, starting with a letter or digit.',
    );
  }
}

/// The idempotency key for a write: derived from what is being written, so
/// the same request always carries the same key.
String writeKey(String kind, String externalRef) =>
    sha256.convert(utf8.encode('$kind:$externalRef')).toString();

/// The ledger could not be reached or refused for now: worth retrying.
class LedgerUnavailable extends Problem {
  LedgerUnavailable(String detail, {int? retryAfterSeconds})
    : super(
        503,
        'ledger_unavailable',
        'The accounting system did not answer',
        detail: detail,
        headers: <String, String>{
          if (retryAfterSeconds != null) 'retry-after': '$retryAfterSeconds',
        },
      );
}

/// No ledger is connected, or the connection was withdrawn.
class LedgerNotConnected extends Problem {
  const LedgerNotConnected()
    : super(
        409,
        'ledger_not_connected',
        'No accounting system is connected',
        detail: 'An administrator connects one under Settings.',
      );
}
