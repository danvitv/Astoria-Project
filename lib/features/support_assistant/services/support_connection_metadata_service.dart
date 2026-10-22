import '../../../core/credentials/api_connection_metadata.dart';
import '../../../core/credentials/credential_metadata.dart';
import '../../../core/credentials/secret_redactor.dart';
import '../../../core/db/repositories/api_config_repo.dart';
import '../models/support_native_view.dart';
import '../models/support_recipient_resolution.dart';
import 'support_recipient_resolver.dart';

/// Projects only current production Drift values; vault fallback is not authority.
class SupportConnectionMetadataService {
  SupportConnectionMetadataService(this._repo, this._redactor);
  final ApiConfigRepo _repo;
  final SecretRedactor Function() _redactor;

  /// Exact assistant-selected row ONLY, invoked inside the native local gate.
  /// Recipient rereads settings/row/settings; no bulk or roleplay fallback.
  Future<SupportConnectionInspection?> loadSelected(
    String sessionId,
    SupportRecipientResolver resolver,
    SupportRecipientSettingsReader readSettings, {
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) return null;
    final resolved = await resolver.resolve(sessionId);
    if (!isCurrent() || resolved is! SupportResolvedRecipient) return null;
    final settings = await readSettings(sessionId);
    if (!isCurrent() ||
        settings?.apiConfigId != resolved.recipient.connectionId ||
        settings?.modelId != resolved.recipient.modelId) {
      return null;
    }
    final row = await _repo.getById(resolved.recipient.connectionId);
    if (!isCurrent() || row == null || row.mode == 'embedding') return null;
    final latest = await resolver.resolve(sessionId);
    if (!isCurrent() ||
        latest is! SupportResolvedRecipient ||
        !latest.context.sameAs(resolved.context) ||
        !latest.recipient.sameAs(resolved.recipient)) {
      return null;
    }
    final redactor = _redactor().withKnownSecrets([
      row.apiKey,
      row.embeddingApiKey,
    ]);
    final credential = CredentialMetadata.fromSecret(row.apiKey);
    return SupportConnectionInspection(
      connectionLabel: redactor.redactText(latest.connectionLabel),
      protocolLabel: redactor.redactText(latest.protocolLabel),
      modelLabel: redactor.redactText(latest.recipient.modelId),
      configured: credential.configured,
      characterCount: credential.characterCount,
    );
  }

  Future<List<ApiConnectionMetadata>> load() async {
    final configs = await _repo
        .getAll(); // Registers all production secrets first.
    final redactor = _redactor();
    return List.unmodifiable(
      configs.map(
        (c) => ApiConnectionMetadata(
          connectionId: redactor.redactText(c.id),
          displayName: redactor.redactText(c.name),
          providerId: redactor.redactText(c.providerId),
          protocol: redactor.redactText(c.protocol),
          mode: redactor.redactText(c.mode),
          endpoint: c.endpoint.isEmpty ? '' : redactor.redactUrl(c.endpoint),
          model: redactor.redactText(c.model),
          llmCredential: CredentialMetadata.fromSecret(c.apiKey),
          embeddingCredential: CredentialMetadata.fromSecret(c.embeddingApiKey),
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
