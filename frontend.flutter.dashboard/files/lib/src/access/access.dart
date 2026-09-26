import 'session.dart';

/// Who may open a route. Every route states one; there is no default.
///
/// Checked here for the screens only. The same rule must be enforced where the
/// data is — Firestore rules, the API — because anything the app decides, a
/// person with the app's code can decide differently. This guard is what keeps
/// honest users on the right screens, not what keeps data safe.
sealed class Access {
  const Access();

  /// Anybody, signed in or not. Kept to sign-in and error pages.
  const factory Access.public() = PublicAccess;

  /// Any signed-in person.
  const factory Access.signedIn() = SignedInAccess;

  /// A signed-in person holding at least one of [roles].
  const factory Access.roles(Set<String> roles) = RoleAccess;
}

final class PublicAccess extends Access {
  const PublicAccess();
}

final class SignedInAccess extends Access {
  const SignedInAccess();
}

final class RoleAccess extends Access {
  const RoleAccess(this.roles);

  /// An empty set admits nobody, which fails safe.
  final Set<String> roles;
}

/// What the guard does with a request for a route.
enum AccessDecision {
  allow,

  /// Not signed in: go to sign-in, and come back after.
  signIn,

  /// Signed in without the role.
  forbidden,

  /// The route needs a signed-in person and this build has no sign-in.
  noSignIn,

  /// The session is not known yet. Wait; never guess.
  pending,
}

/// Decides [access] for [session]. Null [session] means still loading.
AccessDecision decideAccess(Access access, Session? session) {
  if (access is PublicAccess) return AccessDecision.allow;
  return switch (session) {
    null => AccessDecision.pending,
    NoSignIn() => AccessDecision.noSignIn,
    SignedOut() => AccessDecision.signIn,
    SignedIn(:final Set<String> roles) => switch (access) {
      PublicAccess() || SignedInAccess() => AccessDecision.allow,
      RoleAccess(roles: final Set<String> needed) =>
        needed.any(roles.contains)
            ? AccessDecision.allow
            : AccessDecision.forbidden,
    },
  };
}

/// [from] if it is a path inside this app, else `/`.
///
/// The sign-in page returns people to where they were going, and "where they
/// were going" arrives in the URL, so anybody can write it. Only a local path
/// is followed: `//evil.example` and `https://…` are how a login page becomes
/// somebody else's phishing link.
String safeReturnPath(String? from) {
  if (from == null || from.isEmpty) return '/';
  final Uri? uri = Uri.tryParse(from);
  if (uri == null ||
      uri.hasScheme ||
      uri.hasAuthority ||
      !from.startsWith('/') ||
      from.startsWith('//') ||
      from.contains(r'\')) {
    return '/';
  }
  return from;
}
