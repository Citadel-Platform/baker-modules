import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../access/session.dart';
import '../foundation/failure.dart';

/// Sign-in through Firebase Authentication.
///
/// Google only, by default: it is the one provider that works without a
/// separate app registration. Add another here once it is enabled in the
/// Firebase console — a button for a provider that is not enabled is a button
/// that always fails.
class FirebaseSignIn implements SignInActions {
  FirebaseSignIn(this._auth);

  final FirebaseAuth _auth;

  @override
  List<SignInOption> get options => <SignInOption>[
    SignInOption(
      label: 'Continue with Google',
      icon: Icons.login,
      signIn: () => _run(GoogleAuthProvider()),
    ),
  ];

  Future<void> _run(AuthProvider provider) async {
    try {
      if (kIsWeb) {
        await _auth.signInWithPopup(provider);
      } else {
        await _auth.signInWithProvider(provider);
      }
    } on FirebaseAuthException catch (error) {
      throw signInFailure(error);
    }
  }

  @override
  Future<void> signOut() => _auth.signOut();
}

/// A Firebase sign-in error as a sentence for the person signing in.
///
/// The codes are Firebase's; anything unrecognised is described generically
/// and left in the log, never shown raw.
AppFailure signInFailure(FirebaseAuthException error) => switch (error.code) {
  'popup-closed-by-user' ||
  'cancelled-popup-request' ||
  'web-context-canceled' ||
  'canceled' => const Invalid('Sign-in was cancelled.'),
  'popup-blocked' => const Invalid(
    'The browser blocked the sign-in window. Allow pop-ups for this site.',
  ),
  'network-request-failed' => const Unavailable('Sign-in'),
  'too-many-requests' => const Unavailable('Sign-in'),
  'user-disabled' => const NotPermitted('sign in; this account is disabled'),
  'operation-not-allowed' => const NotConfigured('Google sign-in enabled'),
  'unauthorized-domain' => const NotConfigured(
    'this web address among its authorised sign-in domains',
  ),
  _ => const Invalid('Sign-in did not complete. Try again.'),
};
