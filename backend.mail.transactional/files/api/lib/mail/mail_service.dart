import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:googleapis/firestore/v1.dart' as fs;
import 'package:googleapis/storage/v1.dart' as gcs;
import 'package:http/http.dart' as http;

import '../api.dart';
import '../routes/app_routes.dart';
import 'mail_message.dart';
import 'mail_transport.dart';
import 'svix.dart';

/// Where a message stands. It only moves forward: `delivered` after `sent`,
/// never back, and the three problem states are final.
enum MailState {
  queued,
  sent,
  delivered,

  /// The address does not exist or refuses mail. Suppressed from now on.
  bounced,

  /// The recipient marked it as spam. Suppressed from now on.
  complained,

  /// Every recipient was on the suppression list; nothing was sent.
  suppressed,

  /// The provider refused it for a reason that will not pass on its own.
  failed;

  bool get finished => this != queued;
}

/// Fetches an attachment's bytes from Cloud Storage at send time.
abstract interface class AttachmentSource {
  Future<List<int>> read(MailAttachment attachment);
}

class CloudStorageAttachments implements AttachmentSource {
  CloudStorageAttachments(this.api);
  final gcs.StorageApi api;

  @override
  Future<List<int>> read(MailAttachment a) async {
    final Object media = await api.objects.get(
      a.bucket,
      a.object,
      downloadOptions: gcs.DownloadOptions.fullMedia,
    );
    return (media as gcs.Media).stream.fold(<int>[], (List<int> b, List<int> c) => b..addAll(c));
  }
}

