import 'dart:convert';

import 'package:http/http.dart' as http;

/// An HTTP client whose calls carry a token for particular OAuth scopes,
/// from the metadata server Cloud Run provides.
///
/// Needed for APIs outside `cloud-platform`, such as Sheets: the default
/// token (what `googleapis_auth` fetches on Cloud Run, which does not pass
/// scopes) is refused by them. The metadata server issues a token for the
/// scopes asked for in `?scopes=`. Tokens are reused until a minute before
/// they expire.
class ScopedMetadataClient extends http.BaseClient {
  ScopedMetadataClient(
    this._inner, {
    required this.scopes,
    Uri? metadata,
    DateTime Function()? clock,
  }) : _metadata =
           metadata ??
           Uri.parse(
             'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token',
           ),
       _clock = clock ?? DateTime.now;

  final http.Client _inner;
  final List<String> scopes;
  final Uri _metadata;
  final DateTime Function() _clock;
  String? _token;
  DateTime _expires = DateTime.fromMillisecondsSinceEpoch(0);

  Future<String> _current() async {
    if (_token != null && _clock().isBefore(_expires)) return _token!;
    final http.Response r = await _inner.get(
      _metadata.replace(
        queryParameters: <String, String>{'scopes': scopes.join(',')},
      ),
      headers: <String, String>{'Metadata-Flavor': 'Google'},
    );
    if (r.statusCode != 200) {
      throw StateError(
        'The metadata server answered ${r.statusCode} for a scoped token.',
      );
    }
    final Map<String, Object?> body =
        jsonDecode(r.body) as Map<String, Object?>;
    _token = body['access_token']! as String;
    final int life = (body['expires_in'] as int?) ?? 300;
    _expires = _clock().add(Duration(seconds: life - 60));
    return _token!;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    request.headers['authorization'] = 'Bearer ${await _current()}';
    return _inner.send(request);
  }
}
