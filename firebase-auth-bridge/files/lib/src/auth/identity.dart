/// Who the application is acting as.
///
/// A bootstrap cannot know which sign-in a client will use, so this is the
/// seam rather than the implementation: it names the states an application has
/// to render — nobody signed in, somebody signed in, and no sign-in configured
/// at all — and leaves choosing a provider to the person who knows which one
/// the client has.
///
/// The third state is the one usually left out, and it is the one a fresh
/// build is in. Rendering "signed out" for an application that has no sign-in
/// wired sends somebody looking for a login screen that does not exist.
sealed class Identity {
  const Identity();

  /// What this build has. Unconfigured until a provider is wired in.
  static Identity current() => const UnconfiguredIdentity();

  String describe();
}

/// No sign-in has been connected to this application.
final class UnconfiguredIdentity extends Identity {
  const UnconfiguredIdentity();

  @override
  String describe() =>
      'No sign-in is connected to this build, so it is not signed out — it '
      'has nowhere to sign in to.';
}

/// A sign-in exists and nobody is using it.
final class SignedOutIdentity extends Identity {
  const SignedOutIdentity();

  @override
  String describe() => 'Signed out.';
}

/// Somebody is signed in.
final class SignedInIdentity extends Identity {
  const SignedInIdentity({required this.subject, required this.email});

  /// The provider's own stable id. What authorisation is decided on — never
  /// the address, which people change.
  final String subject;
  final String email;

  @override
  String describe() => email.isEmpty ? subject : email;
}
