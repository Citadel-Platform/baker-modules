import 'package:firebase_auth/firebase_auth.dart';

import '../access/session.dart';

/// The claim a person's roles are read from. Set only by a server
/// (`tool/set_roles.dart`), checked by the same name in `firestore.rules`.
const String rolesClaim = 'roles';

/// The session, following Firebase's ID token rather than just sign-in state.
///
/// `idTokenChanges`, not `authStateChanges`: roles live in the token, and a
/// refreshed token with new claims must reach the screens without the person
/// signing out and back in.
Stream<Session> firebaseSessions(FirebaseAuth auth) =>
    auth.idTokenChanges().asyncMap(sessionFor);

/// The session for [user], with roles from its token's claims.
Future<Session> sessionFor(User? user) async {
  if (user == null) return const SignedOut();
  final IdTokenResult token = await user.getIdTokenResult();
  return SignedIn(
    uid: user.uid,
    email: user.email ?? '',
    displayName: user.displayName ?? '',
    roles: rolesFromClaims(token.claims),
  );
}

/// The roles in [claims]: strings only, anything else ignored.
///
/// A malformed claim grants nothing rather than failing sign-in: a person
/// with a bad claim can still reach pages that need no role, and the
/// operator can see and fix it with `set_roles.dart`.
Set<String> rolesFromClaims(Map<String, dynamic>? claims) {
  final Object? value = claims?[rolesClaim];
  if (value is! List) return const <String>{};
  return <String>{
    for (final Object? role in value)
      if (role is String && role.isNotEmpty) role,
  };
}
