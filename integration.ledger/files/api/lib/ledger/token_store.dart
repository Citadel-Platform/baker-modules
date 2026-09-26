import 'dart:convert';

import 'package:googleapis/secretmanager/v1.dart' as sm;

/// Where the ledger's refresh token lives between requests.
abstract interface class TokenStore {
  Future<String?> read();

  /// Stores [token] as the only valid one; older values are destroyed.
  Future<void> write(String token);

  /// Forgets it entirely (on disconnect).
  Future<void> clear();
}

/// In Secret Manager, one secret whose latest version is the token.
///
/// A refresh token is a credential to the client's books, so it is kept
/// where credentials are kept, readable only by the application's identity,
/// and never in Firestore or a log. Xero rotates it on every refresh; each
/// new one is a new version, and the versions before it are destroyed, since
/// they no longer work anyway.
class SecretManagerTokenStore implements TokenStore {
  SecretManagerTokenStore(this.api, {required this.secretName});

  final sm.SecretManagerApi api;

  /// `projects/P/secrets/S`.
  final String secretName;

  @override
  Future<String?> read() async {
    try {
      final sm.AccessSecretVersionResponse r = await api
          .projects
          .secrets
          .versions
          .access('$secretName/versions/latest');
      final String? data = r.payload?.data;
      if (data == null) return null;
      final String token = utf8.decode(base64.decode(data));
      return token.isEmpty ? null : token;
    } on sm.DetailedApiRequestError catch (e) {
      // No version yet, or the latest was destroyed on disconnect.
      if (e.status == 404 || e.status == 400 || e.status == 412) return null;
      rethrow;
    }
  }

  @override
  Future<void> write(String token) async {
    final sm.SecretVersion added = await api.projects.secrets.addVersion(
      sm.AddSecretVersionRequest(
        payload: sm.SecretPayload(data: base64.encode(utf8.encode(token))),
      ),
      secretName,
    );
    await _destroyAllBut(added.name);
  }

  @override
  Future<void> clear() => _destroyAllBut(null);

  Future<void> _destroyAllBut(String? keep) async {
    String? page;
    do {
      final sm.ListSecretVersionsResponse r = await api
          .projects
          .secrets
          .versions
          .list(secretName, filter: 'state:ENABLED', pageToken: page);
      for (final sm.SecretVersion v
          in r.versions ?? const <sm.SecretVersion>[]) {
        if (v.name != keep) {
          await api.projects.secrets.versions.destroy(
            sm.DestroySecretVersionRequest(),
            v.name!,
          );
        }
      }
      page = r.nextPageToken;
    } while (page != null && page.isNotEmpty);
  }
}

class MemoryTokenStore implements TokenStore {
  String? token;
  int writes = 0;
  @override
  Future<String?> read() async => token;
  @override
  Future<void> write(String t) async {
    token = t;
    writes++;
  }

  @override
  Future<void> clear() async => token = null;
}
