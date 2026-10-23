part of 'native_provider_credentials.dart';

/// Native view ownership, not a DTO toggle or assistant permission flag.
final class NativeProviderViewLifetime {
  NativeProviderViewLifetime({required this._isCurrent});
  final bool Function() _isCurrent;
  bool _retired = false;
  bool get isCurrent => !_retired && _current(_isCurrent) && !_retired;
  void retire() => _retired = true;
  @override
  String toString() => 'NativeProviderViewLifetime';
}

final class NativeProviderRouteReview {
  const NativeProviderRouteReview._(
    this._policy,
    this.connection,
    this.purposes,
    this.routes,
    this._lifetime,
  );
  final NativeProviderRoutePolicy _policy;
  final NativeProviderConnectionIdentity connection;
  final Set<NativeProviderPurpose> purposes;
  final List<CredentialRoute> routes;
  final NativeProviderViewLifetime _lifetime;
  @override
  String toString() => 'NativeProviderRouteReview';
}

final class NativeProviderDestinationApproval {
  const NativeProviderDestinationApproval._(this._review);
  final NativeProviderRouteReview _review;
  @override
  String toString() => 'NativeProviderDestinationApproval';
}

/// Exact final routes only. KnownApiHosts/normalizers are NOT trust allowlists.
/// HTTPS-only: no HTTP/local bypass, redirects, discovery or probe authority.
final class NativeProviderRoutePolicy {
  NativeProviderRoutePolicy({required this._redaction});
  final SecretRedactionCoordinator _redaction;

  static bool _secretFreeEndpoint(
    String raw,
    SecretRedactionCoordinator redaction,
  ) {
    final uri = Uri.parse(raw);
    // Redactor's URL projection percent-encodes ':' in Gemini action segments.
    // Compare that benign canonical projection, never execute a redacted URL.
    final origin =
        '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
    final path = uri.pathSegments.map(Uri.encodeComponent).join('/');
    final benign = '$origin/$path';
    return redaction.redactor.redactText(raw) == benign &&
        redaction.redactor.redactText(raw.substring('https://'.length)) ==
            raw.substring('https://'.length);
  }

  static String _strictEndpoint(String raw) {
    try {
      if (raw.length > 2048 ||
          RegExp(r'[\s\\%?#]').hasMatch(raw) ||
          !RegExp(
            r'^https://[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?(?::[1-9][0-9]{0,4})?/',
          ).hasMatch(raw)) {
        throw const FormatException();
      }
      final rawPath = raw.indexOf('/', 'https://'.length);
      if (rawPath < 0 ||
          raw
              .substring(rawPath)
              .split('/')
              .any((part) => part == '.' || part == '..')) {
        throw const FormatException();
      }
      final uri = Uri.parse(raw);
      if (!uri.hasAuthority ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.authority.contains('@') ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.port < 1 ||
          uri.port > 65535 ||
          uri.path.contains('//') ||
          uri.pathSegments.any((part) => part == '.' || part == '..') ||
          !RegExp(r'^[a-zA-Z0-9._~/:\-]+$').hasMatch(uri.path) ||
          !RegExp(r'^[a-zA-Z0-9.-]+$').hasMatch(uri.host) ||
          uri.host.startsWith('.') ||
          uri.host.endsWith('.') ||
          uri.host.contains('..') ||
          !uri.host.contains('.') ||
          RegExp(r'^[0-9.]+$').hasMatch(uri.host) ||
          uri.host.endsWith('.local') ||
          uri.host.endsWith('.localhost') ||
          uri.host.endsWith('.internal') ||
          uri.host.endsWith('.home.arpa')) {
        throw const FormatException();
      }
      // A normalized spelling is reviewed/persisted once, not at dispatch.
      return uri.toString();
    } catch (_) {
      throw const NativeProviderException(NativeProviderFailure.denied);
    }
  }