/// Transactional mail, through an outbox in Firestore.
///
/// A route adds [enqueue]'s write to the same commit as its own changes, then
/// calls [dispatch]. The message exists exactly when the change does. The
/// send is a Cloud Task named after the message, so dispatching twice queues
/// once; the provider call carries the message id as its idempotency key, so
/// a retried task sends once. If dispatching fails after the commit, the
/// sweep (every few minutes, from Cloud Scheduler) finds the message and
/// dispatches it.
class MailService {
  MailService({
    required this.db,
    required this.tasks,
    required this.transport,
    required this.attachments,
    required this.from,
    required this.webhookSecrets,
    this.retention = const Duration(days: 30),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Built from the API's context and settings:
  ///
  ///   MAIL_FROM              `Acme <no-reply@mail.acme.com>`, on a domain
  ///                          verified at the provider
  ///   RESEND_API_KEY         a sending-only key (secret)
  ///   MAIL_WEBHOOK_SECRET    the webhook's `whsec_…`; several, space-separated,
  ///                          during a rotation (secret)
  ///   MAIL_RETENTION_DAYS    how long bodies are kept after sending (30)
  factory MailService.from(AppContext context, {http.Client? client}) {
    final http.Client c = client ?? http.Client();
    return MailService(
      db: context.db,
      tasks: context.queue,
      transport: ResendTransport(c, apiKey: context.setting('RESEND_API_KEY')),
      attachments: CloudStorageAttachments(gcs.StorageApi(c)),
      from: context.setting('MAIL_FROM'),
      webhookSecrets: context.setting('MAIL_WEBHOOK_SECRET').split(' '),
      retention: Duration(
        days: int.tryParse(context.environment['MAIL_RETENTION_DAYS'] ?? '') ?? 30,
      ),
    );
  }

  final AppFirestore db;
  final TaskQueue tasks;
  final MailTransport transport;
  final AttachmentSource attachments;
  final String from;
  final List<String> webhookSecrets;
  final Duration retention;
  final DateTime Function() _clock;

  static const String outbox = '_mail_outbox';
  static const String suppressions = '_mail_suppressions';

  /// How long a queued message waits before the sweep assumes its task was
  /// never created.
  static const Duration dispatchGrace = Duration(minutes: 5);

  /// Attachments beyond this, together, are refused: Resend's limit is 40 MB
  /// after base64, which inflates by a third.
  static const int maxAttachmentBytes = 25 * 1024 * 1024;

  /// The write that puts [message] in the outbox, and its id. Add the write
  /// to the route's own commit; after it succeeds, [dispatch] the id.
  ({String id, fs.Write write}) enqueue(MailMessage message) {
    final String id = _newId();
    final DateTime now = _clock().toUtc();
    return (
      id: id,
      write: db.set('$outbox/$id', <String, Object?>{
        ...message.toFields(),
        'state': MailState.queued.name,
        'attempts': 0,
        'createdAt': now,
        'checkAfter': now.add(dispatchGrace),
      }, mustNotExist: true),
    );
  }

  /// Queues the send. Safe to call more than once.
  Future<void> dispatch(String id) => tasks.enqueue(
    name: 'mail-$id',
    path: '/internal/mail/send',
    body: <String, Object?>{'id': id},
  );

  /// For a route with nothing else to write: enqueue, commit, dispatch.
  Future<String> sendNow(MailMessage message) async {
    final ({String id, fs.Write write}) q = enqueue(message);
    await db.commit(<fs.Write>[q.write]);
    await dispatch(q.id);
    return q.id;
  }

  /// Sends message [id]: what the task calls. Throws a 503 [Problem] for a
  /// failure worth retrying, which makes Cloud Tasks try again with backoff.
  Future<MailState> send(String id) async {
    final Map<String, Object?>? doc = await db.get('$outbox/$id');
    if (doc == null) return MailState.failed;
    final MailState state = MailState.values.byName('${doc['state']}');
    if (state.finished) return state;

    final MailMessage message = MailMessage.fromFields(doc);
    final List<String> suppressed = <String>[
      for (final String to in message.to)
        if (await db.get('$suppressions/${suppressionId(to)}') != null) to,
    ];
    final List<String> recipients = <String>[
      for (final String to in message.to)
        if (!suppressed.contains(to)) to,
    ];
    if (recipients.isEmpty) {
      await _finish(id, MailState.suppressed, detail: 'every recipient is suppressed');
      return MailState.suppressed;
    }

    final List<AttachmentBytes> files = <AttachmentBytes>[];
    int total = 0;
    for (final MailAttachment a in message.attachments) {
      final List<int> bytes;
      try {
        bytes = await attachments.read(a);
      } on gcs.DetailedApiRequestError catch (e) {
        if (e.status == 404) {
          await _finish(id, MailState.failed, detail: 'attachment ${a.filename} no longer exists');
          return MailState.failed;
        }
        rethrow;
      }
      total += bytes.length;
      files.add((attachment: a, bytes: bytes));
    }
    if (total > maxAttachmentBytes) {
      await _finish(id, MailState.failed, detail: 'attachments exceed ${maxAttachmentBytes ~/ 1048576} MB');
      return MailState.failed;
    }

    final SendOutcome outcome = await transport.send(
      MailMessage(
        to: recipients,
        subject: message.subject,
        text: message.text,
        html: message.html,
        replyTo: message.replyTo,
        attachments: message.attachments,
        reference: message.reference,
      ),
      from: from,
      idempotencyKey: 'mail-$id',
      attachments: files,
    );
    final DateTime now = _clock().toUtc();
    switch (outcome) {
      case Sent(:final String providerId):
        await db.commit(<fs.Write>[
          db.update('$outbox/$id', <String, Object?>{
            'state': MailState.sent.name,
            'providerId': providerId,
            'sentAt': now,
            'attempts': ((doc['attempts'] as int?) ?? 0) + 1,
            'skipped': suppressed,
            'purgeAfter': now.add(retention),
            'checkAfter': null,
          }),
        ]);
        return MailState.sent;
      case Refused(:final String reason):
        await _finish(id, MailState.failed, detail: reason);
        return MailState.failed;
      case TryLater(:final String reason):
        await db.commit(<fs.Write>[
          db.update('$outbox/$id', <String, Object?>{
            'attempts': ((doc['attempts'] as int?) ?? 0) + 1,
            'lastError': reason,
            'checkAfter': now.add(dispatchGrace),
          }),
        ]);
        throw Problem(503, 'mail_retry', 'Will retry', detail: reason);
    }
  }

  Future<void> _finish(String id, MailState state, {required String detail}) =>
      db.commit(<fs.Write>[
        db.update('$outbox/$id', <String, Object?>{
          'state': state.name,
          'lastError': detail,
          'finishedAt': _clock().toUtc(),
          'checkAfter': null,
          'purgeAfter': _clock().toUtc().add(retention),
        }),
      ]);

  /// The scheduled sweep: dispatch messages whose task never ran, and remove
  /// bodies past their retention. Returns what it did, for the log.
  Future<({int dispatched, int purged})> sweep() async {
    final DateTime now = _clock().toUtc();
    int dispatched = 0;
    for (final ({String id, Map<String, Object?> data}) m in await db.query(
      outbox,
      range: (field: 'checkAfter', op: 'LESS_THAN', value: now),
      orderBy: 'checkAfter',
      limit: 200,
    )) {
      if (m.data['state'] != MailState.queued.name) continue;
      await db.commit(<fs.Write>[
        db.update('$outbox/${m.id}', <String, Object?>{'checkAfter': now.add(dispatchGrace)}),
      ]);
      await dispatch(m.id);
      dispatched++;
    }
    int purged = 0;
    for (final ({String id, Map<String, Object?> data}) m in await db.query(
      outbox,
      range: (field: 'purgeAfter', op: 'LESS_THAN', value: now),
      orderBy: 'purgeAfter',
      limit: 500,
    )) {
      // The record of who was written to, when, and what became of it is
      // kept; the words are not.
      await db.commit(<fs.Write>[
        db.update('$outbox/${m.id}', <String, Object?>{
          'text': '',
          'html': null,
          'attachments': <Object?>[],
          'purgeAfter': null,
          'purgedAt': now,
        }),
      ]);
      purged++;
    }
    return (dispatched: dispatched, purged: purged);
  }

  /// A delivery event from Resend: checked, then applied. Returns a problem
  /// description, or null when accepted.
  Future<String?> event(List<int> raw, Map<String, String> headers) async {
    final String? problem = svixProblem(
      rawBody: raw,
      id: headers['svix-id'],
      timestamp: headers['svix-timestamp'],
      signatures: headers['svix-signature'],
      secrets: webhookSecrets,
      now: _clock().toUtc(),
    );
    if (problem != null) return problem;

    final Object? decoded = jsonDecode(utf8.decode(raw));
    if (decoded is! Map<String, Object?>) return 'not an event';
    final String type = '${decoded['type']}';
    final Map<String, Object?> data =
        decoded['data'] is Map<String, Object?> ? decoded['data']! as Map<String, Object?> : const <String, Object?>{};
    final MailState? next = switch (type) {
      'email.delivered' => MailState.delivered,
      'email.bounced' => MailState.bounced,
      'email.complained' => MailState.complained,
      'email.suppressed' => MailState.suppressed,
      _ => null,
    };
    // Other events (sent, opened, delayed) change nothing here.
    if (next == null) return null;

    final List<String> to = <String>[
      for (final Object? t in (data['to'] as List<Object?>?) ?? const <Object?>[]) '$t',
    ];
    final DateTime now = _clock().toUtc();
    final List<fs.Write> writes = <fs.Write>[
      if (next != MailState.delivered)
        for (final String address in to)
          db.set('$suppressions/${suppressionId(address)}', <String, Object?>{
            'address': address.trim().toLowerCase(),
            'reason': next.name,
            'at': now,
          }),
    ];

    final Object? providerId = data['email_id'];
    if (providerId is String) {
      final List<({String id, Map<String, Object?> data})> found = await db.query(
        outbox,
        equals: <String, Object?>{'providerId': providerId},
        limit: 1,
      );
      if (found.isNotEmpty) {
        final MailState current = MailState.values.byName('${found.single.data['state']}');
        // Only forward: a late "delivered" never overwrites a bounce.
        if (current == MailState.sent || (current == MailState.delivered && next != MailState.delivered)) {
          writes.add(
            db.update('$outbox/${found.single.id}', <String, Object?>{
              'state': next.name,
              '${next.name}At': now,
            }),
          );
        }
      }
    }
    if (writes.isNotEmpty) await db.commit(writes);
    return null;
  }

  /// Puts a finished message back in the queue, for an operator who fixed
  /// what made it fail. Suppressed and delivered messages are not retried.
  Future<void> retry(String id) async {
    final Map<String, Object?>? doc = await db.get('$outbox/$id');
    if (doc == null) throw Problem.notFound;
    if (doc['state'] != MailState.failed.name) {
      throw const Problem(409, 'not_failed', 'Only a failed message can be retried');
    }
    await db.commit(<fs.Write>[
      db.update('$outbox/$id', <String, Object?>{
        'state': MailState.queued.name,
        'lastError': null,
        'checkAfter': _clock().toUtc().add(dispatchGrace),
      }),
    ]);
    // A new task name: the old one may still be reserved by Cloud Tasks.
    await tasks.enqueue(
      name: 'mail-$id-retry-${_clock().millisecondsSinceEpoch}',
      path: '/internal/mail/send',
      body: <String, Object?>{'id': id},
    );
  }

  static String suppressionId(String address) =>
      sha256.convert(utf8.encode(address.trim().toLowerCase())).toString();

  static final Random _random = Random.secure();
  static String _newId() => List<String>.generate(
    20,
    (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[_random.nextInt(36)],
  ).join();
}
