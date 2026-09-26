// Replaced by `flutterfire configure`, which writes this project's Firebase
// options here. Until then this build has no Firebase project, and says so:
// the app starts, and every page that needs sign-in or data explains that
// nothing is connected rather than failing to start.
//
// ignore_for_file: avoid_classes_with_only_static_members
import 'package:firebase_core/firebase_core.dart';

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform => throw UnsupportedError(
    'No Firebase project is configured. Run flutterfire configure.',
  );
}