  CredentialProtocol _protocol(NativeProviderConnectionIdentity connection) {
    switch (connection.protocol) {
      case 'openai':
      case 'openrouter':
        if (connection.useResponsesApi) break;
        return CredentialProtocol.openAiChatCompletions;
      case 'openai_responses':
        if (!connection.useResponsesApi) break;
        return CredentialProtocol.openAiResponses;
      case 'anthropic':
        if (connection.useResponsesApi) break;
        return CredentialProtocol.anthropic;
      case 'gemini':
        if (connection.useResponsesApi) break;
        return CredentialProtocol.gemini;
      case 'custom_chat_completion':
        return connection.useResponsesApi
            ? CredentialProtocol.openAiResponses
            : CredentialProtocol.openAiChatCompletions;
    }
    throw const NativeProviderException(NativeProviderFailure.denied);
  }

  /// Finite native default URL data, NOT entry/network permission. Only the
  /// custom_chat_completion mode uses [useResponsesApi] to choose its template.
  String standardEndpointFor(
    String protocol,
    String model, {
    bool stream = true,
    bool useResponsesApi = false,
  }) {
    switch (protocol) {
      case 'openai':
        return 'https://api.openai.com/v1/chat/completions';
      case 'openai_responses':
        return 'https://api.openai.com/v1/responses';
      case 'anthropic':
        return 'https://api.anthropic.com/v1/messages';
      case 'openrouter':
        return 'https://openrouter.ai/api/v1/chat/completions';
      case 'custom_chat_completion':
        return useResponsesApi
            ? 'https://api.openai.com/v1/responses'
            : 'https://api.openai.com/v1/chat/completions';
      case 'gemini':
        _requireGeminiModel(model);
        final action = stream ? 'streamGenerateContent' : 'generateContent';
        final endpoint =
            'https://generativelanguage.googleapis.com/v1beta/models/$model:$action';
        if (!_secretFreeEndpoint(endpoint, _redaction)) break;
        return endpoint;
    }
    throw const NativeProviderException(NativeProviderFailure.denied);
  }

  /// Pure classification of a VALID compatible saved route, never permission.
  /// Only exact equality with its finite default template avoids custom approval.
  /// Known host names, path normalizers and a chosen protocol cannot grant it.
  bool requiresCustomDestinationApproval(
    NativeProviderConnectionIdentity connection,
  ) {
    routesFor(connection: connection, purpose: NativeProviderPurpose.roleplay);
    return connection.endpoint !=
        standardEndpointFor(
          connection.protocol,
          connection.model,
          stream: connection.stream,
          useResponsesApi: connection.useResponsesApi,
        );
  }

  bool _custom(NativeProviderConnectionIdentity connection) =>
      requiresCustomDestinationApproval(connection);

