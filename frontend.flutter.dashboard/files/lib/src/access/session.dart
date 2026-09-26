import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Who the application is acting for.
///
/// Three states, and the third is the one usually left out: a build with no
/// sign-in connected at all. Showing "signed out" there sends somebody looking
/// for a login screen that does not exist.
sealed class Session {
  const Session();
}

/// No sign-in is connected to this build.
final class NoSignIn extends Session {
  const NoSignIn();
}

final class SignedOut extends Session {
  const SignedOut();
}

final class SignedIn extends Session {
  const SignedIn({
    required this.uid,
    required this.roles,
    this.email = '',
    this.displayName = '',
  });

  /// The provider's stable id: what authorisation is decided on, never the
  /// address, which people change.
  final String uid;
  final String email;
  final String displayName;

  /// From the signed token's claims, set only by a server. Never from a
  /// document the app can read or write, which anybody with the app open can
  /// edit. See `backend.firebase.auth`.
  final Set<String> roles;

  String get label => displayName.isNotEmpty
      ? displayName
      : email.isNotEmpty
      ? email
      : uid;
}

/// The current session. Overridden by a sign-in module; without one, this
/// build has no sign-in and says so.
final StreamProvider<Session> sessionProvider = StreamProvider<Session>(
  (Ref ref) => Stream<Session>.value(const NoSignIn()),
);

/// One way to sign in, as the sign-in page offers it.
class SignInOption {
  const SignInOption({
    required this.label,
    required this.icon,
    required this.signIn,
  });

  final String label;
  final IconData icon;

  /// Completes when signed in; throws an [AppFailure] the page can explain.
  final Future<void> Function() signIn;
}

/// What a sign-in module provides to the screens.
abstract interface class SignInActions {
  List<SignInOption> get options;
  Future<void> signOut();
}

/// Null until a sign-in module is connected.
final Provider<SignInActions?> signInActionsProvider = Provider<SignInActions?>(
  (Ref ref) => null,
);
