import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../foundation/failure.dart';

/// A Firestore error as a sentence, with the raw one kept for the log.
///
/// Codes are Firestore's own. A missing composite index arrives as
/// `failed-precondition` with a console link in the message: that link is for
/// the developer, so it goes to the log, and the screen says the view is not
/// set up yet.
AppFailure firestoreFailure(FirebaseException error) {
  debugPrint('Firestore ${error.code}: ${error.message}');
  return switch (error.code) {
    'permission-denied' || 'unauthenticated' => const NotPermitted('see this'),
    'unavailable' ||
    'deadline-exceeded' ||
    'resource-exhausted' ||
    'aborted' => const Unavailable('The database'),
    'failed-precondition' => const NotConfigured(
      'the database index this view needs',
    ),
    'not-found' => const Invalid('That record no longer exists.'),
    'already-exists' => const Invalid('That record already exists.'),
    _ => const Invalid('The database refused the request. Try again.'),
  };
}

/// A stored document that does not have the shape the app expects.
///
/// Said out loud, naming the document, rather than shown with blanks where the
/// bad fields were: a record half-rendered is a record somebody edits and
/// saves back half-empty.
class InvalidRecord extends AppFailure {
  const InvalidRecord(this.path, this.problem);

  final String path;
  final String problem;

  @override
  String get message => 'A stored record could not be read ($path): $problem';
}
