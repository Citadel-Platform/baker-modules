import 'package:googleapis/firestore/v1.dart' as fs;
import 'package:shelf/shelf.dart';

import '../api.dart';
import '../routes/app_routes.dart';
import 'mail_service.dart';

/// Mail's routes; added to `appRoutes` when the application is bootstrapped.
///
/// The service is made on first use, from [context]'s settings, so building
/// the route table (as the contract test does) needs no database or keys.
/// [adminRole] may see the outbox and suppressions, retry a failed message,
/// and lift a suppression.
List<ApiRoute> mailRoutes(
  AppContext context, {
  String adminRole = 'admin',
  MailService Function()? service,
}) {
  MailService? made;
  MailService mail() => made ??= (service ?? () => MailService.from(context))();
  return _routes(mail, context, adminRole);
}

List<ApiRoute> _routes(
  MailService Function() mail,
  AppContext context,
  String adminRole,
) => <ApiRoute>[
  ApiRoute(
    'POST',
    '/internal/mail/send',
    (ApiCall call) async {
      final JsonBody body = await JsonBody.read(call.request);
      final String id = body.string('id', maxLength: 64);
      body.check();
      return json(<String, Object?>{'state': (await mail().send(id)).name});
    },
    access: ApiAccess.service(context.internalCaller),
    summary: 'Sends one queued message. Called by Cloud Tasks.',
  ),
  ApiRoute(
    'POST',
    '/internal/mail/sweep',
    (_) async {
      final ({int dispatched, int purged}) did = await mail().sweep();
      return json(<String, Object?>{'dispatched': did.dispatched, 'purged': did.purged});
    },
    access: ApiAccess.service(context.internalCaller),
    summary: 'Dispatches stranded messages and removes old bodies. Called by Cloud Scheduler.',
  ),
  ApiRoute(
    'POST',
    '/webhooks/mail',
    (ApiCall call) async {
      final List<int> raw = await call.request.read().fold(
        <int>[],
        (List<int> a, List<int> b) => a..addAll(b),
      );
      final String? problem = await mail().event(raw, call.request.headers);
      if (problem != null) {
        // The provider retries a refused delivery; a forged one gets nothing.
        throw const Problem(401, 'bad_signature', 'Signature not accepted');
      }
      return Response(204);
    },
    access: const ApiAccess.public(),
    summary: 'Delivery events from Resend, signed with Svix.',
  ),
  ApiRoute(
    'GET',
    '/v1/mail/outbox',
    (ApiCall call) async {
      final String state = call.request.url.queryParameters['state'] ?? 'failed';
      if (!MailState.values.any((MailState s) => s.name == state)) {
        throw Problem.invalid('state is one of ${MailState.values.map((MailState s) => s.name).join(', ')}');
      }
      final List<({String id, Map<String, Object?> data})> rows = await context.db.query(
        MailService.outbox,
        equals: <String, Object?>{'state': state},
        limit: 100,
      );
      // What happened to each message, never what it said.
      return json(<String, Object?>{
        'messages': <Object?>[
          for (final ({String id, Map<String, Object?> data}) r in rows)
            <String, Object?>{
              'id': r.id,
              'to': r.data['to'],
              'subject': r.data['subject'],
              'reference': r.data['reference'],
              'state': r.data['state'],
              'attempts': r.data['attempts'],
              'lastError': r.data['lastError'],
              'createdAt': (r.data['createdAt'] as DateTime?)?.toIso8601String(),
            },
        ],
      });
    },
    access: ApiAccess.roles(<String>{adminRole}),
    summary: 'Messages in one state, newest problems first.',
  ),
  ApiRoute(
    'POST',
    '/v1/mail/outbox/<id>/retry',
    (ApiCall call) async {
      await mail().retry(call.parameters['id']!);
      return Response(202);
    },
    access: ApiAccess.roles(<String>{adminRole}),
    summary: 'Queues a failed message again.',
  ),
  ApiRoute(
    'GET',
    '/v1/mail/suppressions',
    (_) async {
      final List<({String id, Map<String, Object?> data})> rows = await context.db.query(
        MailService.suppressions,
        limit: 500,
      );
      return json(<String, Object?>{
        'suppressions': <Object?>[
          for (final ({String id, Map<String, Object?> data}) r in rows)
            <String, Object?>{
              'id': r.id,
              'address': r.data['address'],
              'reason': r.data['reason'],
              'at': (r.data['at'] as DateTime?)?.toIso8601String(),
            },
        ],
      });
    },
    access: ApiAccess.roles(<String>{adminRole}),
    summary: 'Addresses mail is no longer sent to, and why.',
  ),
  ApiRoute(
    'DELETE',
    '/v1/mail/suppressions/<id>',
    (ApiCall call) async {
      await context.db.commit(<fs.Write>[
        context.db.delete('${MailService.suppressions}/${call.parameters['id']}'),
      ]);
      return Response(204);
    },
    access: ApiAccess.roles(<String>{adminRole}),
    summary: 'Lifts a suppression, for an address that works again.',
  ),
];
