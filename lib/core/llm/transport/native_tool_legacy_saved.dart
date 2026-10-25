part of 'native_tool_transport.dart';

/// One original ordinary saved-row source, not a native credential authority.
/// Its stamp and the original ROOT callback only revoke; each wire separately
/// requires fresh actual native/preparation absence. No alternate slot is read.
final class _LegacySavedToolSource {
  _LegacySavedToolSource(ApiConfig config, this.stamp, Uri recipient)
    : _secret = config.apiKey {
    _ntRequire(
      config.mode == 'chat' &&
          config.apiKey.isNotEmpty &&
          config.apiKey.length <= 8192 &&
          !RegExp(r'[\x00-\x20\x7f]').hasMatch(config.apiKey) &&
          config.embeddingApiKey.isEmpty &&
          !config.embeddingEnabled &&
          config.extraRequestParameters.isEmpty &&
          config.id.isNotEmpty &&
          config.model.isNotEmpty &&
          config.model.length <= 256 &&
          !config.endpoint.contains(config.apiKey) &&
          !config.endpoint.contains(Uri.encodeComponent(config.apiKey)),
      NativeToolReason.denied,
    );
    final protocol = switch (config.protocol) {
      'openai' || 'openrouter' when !config.useResponsesApi =>
        CredentialProtocol.openAiChatCompletions,
      'openai_responses' when config.useResponsesApi =>
        CredentialProtocol.openAiResponses,
      'custom_chat_completion' =>
        config.useResponsesApi
            ? CredentialProtocol.openAiResponses
            : CredentialProtocol.openAiChatCompletions,
      'anthropic' when !config.useResponsesApi => CredentialProtocol.anthropic,
      'gemini' when !config.useResponsesApi => CredentialProtocol.gemini,
      _ => _ntFail(NativeToolReason.unsupported),
    };
    try {
      // Pure route data, NOT NativeProviderDestinationApproval. Preserve the
      // actual saved spelling and recipient, including a compatible custom URL.
      route = CredentialRoute(
        endpoint: config.endpoint,
        protocol: protocol,
        purpose: CredentialPurpose.assistant,
      );
    } catch (_) {
      _ntFail(NativeToolReason.denied);
    }
    _ntRequire(
      config.endpoint == recipient.toString() && route.endpoint == recipient,
      NativeToolReason.denied,
    );
    if (protocol == CredentialProtocol.gemini) {
      // The finite loop is JSON/one-shot. Do not invent a sibling operation URL
      // for a legacy streaming row or silently substitute another model/action.
      _ntRequire(
        !config.stream &&
            RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(config.model) &&
            route.endpoint.path.endsWith(
              '/models/${config.model}:generateContent',
            ),
        NativeToolReason.unsupported,
      );
    }
  }
  final NativeConnectionStamp stamp;
  late final CredentialRoute route;
  String _secret;
  bool _claimed = false;
  bool _retired = false;

  void claim() {
    _ntRequire(!_claimed && !_retired, NativeToolReason.notCurrent);
    _claimed = true;
  }

  bool isCurrent(NativeConnectionMutationOwner mutations) =>
      !_retired && _secret.isNotEmpty && mutations.isCurrent(stamp);

  void checkMetadata(ApiConfig config, SecretRedactor redactor) {
    _toolSafeStrings([
      config.id,
      config.providerId,
      config.protocol,
      config.model,
    ], redactor);
    final safe = redactor.redactUrl(route.endpoint.toString());
    _ntRequire(
      !safe.contains(SecretRedactor.removed) &&
          !safe.contains(SecretRedactor.limited) &&
          !safe.contains(Uri.encodeComponent(SecretRedactor.removed)) &&
          !safe.contains(Uri.encodeComponent(SecretRedactor.limited)),
      NativeToolReason.denied,
    );
  }

  void retire() {
    _retired = true;
    _secret = '';
  }

  @override
  String toString() => 'LegacySavedToolSource';
}
