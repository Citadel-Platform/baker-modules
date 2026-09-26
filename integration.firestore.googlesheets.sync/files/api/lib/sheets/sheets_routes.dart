import 'package:shelf/shelf.dart';

import '../api.dart';
import '../routes/app_routes.dart';
import 'sheets_config.dart';
import 'sheets_sync.dart';

/// Sheets sync's routes; added to `appRoutes` when the application is
/// bootstrapped. The service is made on first use, from [context].
List<ApiRoute> sheetsRoutes(
  AppContext context, {
  List<SheetMapping> mappings = sheetMappings,
  SheetsSync Function()? service,
}) {
  SheetsSync? made;
  SheetsSync sync() =>
      made ??= (service ?? () => SheetsSync.from(context, mappings))();
  return <ApiRoute>[
    ApiRoute(
      'POST',
      '/internal/sheets/changed',
      (ApiCall call) async {
        // Eventarc delivers Firestore events as protobuf. The document is
        // named in the CloudEvent's subject header, `documents/<path>`,
        // which is all the sync needs: it reads the document itself.
        final String subject = call.request.headers['ce-subject'] ?? '';
        if (!subject.startsWith('documents/')) {
          throw Problem.invalid('Not a Firestore document event.');
        }
        final bool queued = await sync().changed(
          subject.substring('documents/'.length),
        );
        return json(<String, Object?>{'queued': queued});
      },
      access: ApiAccess.service(context.internalCaller),
      summary:
          'A document changed. Called by the Firestore trigger (Eventarc).',
    ),
    ApiRoute(
      'POST',
      '/internal/sheets/sync',
      (ApiCall call) async {
        final JsonBody body = await JsonBody.read(call.request);
        final String path = body.string('path', maxLength: 1500);
        body.check();
        await sync().sync(path);
        return Response(204);
      },
      access: ApiAccess.service(context.internalCaller),
      summary: 'Writes one document to its row. Called by Cloud Tasks.',
    ),
    ApiRoute(
      'POST',
      '/internal/sheets/reconcile',
      (_) async => json(await sync().reconcile()),
      access: ApiAccess.service(context.internalCaller),
      summary:
          'Repairs drift between collections and tabs. Called nightly by Cloud Scheduler.',
    ),
    ApiRoute(
      'POST',
      '/webhooks/sheets',
      (ApiCall call) async {
        final List<int> raw = await call.request.read().fold(
          <int>[],
          (List<int> a, List<int> b) => a..addAll(b),
        );
        return json(await sync().edit(raw, call.request.headers));
      },
      access: const ApiAccess.public(),
      summary: 'Edits made in a synced sheet, signed by its Apps Script.',
    ),
  ];
}
