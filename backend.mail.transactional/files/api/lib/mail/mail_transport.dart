import 'dart:convert';

import 'package:http/http.dart' as http;

import 'mail_message.dart';

/// What became of an attempt to hand a message to the provider.
sealed class SendOutcome {
  const SendOutcome();
}

final class Sent extends SendOutcome {
  const Sent(this.providerId);
  final String providerId;
}

/// Worth trying again later: a timeout, a rate limit, the provider down.
final class TryLater extends SendOutcome {
  const TryLater(this.reason);
  final String reason;
}

/// Will fail the same way every time until something changes: an unverified
/// sending domain, a revoked key, a message the provider refuses.
final class Refused extends SendOutcome {
  const Refused(this.reason);
  final String reason;
}

/// An attachment's bytes, fetched at send time.
typedef AttachmentBytes = ({MailAttachment attachment, List<int> bytes});

abstract interface class MailTransport {
  /// Sends [message] once however often it is called with the same
  /// [idempotencyKey].
  Future<SendOutcome> send(
    MailMessage message, {
    required String from,
    required String idempotencyKey,
    List<AttachmentBytes> attachments,
  });
}

/// Resend's API (`POST https://api.resend.com/emails`).
///
/// The idempotency key goes in Resend's `Idempotency-Key` header: a repeat
/// within 24 hours returns the first answer instead of sending again, which
/// is what makes a retried task safe.
class ResendTransport implements MailTransport {
  ResendTransport(this._client, {required this.apiKey, Uri? endpoint})
    : endpoint = endpoint ?? Uri.parse('https://api.resend.com/emails');

  final http.Client _client;
  final String apiKey;
  final Uri endpoint;

  @override
  Future<SendOutcome> send(
    MailMessage message, {
    required String from,
    required String idempotencyKey,
    List<AttachmentBytes> attachments = const <AttachmentBytes>[],
  }) async {
    final http.Response r;
    try {
      r = await _client
          .post(
            endpoint,
            headers: <String, String>{
              'authorization': 'Bearer $apiKey',
              'content-type': 'application/json',
              'idempotency-key': idempotencyKey,
            },
            body: jsonEncode(<String, Object?>{
              'from': from,
              'to': message.to,
              'subject': message.subject,
              'text': message.text,
              'html': ?message.html,
              'reply_to': ?message.replyTo,
              if (attachments.isNotEmpty)
                'attachments': <Object?>[
                  for (final AttachmentBytes a in attachments)
                    <String, Object?>{
                      'filename': a.attachment.filename,
                      'content': base64.encode(a.bytes),
                      'content_type': a.attachment.contentType,
                    },
                ],
            }),
          )
          .timeout(const Duration(seconds: 30));
    } on Exception catch (e) {
      return TryLater('no answer from Resend (${e.runtimeType})');
    }

    Map<String, Object?> body = const <String, Object?>{};
    try {
      final Object? d = jsonDecode(r.body);
      if (d is Map<String, Object?>) body = d;
    } on FormatException {
      // An empty or non-JSON body; the status decides.
    }
    final String said = '${body['message'] ?? body['name'] ?? r.reasonPhrase ?? ''}';

    if (r.statusCode >= 200 && r.statusCode < 300) {
      final Object? id = body['id'];
      if (id is String && id.isNotEmpty) return Sent(id);
      return const TryLater('Resend accepted the message but returned no id');
    }
    // Another attempt with this key is still running: its answer will come.
    if (r.statusCode == 409 && body['name'] == 'concurrent_idempotent_requests') {
      return const TryLater('an earlier attempt is still being processed');
    }
    if (r.statusCode == 429 || r.statusCode >= 500) {
      return TryLater('Resend answered ${r.statusCode}: $said');
    }
    return Refused('Resend refused it (${r.statusCode}): $said');
  }
}
