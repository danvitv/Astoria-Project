import 'dart:convert';

import 'credential_metadata.dart';

/// Immutable, secret-free diagnostic DTO for a persisted API connection.
/// Distinct from the phase 1A allowlisted connection projection service.
final class ApiConnectionMetadata {
  const ApiConnectionMetadata({
    required this.connectionId,
    required this.displayName,
    required this.providerId,
    required this.protocol,
    required this.mode,
    required this.endpoint,
    required this.model,
    required this.llmCredential,
    required this.embeddingCredential,
    required this.embeddingUseSame,
    required this.embeddingEnabled,
    required this.embeddingEndpoint,
    required this.embeddingModel,
    required this.embeddingLlmPresetId,
  });

  final String connectionId;
  final String displayName;
  final String providerId;
  final String protocol;
  final String mode;
  final String endpoint;
  final String model;
  final CredentialMetadata llmCredential;
  final CredentialMetadata embeddingCredential;
  final bool embeddingUseSame;
  final bool embeddingEnabled;
  final String embeddingEndpoint;
  final String embeddingModel;
  final String embeddingLlmPresetId;

  bool get configured => llmCredential.configured;
  int get characterCount => llmCredential.characterCount;
  bool get embeddingConfigured => embeddingCredential.configured;
  int get embeddingCharacterCount => embeddingCredential.characterCount;

  Map<String, Object?> toJson() => {
    'connectionId': connectionId,
    'displayName': displayName,
    'providerId': providerId,
    'protocol': protocol,
    'mode': mode,
    'endpoint': endpoint,
    'model': model,
    'llmCredential': llmCredential.toJson(),
    'embeddingCredential': embeddingCredential.toJson(),
    'embeddingUseSame': embeddingUseSame,
    'embeddingEnabled': embeddingEnabled,
    'embeddingEndpoint': embeddingEndpoint,
    'embeddingModel': embeddingModel,
    'embeddingLlmPresetId': embeddingLlmPresetId,
  };

  @override
  bool operator ==(Object other) =>
      other is ApiConnectionMetadata &&
      connectionId == other.connectionId &&
      displayName == other.displayName &&
      providerId == other.providerId &&
      protocol == other.protocol &&
      mode == other.mode &&
      endpoint == other.endpoint &&
      model == other.model &&
      llmCredential == other.llmCredential &&
      embeddingCredential == other.embeddingCredential &&
      embeddingUseSame == other.embeddingUseSame &&
      embeddingEnabled == other.embeddingEnabled &&
      embeddingEndpoint == other.embeddingEndpoint &&
      embeddingModel == other.embeddingModel &&
      embeddingLlmPresetId == other.embeddingLlmPresetId;

  @override
  int get hashCode => Object.hash(
    connectionId,
    displayName,
    providerId,
    protocol,
    mode,
    endpoint,
    model,
    llmCredential,
    embeddingCredential,
    embeddingUseSame,
    embeddingEnabled,
    embeddingEndpoint,
    embeddingModel,
    embeddingLlmPresetId,
  );

  @override
  String toString() => jsonEncode(toJson());
}
