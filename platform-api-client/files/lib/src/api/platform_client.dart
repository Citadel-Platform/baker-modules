import 'api_failure.dart';

/// Where this application talks to Citadel.
///
/// The address is a compile-time value rather than a runtime setting, because
/// a client application that could be pointed at a different platform by
/// editing a preference is one that can be pointed at somebody else's.
///
/// An unset address is a first-class state, not an error to be discovered on
/// the first call. A build with nothing configured and a build whose platform
/// is unreachable look identical from a failed request, and only one of them
/// is anybody's fault — so this says which before a request is made.
class PlatformClient {
  const PlatformClient({required this.baseUri});

  const PlatformClient._unconfigured() : baseUri = null;

  /// The address this build was compiled with, or an unconfigured client.
  factory PlatformClient.fromEnvironment() {
    const String address = String.fromEnvironment(
      'CITADEL_PLATFORM_API_BASE_URL',
    );
    if (address.isEmpty) return const PlatformClient._unconfigured();
    final Uri? parsed = Uri.tryParse(address);
    if (parsed == null || !parsed.hasScheme || !parsed.hasAuthority) {
      return const PlatformClient._unconfigured();
    }
    return PlatformClient(baseUri: parsed);
  }

  final Uri? baseUri;

  bool get isConfigured => baseUri != null;

  /// The address for a platform route, or a refusal saying why there is none.
  Uri resolve(String path) {
    final Uri? base = baseUri;
    if (base == null) throw ApiFailure.notConfigured;
    return base.resolve(path.startsWith('/') ? path.substring(1) : path);
  }
}
