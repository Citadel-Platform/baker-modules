import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/misc.dart';

import '../access/session.dart';
import '../firebase/firebase_setup.dart';
import 'firebase_session.dart';
import 'firebase_sign_in.dart';

/// Connects Firebase sign-in. Returned from `configure()` in
/// `lib/src/configure.dart`.
///
/// With no Firebase project configured this connects nothing, and the app
/// keeps saying "No sign-in connected" — true, and more useful than a
/// sign-in button that cannot work.
Future<List<Override>> firebaseAuthOverrides() async {
  final FirebaseApp? app = await startFirebase();
  if (app == null) return const <Override>[];
  final FirebaseAuth auth = FirebaseAuth.instanceFor(app: app);
  if (useFirebaseEmulators) {
    await auth.useAuthEmulator(firebaseEmulatorHost, 9099);
  }
  return <Override>[
    sessionProvider.overrideWith((_) => firebaseSessions(auth)),
    signInActionsProvider.overrideWithValue(FirebaseSignIn(auth)),
  ];
}
