import 'dart:convert';

import '../models/api_config.dart';
import '../models/extra_request_parameter.dart';
import '../services/backup/backup_secrets.dart';
import 'api_connection_metadata.dart';
import 'credential_broker.dart';
import 'credential_metadata.dart';
import 'credential_slot.dart';
import 'credential_vault.dart';
import 'secret_redaction_coordinator.dart';
import 'secret_redactor.dart';

/// Bridges [ApiConfig] persistence with [CredentialVault], [SecretRedactor],
/// and optional [CredentialBroker] while keeping non-destructive Drift fallback.
final class ApiConfigCredentialAdapter {
  ApiConfigCredentialAdapter({
    required CredentialVault vault,
    SecretRedactor? redactor,
    SecretRedactionCoordinator? redactionCoordinator,
    CredentialBroker? broker,
  }) : assert(redactor == null || redactionCoordinator == null),
       // Keep the dependency private with a public constructor argument.
       // ignore: prefer_initializing_formals
       _vault = vault,
       _redaction =
           redactionCoordinator ??
           SecretRedactionCoordinator(redactor: redactor),
       // ignore: prefer_initializing_formals
       _broker = broker;

  final CredentialVault _vault;
  final SecretRedactionCoordinator _redaction;
  final CredentialBroker? _broker;

  static CredentialSlot llmSlot(String configId) =>
      CredentialSlot(domain: 'api_config.llm', id: configId);

  static CredentialSlot embeddingSlot(String configId) =>
      CredentialSlot(domain: 'api_config.embedding', id: configId);

  /// Active redactor including all secrets registered through this adapter.
  SecretRedactor get redactor => _redaction.redactor;

  String redactText(String text) => redactor.redactText(text);

  String sanitizeUrl(String url) =>
      url.trim().isEmpty ? '' : redactor.redactUrl(url.trim());

  /// Synchronously registers all secrets carried by [config] (including nested
  /// [ApiConfig.extraRequestParameters]) with the active redaction coordinator.
  void registerConfigSecrets(ApiConfig config) => _registerConfigSecrets(config);

  /// Synchronously registers all secrets carried by [configs].
  void registerAllConfigSecrets(Iterable<ApiConfig> configs) {
    for (final config in configs) {
      _registerConfigSecrets(config);
    }
  }

  Future<void> syncConfigToVault(ApiConfig config) async {
    _registerConfigSecrets(config);
    await _syncSlot(llmSlot(config.id), config.apiKey);
    await _syncSlot(embeddingSlot(config.id), config.embeddingApiKey);
  }

  Future<ApiConfig> hydrateFromVaultOrFallback(ApiConfig rowConfig) async {
    _registerConfigSecrets(rowConfig);
    final apiKey = await _hydrateSlotOrSeed(
      llmSlot(rowConfig.id),
      rowConfig.apiKey,
    );
    final embeddingApiKey = await _hydrateSlotOrSeed(
      embeddingSlot(rowConfig.id),
      rowConfig.embeddingApiKey,
    );
    final hydrated = rowConfig.copyWith(
      apiKey: apiKey,
      embeddingApiKey: embeddingApiKey,
    );
    _registerConfigSecrets(hydrated);
    return hydrated;
  }

  Future<void> deleteConfigCredentials(String configId) async {
    final llm = llmSlot(configId);
    final embedding = embeddingSlot(configId);
    _broker?.revokeSlot(llm);
    _broker?.revokeSlot(embedding);
    // A fresh adapter may not have hydrated this connection. Register vault-only
    // values before removal so historical diagnostics remain covered.
    final llmSecret = await _readConfiguredSecret(llm);
    if (llmSecret != null) _registerSecret(llmSecret);
    final embeddingSecret = await _readConfiguredSecret(embedding);
    if (embeddingSecret != null) _registerSecret(embeddingSecret);
    await _vault.delete(llm);
    await _vault.delete(embedding);
  }

