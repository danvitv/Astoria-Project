part of 'native_provider_credentials.dart';

/// Safe, immutable saved-row routing identity. No ApiConfig is retained.
/// Obtain it through the native issuer, never from imported/model JSON.
final class NativeProviderConnectionIdentity {
  const NativeProviderConnectionIdentity._({
    required this.id,
    required this.providerId,
    required this.protocol,
    required this.endpoint,
    required this.model,
    required this.stream,
    required this.useResponsesApi,
  });

  final String id;
  final String providerId;
  final String protocol;
  final String endpoint;
  final String model;
  final bool stream;
  final bool useResponsesApi;

  static NativeProviderConnectionIdentity? _fromSaved(
    ApiConfig config,
    SecretRedactionCoordinator redaction,
  ) {
    final strings = [
      config.id,
      config.providerId,
      config.protocol,
      config.model,
    ];
    if (config.mode != 'chat' ||
        !RegExp(r'^[a-zA-Z0-9_-][a-zA-Z0-9._-]{0,127}$').hasMatch(config.id) ||
        !RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(config.providerId) ||
        !const {
          'openai',
          'openai_responses',
          'anthropic',
          'gemini',
          'openrouter',
          'custom_chat_completion',
        }.contains(config.protocol) ||
        !RegExp(
          r'^[a-zA-Z0-9][a-zA-Z0-9._/:\-]{0,191}$',
        ).hasMatch(config.model) ||
        strings.any((value) => redaction.redactor.redactText(value) != value)) {
      return null;
    }
    try {
      final endpoint = NativeProviderRoutePolicy._strictEndpoint(
        config.endpoint,
      );
      if (endpoint != config.endpoint ||
          !NativeProviderRoutePolicy._secretFreeEndpoint(endpoint, redaction)) {
        return null;
      }
      return NativeProviderConnectionIdentity._(
        id: config.id,
        providerId: config.providerId,
        protocol: config.protocol,
        endpoint: endpoint,
        model: config.model,
        stream: config.stream,
        useResponsesApi: config.useResponsesApi,
      );
    } catch (_) {
      return null;
    }
  }

  List<Object> get _fields => [
    id,
    providerId,
    protocol,
    endpoint,
    model,
    stream,
    useResponsesApi,
  ];

  @override
  bool operator ==(Object other) =>
      other is NativeProviderConnectionIdentity &&
      jsonEncode(_fields) == jsonEncode(other._fields);

  @override
  int get hashCode => Object.hashAll(_fields);

  @override
  String toString() => 'NativeProviderConnectionIdentity';
}

/// An identity/stamp, NOT network, prompt, settings or credential permission.
final class SavedConnectionAuth {
  const SavedConnectionAuth._(this.connection, this.purpose, this._stamp);
  final NativeProviderConnectionIdentity connection;
  final NativeProviderPurpose purpose;
  final NativeConnectionStamp _stamp;

  @override
  String toString() => 'SavedConnectionAuth';
}

final class NativeSavedConnectionAuthIssuer {
  NativeSavedConnectionAuthIssuer({required this._mutations});

  final NativeConnectionMutationOwner _mutations;

  bool isCurrent(SavedConnectionAuth reference) =>
      _mutations.isCurrent(reference._stamp) &&
      _mutations._row(reference.connection) != null;

  SavedConnectionAuth? referenceFor(
    ApiConfig config,
    NativeProviderPurpose purpose,
  ) {
    final stamp = _mutations.observe();
    final identity = NativeProviderConnectionIdentity._fromSaved(
      config,
      _mutations._redaction,
    );
    if (stamp == null || identity == null) return null;
    // Only boolean conflict facts stay inside the trusted owner. Neither keys,
    // embeddings nor extras enter the identity/reference or an assistant DTO.
    _mutations._rows[identity.id] = _NativeSavedRow(
      identity,
      stamp,
      config.apiKey.isNotEmpty ||
          config.embeddingApiKey.isNotEmpty ||
          config.embeddingEnabled ||
          config.extraRequestParameters.isNotEmpty,
    );
    return SavedConnectionAuth._(identity, purpose, stamp);
  }

  @override
  String toString() => 'NativeSavedConnectionAuthIssuer';
}

final class _NativeSavedRow {
  const _NativeSavedRow(this.identity, this.stamp, this.conflicting);
  final NativeProviderConnectionIdentity identity;
  final NativeConnectionStamp stamp;
  final bool conflicting;
}
