part of 'support_provider_action_service.dart';

extension _ProviderProjection on SupportProviderActionService {
  SupportProviderSetupValue? _project(
    KeylessApiConfigView view,
    SecretRedactor p,
  ) {
    if (!view.isValid) return null;
    final strings = [
      view.connectionId,
      view.displayName,
      view.providerId,
      view.protocol,
      view.model,
    ];
    // Evidence field bytes must match the effect. Never persist masks as labels
    // or silently sanitize an executable field and claim the old review applied.
    if (strings.any((s) => p.redactText(s) != s)) return null;
    try {
      final uri = Uri.parse(view.endpoint);
      final origin =
          '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
      final benign =
          '$origin/${uri.pathSegments.map(Uri.encodeComponent).join('/')}';
      if (p.redactText(view.endpoint) != benign ||
          p.redactText(view.endpoint.substring('https://'.length)) !=
              view.endpoint.substring('https://'.length)) {
        return null;
      }
    } catch (_) {
      return null;
    }
    return SupportProviderSetupValue(
      connectionId: view.connectionId,
      name: view.displayName,
      protocol: view.protocol,
      endpoint: view.endpoint,
      model: view.model,
      maxTokens: view.maxTokens,
      contextSize: view.contextSize,
      temperature: view.temperature,
    );
  }

  SupportProviderSetupPreview? _projectExact(SupportProviderReview review) {
    try {
      final p = currentRedactor();
      if (p.redactText(review._binding.sessionId) !=
          review._binding.sessionId) {
        return null;
      }
      final before = review._before == null
          ? null
          : _project(review._before, p);
      final after = review._after == null ? null : _project(review._after, p);
      if ((review._before != null && before == null) ||
          (review._after != null && after == null) ||
          !identical(p, currentRedactor())) {
        return null;
      }
      return SupportProviderSetupPreview(
        kind: review.kind,
        purpose: review.purpose,
        destinationKind: review.destinationKind,
        before: before,
        after: after,
      );
    } catch (_) {
      return null;
    }
  }

  SupportProviderSetupValue? _projectHandle(
    SupportProviderConnectionHandle handle,
  ) {
    if (!_current(handle._binding)) return null;
    try {
      final p = currentRedactor();
      final value = _project(handle._view, p);
      return _current(handle._binding) && identical(p, currentRedactor())
          ? value
          : null;
    } catch (_) {
      return null;
    }
  }

  SupportProviderDestinationKind? _destination(KeylessApiConfigView view) {
    try {
      // Native core currently supports strict public HTTPS DNS routes ONLY.
      // HTTP, IP literals and local hosts are unavailable, not "custom supported".
      final raw = view.endpoint;
      final uri = Uri.parse(raw);
      if (!RegExp(
            r'^https://[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?(?::[1-9][0-9]{0,4})?/',
          ).hasMatch(raw) ||
          !RegExp(r'^[a-zA-Z0-9._~/:\-]+$').hasMatch(uri.path) ||
          !uri.host.contains('.') ||
          uri.host.startsWith('.') ||
          uri.host.endsWith('.') ||
          uri.host.contains('..') ||
          RegExp(r'^[0-9.]+$').hasMatch(uri.host) ||
          [
            '.local',
            '.localhost',
            '.internal',
            '.home.arpa',
          ].any(uri.host.endsWith) ||
          !RegExp(
            r'^[a-zA-Z0-9][a-zA-Z0-9._/:\-]{0,191}$',
          ).hasMatch(view.model)) {
        return null;
      }
      final standard = routePolicy.standardEndpointFor(
        view.protocol,
        view.model,
        stream: true,
        useResponsesApi: view.protocol == 'openai_responses',
      );
      return raw == standard
          ? SupportProviderDestinationKind.standard
          : SupportProviderDestinationKind.customHttps;
    } catch (_) {
      return null;
    }
  }
}