  Future<ApiConnectionMetadata> projectMetadata(ApiConfig config) async {
    _registerConfigSecrets(config);
    final llmMeta = await _resolveSlotMetadata(
      llmSlot(config.id),
      config.apiKey,
    );
    final embeddingMeta = await _resolveSlotMetadata(
      embeddingSlot(config.id),
      config.embeddingApiKey,
    );
    return ApiConnectionMetadata(
      connectionId: redactText(config.id),
      displayName: redactText(config.name),
      providerId: redactText(config.providerId),
      protocol: redactText(config.protocol),
      mode: redactText(config.mode),
      endpoint: sanitizeUrl(config.endpoint),
      model: redactText(config.model),
      llmCredential: llmMeta,
      embeddingCredential: embeddingMeta,
      embeddingUseSame: config.embeddingUseSame,
      embeddingEnabled: config.embeddingEnabled,
      embeddingEndpoint: sanitizeUrl(config.embeddingEndpoint),
      embeddingModel: redactText(config.embeddingModel),
      embeddingLlmPresetId: redactText(config.embeddingLlmPresetId),
    );
  }

  Future<List<ApiConnectionMetadata>> projectAllMetadata(
    Iterable<ApiConfig> configs,
  ) async {
    final projections = <ApiConnectionMetadata>[];
    for (final config in configs) {
      projections.add(await projectMetadata(config));
    }
    return List<ApiConnectionMetadata>.unmodifiable(projections);
  }

  Future<void> _syncSlot(CredentialSlot slot, String rawSecret) async {
    final existing = await _readConfiguredSecret(slot);
    if (existing != null) _registerSecret(existing);
    if (rawSecret.trim().isEmpty) {
      _broker?.revokeSlot(slot);
      await _vault.delete(slot);
      return;
    }
    _registerSecret(rawSecret);
    if (existing != rawSecret) {
      _broker?.revokeSlot(slot);
    }
    await _vault.store(slot, rawSecret);
  }

  Future<String> _hydrateSlotOrSeed(
    CredentialSlot slot,
    String legacySecret,
  ) async {
    final vaultSecret = await _readConfiguredSecret(slot);
    if (vaultSecret != null) {
      _registerSecret(vaultSecret);
      return vaultSecret;
    }
    if (legacySecret.trim().isNotEmpty) {
      _registerSecret(legacySecret);
      await _vault.store(slot, legacySecret);
    }
    return legacySecret;
  }

  Future<CredentialMetadata> _resolveSlotMetadata(
    CredentialSlot slot,
    String fallbackSecret,
  ) async {
    final vaultSecret = await _readConfiguredSecret(slot);
    if (vaultSecret != null) {
      _registerSecret(vaultSecret);
      return CredentialMetadata.fromSecret(vaultSecret);
    }
    if (fallbackSecret.trim().isEmpty) return CredentialMetadata.absent;
    _registerSecret(fallbackSecret);
    return CredentialMetadata.fromSecret(fallbackSecret);
  }

  Future<String?> _readConfiguredSecret(CredentialSlot slot) async {
    final meta = await _vault.metadata(slot);
    if (!meta.configured) return null;
    String? secretValue;
    try {
      await _vault.useSecret(slot, (secret) async {
        secretValue = secret;
      });
    } on CredentialVaultException catch (e) {
      if (e.failure == CredentialVaultFailure.missing) return null;
      rethrow;
    }
    return secretValue;
  }

  void _registerConfigSecrets(ApiConfig config) {
    _registerSecret(config.apiKey);
    _registerSecret(config.embeddingApiKey);
    for (final ExtraRequestParameter param in config.extraRequestParameters) {
      if (BackupSecrets.isSecretField(param.key) ||
          SecretRedactor.isSecretField(param.key)) {
        _registerSecret(param.value);
      }
      _registerNestedJsonSecrets(param.value);
    }
  }

  void _registerNestedJsonSecrets(String raw) {
    final trimmed = raw.trimLeft();
    if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return;
    try {
      _walkSecretJson(jsonDecode(raw), 0);
    } catch (_) {}
  }

  void _walkSecretJson(Object? node, int depth) {
    if (depth > 8) return;
    if (node is Map) {
      for (final entry in node.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String &&
            (BackupSecrets.isSecretField(key) ||
                SecretRedactor.isSecretField(key)) &&
            value is String) {
          _registerSecret(value);
        } else {
          _walkSecretJson(value, depth + 1);
        }
      }
    } else if (node is List) {
      for (final item in node) {
        _walkSecretJson(item, depth + 1);
      }
    }
  }

  void _registerSecret(String raw) => _redaction.registerSecret(raw);

  @override
  String toString() => 'ApiConfigCredentialAdapter';
}
