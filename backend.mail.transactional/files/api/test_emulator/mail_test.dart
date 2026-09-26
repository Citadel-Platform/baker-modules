@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:api/api.dart';
import 'package:api/mail/mail_message.dart';
import 'package:api/mail/mail_routes.dart';
import 'package:api/mail/mail_service.dart';
import 'package:api/mail/mail_transport.dart';
import 'package:api/routes/app_routes.dart';
import 'package:crypto/crypto.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:googleapis/firestore/v1.dart' as fs;
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Mail against the Firestore emulator: the outbox, sending, the sweep,
/// delivery events and suppression, with the provider and the queue faked.
///
///     firebase emulators:exec --only firestore --project demo-local \
///       "cd api && dart test test_emulator/mail_test.dart"
void main() {
  final String host = Platform.environment['FIRESTORE_EMULATOR_HOST'] ?? '';
  late AppFirestore db;
  late MemoryTaskQueue tasks;
  late _Transport transport;
  late MailService mail;
  late DateTime now;
  const String secret = 'whsec_c2VjcmV0LXZhbHVlLWZvci10ZXN0cw==';

  setUpAll(() {
    expect(host, isNotEmpty, reason: 'Run under firebase emulators:exec.');
  });

  setUp(() async {
    // A database per test run, so tests do not see each other's documents.
    db = AppFirestore(
      fs.FirestoreApi(_Owner(), rootUrl: 'http://$host/'),
      projectId: 'demo-mail-${DateTime.now().microsecondsSinceEpoch}',
    );
    tasks = MemoryTaskQueue();
    transport = _Transport();
    now = DateTime.now().toUtc();
    mail = MailService(
      db: db,
      tasks: tasks,
      transport: transport,
      attachments: _Files(),
      from: 'Acme <no-reply@mail.acme.test>',
      webhookSecrets: <String>['whsec_old', secret],
      retention: const Duration(days: 30),
      clock: () => now,
    );
  });

  MailMessage message({List<String>? to}) => MailMessage(
    to: to ?? <String>['ann@example.com'],
    subject: 'Invoice 42',
    text: 'Your invoice is attached.',
    attachments: <MailAttachment>[
      MailAttachment(bucket: 'b', object: 'invoices/42.pdf', filename: 'invoice-42.pdf', contentType: 'application/pdf'),
    ],
    reference: 'invoices/42',
  );

  test('the change and its message commit together, or neither does', () async {
    final ({String id, fs.Write write}) q = mail.enqueue(message());
    // A commit that fails (the record already exists) takes the message with it.
    await db.commit(<fs.Write>[db.set('invoices/42', <String, Object?>{'n': 1})]);
    await expectLater(
      db.commit(<fs.Write>[
        db.set('invoices/42', <String, Object?>{'n': 2}, mustNotExist: true),
        q.write,
      ]),
      throwsA(isA<fs.DetailedApiRequestError>()),
    );
    expect(await db.get('${MailService.outbox}/${q.id}'), isNull);

    final ({String id, fs.Write write}) ok = mail.enqueue(message());
    await db.commit(<fs.Write>[db.set('invoices/43', <String, Object?>{'n': 1}), ok.write]);
    expect((await db.get('${MailService.outbox}/${ok.id}'))!['state'], 'queued');
  });

  test('queued, dispatched once, sent once, with the attachment', () async {
    final String id = await mail.sendNow(message());
    await mail.dispatch(id);
    expect(tasks.queued, hasLength(1), reason: 'named tasks queue once');
    expect(tasks.queued.single.path, '/internal/mail/send');

    expect(await mail.send(id), MailState.sent);
    expect(await mail.send(id), MailState.sent, reason: 'a repeat changes nothing');
    expect(transport.sends, hasLength(1));
    expect(transport.sends.single.key, 'mail-$id');
    expect(transport.sends.single.files.single.attachment.filename, 'invoice-42.pdf');
    final Map<String, Object?> doc = (await db.get('${MailService.outbox}/$id'))!;
    expect(doc['providerId'], 'resend-1');
    expect(doc['attempts'], 1);
  });

  test('a transient failure is retried by the queue; a refusal is final', () async {
    final String id = await mail.sendNow(message());
    transport.next = const TryLater('Resend answered 503');
    await expectLater(mail.send(id), throwsA(isA<Problem>().having((Problem p) => p.status, 'status', 503)));
    Map<String, Object?> doc = (await db.get('${MailService.outbox}/$id'))!;
    expect(doc['state'], 'queued');
    expect(doc['attempts'], 1);
    expect(doc['lastError'], contains('503'));

    transport.next = const Refused('The a.co domain is not verified.');
    expect(await mail.send(id), MailState.failed);
    doc = (await db.get('${MailService.outbox}/$id'))!;
    expect(doc['lastError'], contains('not verified'));

    // An operator fixes the domain and retries it.
    await mail.retry(id);
    expect(await mail.send(id), MailState.sent);
  });

  test('suppressed addresses are skipped; all suppressed means nothing sent', () async {
    await db.commit(<fs.Write>[
      db.set('${MailService.suppressions}/${MailService.suppressionId('Bounced@Example.com ')}', <String, Object?>{
        'address': 'bounced@example.com',
        'reason': 'bounced',
      }),
    ]);
    final String some = await mail.sendNow(message(to: <String>['ann@example.com', 'bounced@example.com']));
    expect(await mail.send(some), MailState.sent);
    expect(transport.sends.single.to, <String>['ann@example.com']);
    final String all = await mail.sendNow(message(to: <String>['bounced@example.com']));
    expect(await mail.send(all), MailState.suppressed);
    expect(transport.sends, hasLength(1));
  });

  test('the sweep dispatches stranded messages and removes old bodies', () async {
    // Committed, but the task was never created (the process died).
    final ({String id, fs.Write write}) q = mail.enqueue(message());
    await db.commit(<fs.Write>[q.write]);
    expect(tasks.queued, isEmpty);
    now = now.add(const Duration(minutes: 6));
    expect((await mail.sweep()).dispatched, 1);
    expect(tasks.queued.single.body, <String, Object?>{'id': q.id});
    expect((await mail.sweep()).dispatched, 0, reason: 'checked again only after the grace period');

    await mail.send(q.id);
    now = now.add(const Duration(days: 31));
    expect((await mail.sweep()).purged, 1);
    final Map<String, Object?> doc = (await db.get('${MailService.outbox}/${q.id}'))!;
    expect(doc['text'], '');
    expect(doc['attachments'], isEmpty);
    expect(doc['to'], <String>['ann@example.com'], reason: 'who and when are kept');
    expect(doc['state'], 'sent');
  });

  group('delivery events', () {
    List<int> event(String type, String emailId, List<String> to) =>
        utf8.encode(jsonEncode(<String, Object?>{
          'type': type,
          'created_at': now.toIso8601String(),
          'data': <String, Object?>{'email_id': emailId, 'to': to},
        }));

    Map<String, String> signed(List<int> raw, {String id = 'msg_1'}) {
      final String ts = '${now.millisecondsSinceEpoch ~/ 1000}';
      final List<int> key = base64.decode(secret.substring(6));
      final String sig = base64.encode(
        Hmac(sha256, key).convert(<int>[...utf8.encode('$id.$ts.'), ...raw]).bytes,
      );
      return <String, String>{'svix-id': id, 'svix-timestamp': ts, 'svix-signature': 'v1,$sig'};
    }

    test('delivered, then a bounce suppresses the address; never backwards', () async {
      final String id = await mail.sendNow(message());
      await mail.send(id);
      List<int> raw = event('email.delivered', 'resend-1', <String>['ann@example.com']);
      expect(await mail.event(raw, signed(raw)), isNull);
      expect((await db.get('${MailService.outbox}/$id'))!['state'], 'delivered');

      raw = event('email.bounced', 'resend-1', <String>['ann@example.com']);
      expect(await mail.event(raw, signed(raw, id: 'msg_2')), isNull);
      expect((await db.get('${MailService.outbox}/$id'))!['state'], 'bounced');
      expect(await db.get('${MailService.suppressions}/${MailService.suppressionId('ann@example.com')}'), isNotNull);

      // A late "delivered" does not undo the bounce.
      raw = event('email.delivered', 'resend-1', <String>['ann@example.com']);
      await mail.event(raw, signed(raw, id: 'msg_3'));
      expect((await db.get('${MailService.outbox}/$id'))!['state'], 'bounced');
    });

    test('a forged event changes nothing', () async {
      final String id = await mail.sendNow(message());
      await mail.send(id);
      final List<int> raw = event('email.complained', 'resend-1', <String>['ann@example.com']);
      final Map<String, String> headers = signed(event('email.delivered', 'resend-1', <String>[]));
      expect(await mail.event(raw, headers), isNotNull);
      expect((await db.get('${MailService.outbox}/$id'))!['state'], 'sent');
      expect(await db.get('${MailService.suppressions}/${MailService.suppressionId('ann@example.com')}'), isNull);
    });

    test('the webhook route answers 204 when signed, 401 when not', () async {
      final Handler api = buildApi(
        routes: mailRoutes(
          AppContext(internalCaller: 'i@x.iam.gserviceaccount.com', firestore: db, tasks: tasks),
          service: () => mail,
        ),
        services: ApiServices(
          tokens: FirebaseTokenVerifier(projectId: 'p', keys: _NoKeys()),
          revocation: _Never(),
          idempotency: MemoryIdempotencyStore(),
        ),
      );
      final List<int> raw = event('email.delivered', 'none', <String>[]);
      Future<Response> post(Map<String, String> h) async => await api(Request(
        'POST',
        Uri.parse('https://api.test/webhooks/mail'),
        headers: <String, String>{'content-type': 'application/json', ...h},
        body: raw,
      ));
      expect((await post(signed(raw))).statusCode, 204);
      expect((await post(<String, String>{'svix-id': 'x', 'svix-timestamp': '1', 'svix-signature': 'v1,AAAA'})).statusCode, 401);
    });
  });
}

class _Transport implements MailTransport {
  final List<({List<String> to, String key, List<AttachmentBytes> files})> sends =
      <({List<String> to, String key, List<AttachmentBytes> files})>[];
  SendOutcome? next;

  @override
  Future<SendOutcome> send(
    MailMessage message, {
    required String from,
    required String idempotencyKey,
    List<AttachmentBytes> attachments = const <AttachmentBytes>[],
  }) async {
    final SendOutcome? forced = next;
    next = null;
    if (forced != null) return forced;
    sends.add((to: message.to, key: idempotencyKey, files: attachments));
    return const Sent('resend-1');
  }
}

class _Files implements AttachmentSource {
  @override
  Future<List<int>> read(MailAttachment a) async => utf8.encode('%PDF-1.7 ${a.object}');
}

class _NoKeys implements SigningKeys {
  @override
  Future<Map<String, RSAPublicKey>> current({bool unknownKeyId = false}) async =>
      const <String, RSAPublicKey>{};
}

class _Never implements RevocationCheck {
  @override
  Future<void> check(VerifiedUser user) async {}
}

class _Owner extends http.BaseClient {
  final http.Client _inner = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['authorization'] = 'Bearer owner';
    return _inner.send(request);
  }
}
