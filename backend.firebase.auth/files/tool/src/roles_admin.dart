import 'dart:convert';

import 'package:http/http.dart' as http;

/// Reads and sets a person's roles: the `roles` custom claim on their
/// Firebase account.
///
/// Through the Identity Toolkit REST API, which is what the Admin SDKs call.
/// Custom claims can only be set with administrator credentials, which is the
/// point: a role the app could write for itself would not be a role.
///
/// Only `roles` is changed. Custom claims are replaced as a whole object, so
/// other claims are read first and written back untouched.
class RolesAdmin {
  RolesAdmin(this._client, {required this.projectId, Uri? endpoint})
    : endpoint =
          endpoint ?? Uri.parse('https://identitytoolkit.googleapis.com/v1/');

  final http.Client _client;
  final String projectId;

  /// The API base, ending in `/v1/`. The emulator's is
  /// `http://<host>/identitytoolkit.googleapis.com/v1/`.
  final Uri endpoint;

  static const String claim = 'roles';
  static const int maxRoles = 20;

  /// Firebase's limit on the serialised custom claims.
  static const int maxClaimsBytes = 1000;
  static final RegExp rolePattern = RegExp(r'^[a-z][a-z0-9_-]{0,31}$');

  /// The account for [email] or [uid], or null when there is none.
  Future<Account?> find({String? email, String? uid}) async {
    if ((email == null) == (uid == null)) {
      throw ArgumentError('Give exactly one of email and uid.');
    }
    final Map<String, Object?> body = await _post(
      'accounts:lookup',
      <String, Object?>{
        if (email != null) 'email': <String>[email],
        if (uid != null) 'localId': <String>[uid],
      },
    );
    final Object? users = body['users'];
    if (users is! List || users.isEmpty) return null;
    return Account.fromJson(users.first as Map<String, Object?>);
  }

  /// Sets [account]'s roles to [roles], keeping every other claim.
  Future<void> setRoles(Account account, Set<String> roles) async {
    final Map<String, Object?> claims = claimsWith(account.claims, roles);
    await _post('accounts:update', <String, Object?>{
      'localId': account.uid,
      'customAttributes': jsonEncode(claims),
    });
  }

  /// [claims] with `roles` replaced by [roles], validated.
  static Map<String, Object?> claimsWith(
    Map<String, Object?> claims,
    Set<String> roles,
  ) {
    final List<String> bad = <String>[
      for (final String r in roles)
        if (!rolePattern.hasMatch(r)) r,
    ];
    if (bad.isNotEmpty) {
      throw FormatException(
        'Not a role name: ${bad.join(', ')}. Use lower case letters, digits, '
        '_ and -, starting with a letter.',
      );
    }
    if (roles.length > maxRoles) {
      throw FormatException('At most $maxRoles roles; ${roles.length} given.');
    }
    final Map<String, Object?> next = <String, Object?>{...claims}
      ..remove(claim);
    if (roles.isNotEmpty) next[claim] = (roles.toList()..sort());
    if (utf8.encode(jsonEncode(next)).length > maxClaimsBytes) {
      throw const FormatException(
        'The claims would exceed Firebase\'s 1000-byte limit.',
      );
    }
    return next;
  }

  Future<Map<String, Object?>> _post(
    String method,
    Map<String, Object?> body,
  ) async {
    final Uri uri = endpoint.resolve('projects/$projectId/$method');
    final http.Response response = await _client.post(
      uri,
      headers: <String, String>{'content-type': 'application/json'},
      body: jsonEncode(body),
    );
    final Object? decoded = response.body.isEmpty
        ? <String, Object?>{}
        : jsonDecode(response.body);
    if (response.statusCode != 200) {
      final Object? error = decoded is Map ? decoded['error'] : null;
      final Object? message = error is Map ? error['message'] : null;
      throw RolesAdminException(
        response.statusCode,
        '${message ?? response.reasonPhrase ?? 'request failed'}',
      );
    }
    return decoded is Map<String, Object?> ? decoded : <String, Object?>{};
  }
}

/// A Firebase account as far as roles are concerned.
class Account {
  const Account({
    required this.uid,
    required this.email,
    required this.claims,
    required this.disabled,
  });

  factory Account.fromJson(Map<String, Object?> json) {
    final Object? raw = json['customAttributes'];
    Map<String, Object?> claims = <String, Object?>{};
    if (raw is String && raw.isNotEmpty) {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) claims = decoded;
    }
    return Account(
      uid: '${json['localId']}',
      email: '${json['email'] ?? ''}',
      claims: claims,
      disabled: json['disabled'] == true,
    );
  }

  final String uid;
  final String email;
  final Map<String, Object?> claims;
  final bool disabled;

  Set<String> get roles {
    final Object? value = claims[RolesAdmin.claim];
    return value is List
        ? <String>{
            for (final Object? r in value)
              if (r is String) r,
          }
        : const <String>{};
  }
}

class RolesAdminException implements Exception {
  const RolesAdminException(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => 'Identity Toolkit answered $status: $message';
}
