import 'package:googleapis/secretmanager/v1.dart' as sm;
import 'package:http/http.dart' as http;

import '../api.dart';
import '../routes/app_routes.dart';
import 'ledger.dart';
import 'token_store.dart';
import 'xero_auth.dart';
import 'xero_ledger.dart';

/// Where the ledger connection stands. Four states, each shown differently.
enum LedgerStatus {
  /// This deployment has no Xero app credentials.
  notConfigured,

  /// Credentials, but nobody has connected an organisation.
  notConnected,

  /// Connected, but Xero did not answer or refused the stored connection.
  unreachable,
  connected,
}

/// The ledger for this deployment: Xero, connected by an administrator.
class LedgerService {
  LedgerService({required this.auth, required this.db, required this.client});

  /// From the API's context:
  ///
  ///   XERO_CLIENT_ID, XERO_CLIENT_SECRET   the Xero app (secrets)
  ///   XERO_TOKEN_SECRET                    `projects/P/secrets/S`, where the
  ///                                        refresh token is kept
  ///   API_URL                              for the OAuth redirect
  ///
  /// Returns null when the Xero app is not configured.
  static LedgerService? from(AppContext context, {http.Client? client}) {
    final String id = context.environment['XERO_CLIENT_ID'] ?? '';
    final String secret = context.environment['XERO_CLIENT_SECRET'] ?? '';
    if (id.isEmpty || secret.isEmpty) return null;
    final http.Client c = client ?? http.Client();
    return LedgerService(
      db: context.db,
      client: c,
      auth: XeroAuth(
        client: c,
        clientId: id,
        clientSecret: secret,
        redirectUri: '${context.setting('API_URL')}/v1/ledger/xero/callback',
        tokens: SecretManagerTokenStore(
          sm.SecretManagerApi(context.googleClient),
          secretName: context.setting('XERO_TOKEN_SECRET'),
        ),
        db: context.db,
      ),
    );
  }

  final XeroAuth auth;
  final AppFirestore db;
  final http.Client client;

  /// The connected ledger, or [LedgerNotConnected].
  Future<Ledger> ledger() async {
    final Map<String, Object?>? c = await db.get(XeroAuth.connection);
    final Object? tenant = c?['tenantId'];
    if (tenant is! String) throw const LedgerNotConnected();
    return XeroLedger(client: client, auth: auth, tenantId: tenant);
  }

  Future<({LedgerStatus status, String? organisation, String? detail})>
  status() async {
    final Map<String, Object?>? c = await db.get(XeroAuth.connection);
    if (c == null) {
      return (
        status: LedgerStatus.notConnected,
        organisation: null,
        detail: null,
      );
    }
    final String? name = c['tenantName'] as String?;
    try {
      await auth.accessToken();
      return (status: LedgerStatus.connected, organisation: name, detail: null);
    } on LedgerNotConnected {
      return (
        status: LedgerStatus.notConnected,
        organisation: name,
        detail: 'Xero no longer accepts the connection; connect again.',
      );
    } on Problem catch (p) {
      return (
        status: LedgerStatus.unreachable,
        organisation: name,
        detail: p.detail,
      );
    }
  }
}
