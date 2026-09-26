import '../api.dart';

/// One email to send, checked before it is stored.
///
/// Plain text is required and HTML optional: every message is readable in a
/// client that shows no HTML, and a template's HTML is built from escaped
/// values (see [escapeHtml]). Attachments are references to Cloud Storage
/// objects, fetched only at send time, so the outbox never holds file bytes.
class MailMessage {
  MailMessage({
    required this.to,
    required this.subject,
    required this.text,
    this.html,
    this.replyTo,
    this.attachments = const <MailAttachment>[],
    this.reference,
  }) {
    final List<String> problems = <String>[
      if (to.isEmpty) 'no recipient',
      if (to.length > maxRecipients) 'more than $maxRecipients recipients',
      for (final String r in <String>[...to, ?replyTo])
        if (!isEmailAddress(r)) '"$r" is not an email address',
      if (subject.trim().isEmpty) 'no subject',
      if (subject.length > 250) 'subject over 250 characters',
      // A line break in a header is how one header becomes several.
      if (subject.contains('\n') || subject.contains('\r')) 'line break in subject',
      if (text.trim().isEmpty) 'no text',
      if (attachments.length > 10) 'more than 10 attachments',
    ];
    if (problems.isNotEmpty) {
      throw Problem.invalid('The message cannot be sent: ${problems.join('; ')}.');
    }
  }

  static const int maxRecipients = 50;

  final List<String> to;
  final String subject;
  final String text;
  final String? html;
  final String? replyTo;
  final List<MailAttachment> attachments;

  /// What this message is about in the application (`invoices/123`), so the
  /// outbox can be searched by it.
  final String? reference;

  Map<String, Object?> toFields() => <String, Object?>{
    'to': to,
    'subject': subject,
    'text': text,
    'html': ?html,
    'replyTo': ?replyTo,
    'attachments': <Object?>[for (final MailAttachment a in attachments) a.toFields()],
    'reference': ?reference,
  };

  static MailMessage fromFields(Map<String, Object?> f) => MailMessage(
    to: <String>[for (final Object? t in f['to']! as List<Object?>) '$t'],
    subject: f['subject']! as String,
    text: f['text']! as String,
    html: f['html'] as String?,
    replyTo: f['replyTo'] as String?,
    attachments: <MailAttachment>[
      for (final Object? a in (f['attachments'] as List<Object?>?) ?? const <Object?>[])
        MailAttachment.fromFields(a! as Map<String, Object?>),
    ],
    reference: f['reference'] as String?,
  );
}

/// A file in Cloud Storage to attach.
class MailAttachment {
  MailAttachment({
    required this.bucket,
    required this.object,
    required this.filename,
    required this.contentType,
  }) {
    if (!allowedTypes.contains(contentType)) {
      throw Problem.invalid('Attachments of type $contentType are not sent.');
    }
    if (filename.contains('/') || filename.contains('\\') || filename.contains('\n')) {
      throw Problem.invalid('An attachment name cannot contain a path or a line break.');
    }
  }

  /// What may be attached: documents and images people expect by email.
  /// Executables and archives are the ones that get a domain blocked.
  static const Set<String> allowedTypes = <String>{
    'application/pdf',
    'image/png',
    'image/jpeg',
    'text/csv',
    'text/plain',
    'text/calendar',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  };

  final String bucket;
  final String object;
  final String filename;
  final String contentType;

  Map<String, Object?> toFields() => <String, Object?>{
    'bucket': bucket,
    'object': object,
    'filename': filename,
    'contentType': contentType,
  };

  static MailAttachment fromFields(Map<String, Object?> f) => MailAttachment(
    bucket: f['bucket']! as String,
    object: f['object']! as String,
    filename: f['filename']! as String,
    contentType: f['contentType']! as String,
  );
}

bool isEmailAddress(String s) =>
    s.length <= 254 && RegExp(r'^[^@\s<>"]+@[^@\s<>"]+\.[^@\s<>"]+$').hasMatch(s);

/// Text made safe to put inside HTML: every value a template inserts goes
/// through this, so a customer named `<script>` is displayed, not run.
String escapeHtml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
