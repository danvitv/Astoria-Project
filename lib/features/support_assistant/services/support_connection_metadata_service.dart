import '../../../core/credentials/api_connection_metadata.dart';
import '../../../core/credentials/native_provider_credentials.dart';
import '../../../core/credentials/secret_redactor.dart';
import '../../../core/db/repositories/api_config_repo.dart';
import '../models/support_native_view.dart';
import '../models/support_recipient_resolution.dart';
import 'support_recipient_resolver.dart';

/// Read-only projection. Protected native metadata is storage truth, never a
/// purpose/network grant. Unknown native facts must not become a legacy key.
class SupportConnectionMetadataService {
  SupportConnectionMetadataService(
    this._repo,
    this._redactor, {
    this._nativeMetadata,
    this._nativeMetadataIsCurrent,
  });
  final ApiConfigRepo _repo;
  final SecretRedactor Function() _redactor;
  final NativeProviderCredentialMetadataReader? _nativeMetadata;
  final bool Function()? _nativeMetadataIsCurrent;

  bool _current(bool Function() current) {
    try {
      return current() && (_nativeMetadataIsCurrent?.call() ?? true);
    } catch (_) {
      return false;
    }
  }

  /// Exact assistant-selected row ONLY, invoked inside the native local gate.
  /// Recipient rereads settings/row/settings; no bulk or roleplay fallback.
  Future<SupportConnectionInspection?> loadSelected(
    String sessionId,
    SupportRecipientResolver resolver,
    SupportRecipientSettingsReader readSettings, {
    required bool Function() isCurrent,
  }) async {
    final originalRedactor = _redactor();
    bool current() =>
        _current(isCurrent) &&
        (_nativeMetadata == null || identical(originalRedactor, _redactor()));
    if (!current()) return null;
    NativeProviderConfigurationMetadata? native;
    String? metadataConnectionId;
    final metadata = _nativeMetadata;
    if (metadata != null) {
      // Register the cold protected key BEFORE resolver label projection. This
      // remains inside the original local-data gate; OFF never calls this port.
      final selected = await readSettings(sessionId);
      if (!current() || selected?.apiConfigId == null) return null;
      metadataConnectionId = selected!.apiConfigId!;
      final selectedRow = await _repo.getById(metadataConnectionId);
      if (!current() ||
          selectedRow == null ||
          selectedRow.mode == 'embedding') {
        return null;
      }
      native = await metadata.readConfiguration(
        connectionId: metadataConnectionId,
        isCurrent: current,
      );
      if (!current() || (native.nativeManaged && native.metadata == null)) {
        return null;
      }
      final latestSettings = await readSettings(sessionId);
      if (!current() ||
          latestSettings?.apiConfigId != selected.apiConfigId ||
          latestSettings?.modelId != selected.modelId) {
        return null;
      }
    }
    final resolved = await resolver.resolve(sessionId);
    if (!current() || resolved is! SupportResolvedRecipient) return null;
    if (metadataConnectionId != null &&
        metadataConnectionId != resolved.recipient.connectionId) {
      return null;
    }
    final settings = await readSettings(sessionId);
    if (!current() ||
        settings?.apiConfigId != resolved.recipient.connectionId ||
        settings?.modelId != resolved.recipient.modelId) {
      return null;
    }
    final row = await _repo.getById(resolved.recipient.connectionId);
    if (!current() || row == null || row.mode == 'embedding') return null;
    final latest = await resolver.resolve(sessionId);
    if (!current() ||
        latest is! SupportResolvedRecipient ||
        !latest.context.sameAs(resolved.context) ||
        !latest.recipient.sameAs(resolved.recipient)) {
      return null;
    }
    final redactor = _redactor().withKnownSecrets([
      row.apiKey,
      row.embeddingApiKey,
    ]);
    final credential = native?.nativeManaged == true
        ? native!.metadata!
        : CredentialMetadata.fromSecret(row.apiKey);
    return SupportConnectionInspection(
      connectionLabel: redactor.redactText(latest.connectionLabel),
      protocolLabel: redactor.redactText(latest.protocolLabel),
      modelLabel: redactor.redactText(latest.recipient.modelId),
      configured: credential.configured,
      characterCount: credential.characterCount,
    );
  }

  Future<List<ApiConnectionMetadata>> load({bool Function()? isCurrent}) async {
    bool current() => _current(isCurrent ?? () => true);
    if (!current()) return const [];
    final configs = await _repo
        .getAll(); // Registers all production secrets first.
    if (!current()) return const [];
    final credentials = <String, CredentialMetadata?>{};
    final metadata = _nativeMetadata;
    if (metadata != null) {
      // Inspect EVERY protected slot before projecting ANY variable string.
      // Unknown native rows are omitted, not labelled as empty/legacy.
      for (final config in configs) {
        final facts = await metadata.readConfiguration(
          connectionId: config.id,
          isCurrent: current,
        );
        if (!current()) return const [];
        credentials[config.id] = facts.nativeManaged
            ? facts.metadata
            : CredentialMetadata.fromSecret(config.apiKey);
      }
    }
    final redactor = _redactor();
    return List.unmodifiable(
      configs
          .where((c) => metadata == null || credentials[c.id] != null)
          .map(
            (c) => ApiConnectionMetadata(
              connectionId: redactor.redactText(c.id),
              displayName: redactor.redactText(c.name),
              providerId: redactor.redactText(c.providerId),
              protocol: redactor.redactText(c.protocol),
              mode: redactor.redactText(c.mode),
              endpoint: c.endpoint.isEmpty
                  ? ''
                  : redactor.redactUrl(c.endpoint),
              model: redactor.redactText(c.model),
              llmCredential: metadata == null
                  ? CredentialMetadata.fromSecret(c.apiKey)
                  : credentials[c.id]!,
              embeddingCredential: CredentialMetadata.fromSecret(
                c.embeddingApiKey,
              ),
              embeddingUseSame: c.embeddingUseSame,
              embeddingEnabled: c.embeddingEnabled,
              embeddingEndpoint: c.embeddingEndpoint.isEmpty
                  ? ''
                  : redactor.redactUrl(c.embeddingEndpoint),
              embeddingModel: redactor.redactText(c.embeddingModel),
              embeddingLlmPresetId: redactor.redactText(c.embeddingLlmPresetId),
            ),
          ),
    );
  }
}
