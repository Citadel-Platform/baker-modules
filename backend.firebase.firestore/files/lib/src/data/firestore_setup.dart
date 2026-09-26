import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';

import '../firebase/firebase_setup.dart';
import '../foundation/failure.dart';

/// The database. Until connected, reading it is a [NotConfigured] failure,
/// which every screen shows as "Not set up" rather than as empty.
final Provider<FirebaseFirestore> firestoreProvider =
    Provider<FirebaseFirestore>(
      (Ref ref) => throw const NotConfigured('database'),
    );

/// A named database, `--dart-define=FIRESTORE_DATABASE=<id>`; the project's
/// `(default)` database otherwise.
const String firestoreDatabase = String.fromEnvironment(
  'FIRESTORE_DATABASE',
  defaultValue: '(default)',
);

/// Connects Firestore. Returned from `configure()` in
/// `lib/src/configure.dart`, after the sign-in overrides.
Future<List<Override>> firestoreOverrides() async {
  final FirebaseApp? app = await startFirebase();
  if (app == null) return const <Override>[];
  final FirebaseFirestore db = FirebaseFirestore.instanceFor(
    app: app,
    databaseId: firestoreDatabase,
  );
  if (useFirebaseEmulators) {
    // 8180, not Firestore's default 8080: the API and the web server listen
    // on 8080 locally, as Cloud Run expects, and a shared port refuses one.
    db.useFirestoreEmulator(firebaseEmulatorHost, 8180);
  }
  return <Override>[firestoreProvider.overrideWithValue(db)];
}
