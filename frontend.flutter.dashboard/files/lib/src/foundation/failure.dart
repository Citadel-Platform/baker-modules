import 'dart:async';

/// A failure the application knows how to explain.
///
/// Anything that reaches a screen goes through [describeFailure]. An
/// exception's `toString()` is written for a developer reading a log — class
/// names, stack fragments, sometimes a URL with a token in it — and never for
/// the person using the app.
abstract class AppFailure implements Exception {
  const AppFailure();

  /// One sentence, for the person using the app.
  String get message;

  /// Whether trying again could work. Drives whether a Retry button is shown.
  bool get retryable => false;
}

/// The thing asked for is not set up in this build — no backend connected,
/// no sign-in configured. Different from "empty" and from "failed", and shown
/// differently: nothing is wrong, something is missing.
class NotConfigured extends AppFailure {
  const NotConfigured(this.what);

  /// What is not set up, as a noun phrase: "a database".
  final String what;

  @override
  String get message => 'This app has no $what connected yet.';
}

/// The signed-in person may not do this.
class NotPermitted extends AppFailure {
  const NotPermitted([this.action = 'do this']);
  final String action;

  @override
  String get message => 'Your account is not allowed to $action.';
}

/// The network or a service did not answer. Worth trying again.
class Unavailable extends AppFailure {
  const Unavailable([this.what = 'The service']);
  final String what;

  @override
  String get message => '$what did not respond. Try again in a moment.';

  @override
  bool get retryable => true;
}

/// Input the app refused, with the reason in the person's terms.
class Invalid extends AppFailure {
  const Invalid(this.message);

  @override
  final String message;
}

/// A sentence for any error, safe to put on a screen.
///
/// Known failures explain themselves. A timeout reads as unavailable. Anything
/// else is described generically — its details belong in the log, which
/// [describeFailure] never replaces.
String describeFailure(Object error) => switch (error) {
  AppFailure() => error.message,
  TimeoutException() => const Unavailable().message,
  _ => 'Something went wrong. Try again, and if it keeps happening, report it.',
};

/// Whether a Retry control makes sense for [error].
bool isRetryable(Object error) => switch (error) {
  AppFailure() => error.retryable,
  TimeoutException() => true,
  _ => true,
};
