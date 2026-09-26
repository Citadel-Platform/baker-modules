# backend.firebase.auth

Firebase Authentication for a `frontend.flutter.dashboard` application.

## What is in it

- **Firebase start-up** (`lib/src/firebase/firebase_setup.dart`), shared with
  the Firestore module. A stub `lib/firebase_options.dart` lets a fresh tree
  build and run before `flutterfire configure` replaces it; until then the app
  says no sign-in is connected rather than failing to start.
- **Sessions** (`lib/src/auth/firebase_session.dart`) follow the ID token
  (`idTokenChanges`), so new roles reach the screens when the token refreshes
  without signing out. Roles come from the `roles` custom claim; a malformed
  claim grants nothing.
- **Sign-in** (`firebase_sign_in.dart`): Google by popup on the web and by
  provider on mobile. Every Firebase error code maps to a sentence
  (cancelled, blocked pop-up, network, disabled account, provider not
  enabled, domain not authorised); nothing raw reaches the screen.
- **Roles tool** (`tool/set_roles.dart`): shows or sets a person's roles
  through the Identity Toolkit API as the operator's Application Default
  Credentials, never a key file. Dry run unless `--apply`; keeps other
  claims; validates names, count and Firebase's 1000-byte claims limit;
  reads back what it wrote. Talks to the emulator when
  `FIREBASE_AUTH_EMULATOR_HOST` is set, and refuses a `demo-` project
  otherwise.
- **Emulators**: `USE_FIREBASE_EMULATORS=true` at build time points the app at
  them.

## Tested

Unit tests with mocks (session mapping, sign-in errors, claims rules), and
`test_emulator/auth/` against the Auth emulator: lookup, set, keep other
claims, clear, and the command line's dry run, refusal and apply.

**Not yet driven against a real project:** the roles tool with Application
Default Credentials and a quota project. It uses the same REST calls the
emulator test proves, against Google's documented endpoint.

## Why roles are claims

A role stored in a document the app can write is a role anybody can grant
themselves. Claims are signed into the token by Firebase and can only be set
with administrator credentials, and Firestore rules read the same claim.
