import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../../firebase_options.dart';
import 'stored_session_stub.dart'
    if (dart.library.js_interop) 'stored_session_web.dart';

/// Whether to talk to the local Firebase emulators instead of the project.
///
/// A compile-time switch, `--dart-define=USE_FIREBASE_EMULATORS=true`, so a
/// release build cannot be pointed at a laptop by a setting.
const bool useFirebaseEmulators = bool.fromEnvironment(
  'USE_FIREBASE_EMULATORS',
);

/// Where the emulators are. `10.0.2.2` from an Android emulator.
const String firebaseEmulatorHost = String.fromEnvironment(
  'FIREBASE_EMULATOR_HOST',
  defaultValue: 'localhost',
);

/// Starts Firebase once, or returns null when this build has no project.
///
/// `flutterfire configure` has not run, or has not been run for this
/// platform, when the options throw [UnsupportedError]. That is "not
/// configured", not a crash: the app still starts and says so.
Future<FirebaseApp?> startFirebase() async {
  if (Firebase.apps.isNotEmpty) return Firebase.app();
  final FirebaseOptions options;
  try {
    options = DefaultFirebaseOptions.currentPlatform;
  } on UnsupportedError catch (error) {
    debugPrint('Firebase not configured: ${error.message}');
    return null;
  }
  if (useFirebaseEmulators && kIsWeb && !_pluginReconnectsEmulator) {
    // On the web, FlutterFire starts Auth inside initializeApp and restores
    // the stored session there, a network call made before this app can
    // connect the emulator. The call goes to production, and the emulator
    // connection made afterwards is refused silently. Forgetting the stored
    // session means nothing is sent before the emulator is connected. A
    // reload signs you out in this mode, which costs an emulator account
    // nothing.
    await forgetStoredFirebaseSession();
  }
  return Firebase.initializeApp(options: options);
}

/// FlutterFire reconnects the emulator itself, before restoring the session,
/// only on `localhost` in a debug build.
bool get _pluginReconnectsEmulator =>
    Uri.base.host == 'localhost' && kDebugMode;
