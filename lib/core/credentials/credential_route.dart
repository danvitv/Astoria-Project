enum CredentialProtocol {
  openAiChatCompletions,
  openAiResponses,
  anthropic,
  gemini,
  custom,
}

enum CredentialPurpose {
  chat,
  modelDiscovery,
  embeddings,
  imageGeneration,
  memory,
  assistant,
}

/// An exact HTTPS destination, protocol, and purpose (not an origin wildcard).
/// A native route approval still must vet the hostname/path; parsing is not trust.
final class CredentialRoute {
  factory CredentialRoute({
    required String endpoint,
    required CredentialProtocol protocol,
    required CredentialPurpose purpose,
  }) => CredentialRoute.parse(
    endpoint: endpoint,
    protocol: protocol,
    purpose: purpose,
  );

  factory CredentialRoute.parse({
    required String endpoint,
    required CredentialProtocol protocol,
    required CredentialPurpose purpose,
  }) {
    try {
      if (RegExp(r'[\s\\]').hasMatch(endpoint) ||
          endpoint.contains('?') ||
          endpoint.contains('#') ||
          RegExp(r'%(?![a-fA-F0-9]{2})').hasMatch(endpoint)) {
        throw const FormatException();
      }
      // Check the raw path BEFORE Uri.parse can normalize literal dot segments.
      // Decode segments once too, so encoded dots/slashes cannot bypass binding.
      final pathStart = endpoint.indexOf('/', endpoint.indexOf('://') + 3);
      if (pathStart != -1) {
        final path = endpoint.substring(pathStart);
        if (path.contains('//')) throw const FormatException();
        for (final rawSegment in path.split('/').skip(1)) {
          final segment = Uri.decodeComponent(rawSegment);
          if (segment == '.' ||
              segment == '..' ||
              segment.contains('/') ||
              segment.contains('\\')) {
            throw const FormatException();
          }
        }
      }
      final uri = Uri.parse(endpoint);
      if (uri.scheme != 'https' ||
          !uri.hasAuthority ||
          uri.host.isEmpty ||
          uri.port < 1 ||
          uri.port > 65535 ||
          uri.authority.contains('@') ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw const FormatException();
      }
      return CredentialRoute._(uri, protocol, purpose);
    } catch (_) {
      throw const FormatException('Invalid credential route');
    }
  }

  const CredentialRoute._(this.endpoint, this.protocol, this.purpose);

  /// Trusted transport use only; diagnostic projections must sanitize this URL.
  final Uri endpoint;
  final CredentialProtocol protocol;
  final CredentialPurpose purpose;

  @override
  bool operator ==(Object other) =>
      other is CredentialRoute &&
      endpoint == other.endpoint &&
      protocol == other.protocol &&
      purpose == other.purpose;

  @override
  int get hashCode => Object.hash(endpoint, protocol, purpose);

  @override
  String toString() => 'CredentialRoute(${protocol.name}, ${purpose.name})';
}
