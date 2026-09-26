import 'dart:convert';

import 'package:api/api.dart';
import 'package:api/mail/mail_message.dart';
import 'package:api/mail/mail_transport.dart';
import 'package:api/mail/svix.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('MailMessage', () {
    test('refuses what cannot be sent, naming each problem', () {
      expect(
        () => MailMessage(to: <String>[], subject: '', text: ''),
        throwsA(isA<Problem>().having((Problem p) => p.detail, 'detail',
            allOf(contains('no recipient'), contains('no subject'), contains('no text')))),
      );
      expect(
        () => MailMessage(to: <String>['a@b.co'], subject: 'Hi\r\nBcc: x@y.z', text: 't'),
        throwsA(isA<Problem>().having((Problem p) => p.detail, 'detail', contains('line break'))),
      );
      expect(
        () => MailMessage(to: <String>['not an address'], subject: 's', text: 't'),
        throwsA(isA<Problem>()),
      );
      expect(
        () => MailMessage(to: List<String>.filled(51, 'a@b.co'), subject: 's', text: 't'),
        throwsA(isA<Problem>()),
      );
    });

    test('attachments: allowed types only, names without paths', () {
      expect(
        () => MailAttachment(bucket: 'b', object: 'o', filename: 'x.exe', contentType: 'application/x-msdownload'),
        throwsA(isA<Problem>()),
      );
      expect(
        () => MailAttachment(bucket: 'b', object: 'o', filename: '../x.pdf', contentType: 'application/pdf'),
        throwsA(isA<Problem>()),
      );
    });

    test('round-trips through its stored form', () {
      final MailMessage m = MailMessage(
        to: <String>['a@b.co'],
        subject: 's',
        text: 't',
        html: '<p>t</p>',
        attachments: <MailAttachment>[
          MailAttachment(bucket: 'b', object: 'o/1.pdf', filename: '1.pdf', contentType: 'application/pdf'),
        ],
        reference: 'invoices/1',
      );
      final MailMessage back = MailMessage.fromFields(m.toFields());
      expect(back.toFields(), m.toFields());
    });

    test('escapeHtml leaves nothing that could run', () {
      expect(escapeHtml('<script>"x" & \'y\'</script>'),
          '&lt;script&gt;&quot;x&quot; &amp; &#39;y&#39;&lt;/script&gt;');
    });
  });

  group('Svix signatures', () {
    // Svix's own published example, so the check is against their
    // arithmetic, not a copy of ours.
    const String secret = 'whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw';
    const String id = 'msg_p5jXN8AQM9LWM0D4loKWxJek';
    const String timestamp = '1614265330';
    final List<int> body = utf8.encode('{"test": 2432232314}');
    const String signature = 'v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=';
    final DateTime then = DateTime.fromMillisecondsSinceEpoch(1614265330 * 1000, isUtc: true);

    String? check({
      List<int>? raw,
      String? sig = signature,
      List<String> secrets = const <String>[secret],
      DateTime? now,
    }) => svixProblem(
      rawBody: raw ?? body,
      id: id,
      timestamp: timestamp,
      signatures: sig,
      secrets: secrets,
      now: now ?? then,
    );

    test('the published example verifies', () => expect(check(), isNull));
    test('a changed body does not', () {
      expect(check(raw: utf8.encode('{"test":2432232314}')), isNotNull);
    });
    test('another secret does not; one of several (a rotation) does', () {
      expect(check(secrets: <String>['whsec_c2VjcmV0']), isNotNull);
      expect(check(secrets: <String>['whsec_c2VjcmV0', secret]), isNull);
    });
    test('a matching signature among several passes', () {
      expect(check(sig: 'v1,AAAA $signature'), isNull);
    });
    test('outside five minutes is refused, a replay window', () {
      expect(check(now: then.add(const Duration(minutes: 6))), contains('window'));
    });
    test('missing headers are refused', () => expect(check(sig: null), contains('missing')));
  });

  group('ResendTransport', () {
    final MailMessage message = MailMessage(to: <String>['a@b.co'], subject: 's', text: 't');

    Future<(SendOutcome, http.Request?)> send(http.Response answer) async {
      http.Request? seen;
      final ResendTransport t = ResendTransport(
        MockClient((http.Request r) async {
          seen = r;
          return answer;
        }),
        apiKey: 're_test',
      );
      return (await t.send(message, from: 'A <no-reply@a.co>', idempotencyKey: 'mail-1'), seen);
    }

    test('sends what Resend documents, with the idempotency key', () async {
      final (SendOutcome o, http.Request? r) = await send(http.Response('{"id":"e1"}', 200));
      expect((o as Sent).providerId, 'e1');
      expect(r!.url.toString(), 'https://api.resend.com/emails');
      expect(r.headers['idempotency-key'], 'mail-1');
      expect(r.headers['authorization'], 'Bearer re_test');
      final Map<String, Object?> body = jsonDecode(r.body) as Map<String, Object?>;
      expect(body['to'], <String>['a@b.co']);
      expect(body['from'], 'A <no-reply@a.co>');
    });

    test('rate limits, outages and a concurrent attempt are worth retrying', () async {
      for (final http.Response r in <http.Response>[
        http.Response('{"name":"rate_limit_exceeded"}', 429),
        http.Response('', 503),
        http.Response('{"name":"concurrent_idempotent_requests"}', 409),
      ]) {
        expect((await send(r)).$1, isA<TryLater>(), reason: '${r.statusCode}');
      }
    });

    test('a refusal is final, with the provider\'s reason', () async {
      final (SendOutcome o, _) = await send(
        http.Response('{"name":"validation_error","message":"The a.co domain is not verified."}', 403),
      );
      expect((o as Refused).reason, contains('not verified'));
      final (SendOutcome reused, _) = await send(
        http.Response('{"name":"invalid_idempotent_request"}', 409),
      );
      expect(reused, isA<Refused>());
    });

    test('no answer is worth retrying, not a crash', () async {
      final ResendTransport t = ResendTransport(
        MockClient((_) async => throw http.ClientException('reset')),
        apiKey: 'k',
      );
      expect(await t.send(message, from: 'a@a.co', idempotencyKey: 'k'), isA<TryLater>());
    });
  });
}
