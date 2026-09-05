/// What the application reports about itself.
///
/// The seam, not a transport. A bootstrap should not decide that a client's
/// first application starts sending telemetry somewhere — that is a decision
/// with a privacy answer attached — so the default records nothing and says
/// so, and wiring Conduit in is a deliberate later act.
abstract interface class Capture {
  /// Something happened that is worth counting. Never a message body, never a
  /// customer's data: an event is a name and a small number of dimensions.
  void event(String name, {Map<String, String> attributes});

  /// Something failed. The failure, not the data it was working on.
  void failure(String name, {String? detail});
}

/// The default: nothing is captured, and nothing pretends to be.
///
/// Deliberately not a silent no-op that looks like a working pipeline. An
/// application whose telemetry is switched off and one whose telemetry is
/// broken look the same from inside; [isRecording] is how a settings screen
/// can say which.
final class NoCapture implements Capture {
  const NoCapture();

  bool get isRecording => false;

  @override
  void event(String name, {Map<String, String> attributes = const <String, String>{}}) {}

  @override
  void failure(String name, {String? detail}) {}
}