  void _requireGeminiModel(String model) {
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{0,191}$').hasMatch(model) ||
        _redaction.redactor.redactText(model) != model) {
      throw const NativeProviderException(NativeProviderFailure.denied);
    }
  }

  CredentialPurpose _purpose(NativeProviderPurpose purpose) =>
      switch (purpose) {
        NativeProviderPurpose.roleplay ||
        NativeProviderPurpose.studio => CredentialPurpose.chat,
        NativeProviderPurpose.memoryBooks => CredentialPurpose.memory,
        NativeProviderPurpose.astoria => CredentialPurpose.assistant,
      };

  /// PURE route data. Compatible custom routes can be described without approval;
  /// description grants no entry, network, model-list, probe or redirect authority.
  List<CredentialRoute> routesFor({
    required NativeProviderConnectionIdentity connection,
    required NativeProviderPurpose purpose,
  }) {
    final endpoint = _strictEndpoint(connection.endpoint);
    if (endpoint != connection.endpoint ||
        !_secretFreeEndpoint(endpoint, _redaction) ||
        _redaction.redactor.redactText(connection.model) != connection.model) {
      throw const NativeProviderException(NativeProviderFailure.denied);
    }
    final protocol = _protocol(connection);
    final List<String> endpoints;
    if (protocol == CredentialProtocol.gemini) {
      _requireGeminiModel(connection.model);
      final savedAction = connection.stream
          ? 'streamGenerateContent'
          : 'generateContent';
      final suffix = '/models/${connection.model}:$savedAction';
      if (!endpoint.endsWith(suffix)) {
        throw const NativeProviderException(NativeProviderFailure.denied);
      }
      // Preserve the EXACT chosen origin/prefix. Never rewrite unknown versions
      // or paths, infer another model, probe alternatives or follow redirects.
      final prefix = endpoint.substring(0, endpoint.length - suffix.length);
      final base = '$prefix/models/${connection.model}';
      endpoints = ['$base:generateContent', '$base:streamGenerateContent'];
    } else {
      final suffix = switch (protocol) {
        CredentialProtocol.openAiChatCompletions => '/chat/completions',
        CredentialProtocol.openAiResponses => '/responses',
        CredentialProtocol.anthropic => '/messages',
        _ => '',
      };
      if (suffix.isEmpty || !endpoint.endsWith(suffix)) {
        throw const NativeProviderException(NativeProviderFailure.denied);
      }
      endpoints = [endpoint];
    }
    // The second Gemini action is also bounded and secret-free, not silently
    // usable merely because the saved one-shot spelling passed validation.
    for (final url in endpoints) {
      if (_strictEndpoint(url) != url ||
          !_secretFreeEndpoint(url, _redaction)) {
        throw const NativeProviderException(NativeProviderFailure.denied);
      }
    }
    return List.unmodifiable(
      endpoints.map(
        (url) => CredentialRoute(
          endpoint: url,
          protocol: protocol,
          purpose: _purpose(purpose),
        ),
      ),
    );
  }

  NativeProviderRouteReview reviewCustomDestination({
    required NativeProviderConnectionIdentity connection,
    required Set<NativeProviderPurpose> purposes,
    required NativeProviderViewLifetime lifetime,
  }) {
    _requireCurrent(() => lifetime.isCurrent);
    if (!_custom(connection) || purposes.isEmpty) {
      throw const NativeProviderException(NativeProviderFailure.denied);
    }
    return NativeProviderRouteReview._(
      this,
      connection,
      Set.unmodifiable(purposes),
      _routeSet(connection, purposes),
      lifetime,
    );
  }

  /// Invoke ONLY from the native final gesture on this displayed exact review.
  /// Do not publish this issuer through a tool, card decoder or callback registry.
  NativeProviderDestinationApproval confirmCustomDestination(
    NativeProviderRouteReview displayed,
  ) {
    _requireCurrent(() => displayed._lifetime.isCurrent);
    if (!identical(displayed._policy, this) ||
        !_sameRoutes(
          displayed.routes,
          _routeSet(displayed.connection, displayed.purposes),
        )) {
      throw const NativeProviderException(NativeProviderFailure.denied);
    }
    return NativeProviderDestinationApproval._(displayed);
  }

  List<CredentialRoute> _routeSet(
    NativeProviderConnectionIdentity connection,
    Set<NativeProviderPurpose> purposes,
  ) {
    final routes = <CredentialRoute>{};
    for (final purpose in purposes) {
      routes.addAll(routesFor(connection: connection, purpose: purpose));
    }
    final sorted = routes.toList()
      ..sort((a, b) => _routeBytes(a).compareTo(_routeBytes(b)));
    return List.unmodifiable(sorted);
  }

  bool _approved(
    NativeProviderConnectionIdentity connection,
    Set<NativeProviderPurpose> purposes,
    NativeProviderViewLifetime lifetime,
    NativeProviderDestinationApproval? approval,
  ) {
    if (!lifetime.isCurrent || purposes.isEmpty) return false;
    if (!_custom(connection)) {
      _routeSet(connection, purposes);
      return true;
    }
    final review = approval?._review;
    return review != null &&
        identical(review._policy, this) &&
        identical(review._lifetime, lifetime) &&
        review._lifetime.isCurrent &&
        review.connection == connection &&
        _samePurposes(review.purposes, purposes) &&
        _sameRoutes(review.routes, _routeSet(connection, purposes));
  }

  @override
  String toString() => 'NativeProviderRoutePolicy';
}

String _routeBytes(CredentialRoute route) => jsonEncode([
  route.endpoint.toString(),
  route.protocol.name,
  route.purpose.name,
]);
bool _sameRoutes(List<CredentialRoute> a, List<CredentialRoute> b) =>
    jsonEncode(a.map(_routeBytes).toList()) ==
    jsonEncode(b.map(_routeBytes).toList());
bool _samePurposes(
  Set<NativeProviderPurpose> a,
  Set<NativeProviderPurpose> b,
) => a.length == b.length && a.containsAll(b);
