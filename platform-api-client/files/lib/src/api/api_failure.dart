/// Why a call did not produce an answer, in a sentence somebody can act on.
///
/// The same shape the Citadel console uses, and for the same reason: an
/// exception's `toString` rendered into a user interface is how a client ends
/// up reading a stack frame. Every failure surface in a generated application
/// goes through this.
class ApiFailure implements Exception {
  const ApiFailure({
    required this.title,
    required this.message,
    this.remedy,
    this.retryable = false,
  });

  /// What went wrong, as a short noun phrase. Not how.
  final String title;

  /// One line: the state of the world, in the reader's vocabulary.
  final String message;

  /// What to do about it, imperative. Null when there is nothing to do but
  /// retry, which [retryable] already says.
  final String? remedy;

  final bool retryable;

  /// The failure for a build that was never told where the platform is.
  static const ApiFailure notConfigured = ApiFailure(
    title: 'No platform address',
    message:
        'This build was compiled without the address of the Citadel Platform '
        'API, so it has nowhere to send anything.',
    remedy:
        'Rebuild with --dart-define=CITADEL_PLATFORM_API_BASE_URL=<address>.',
  );

  @override
  String toString() => '$title: $message';
}
