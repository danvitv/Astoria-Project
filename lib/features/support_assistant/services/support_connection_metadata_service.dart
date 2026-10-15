import '../../../core/credentials/api_connection_metadata.dart';
import '../../../core/credentials/credential_metadata.dart';
import '../../../core/credentials/secret_redactor.dart';
import '../../../core/db/repositories/api_config_repo.dart';

/// Projects only current production Drift values; vault fallback is not authority.
class SupportConnectionMetadataService {
  SupportConnectionMetadataService(this._repo, this._redactor);
  final ApiConfigRepo _repo;
  final SecretRedactor Function() _redactor;
  Future<List<ApiConnectionMetadata>> load() async {
    final configs = await _repo.getAll(); // Registers all production secrets first.
    final redactor = _redactor();
    return List.unmodifiable(configs.map((c) => ApiConnectionMetadata(
      connectionId: redactor.redactText(c.id), displayName: redactor.redactText(c.name),
      providerId: redactor.redactText(c.providerId), protocol: redactor.redactText(c.protocol), mode: redactor.redactText(c.mode),
      endpoint: c.endpoint.isEmpty ? '' : redactor.redactUrl(c.endpoint), model: redactor.redactText(c.model),
      llmCredential: CredentialMetadata.fromSecret(c.apiKey), embeddingCredential: CredentialMetadata.fromSecret(c.embeddingApiKey),
      embeddingUseSame: c.embeddingUseSame, embeddingEnabled: c.embeddingEnabled,
      embeddingEndpoint: c.embeddingEndpoint.isEmpty ? '' : redactor.redactUrl(c.embeddingEndpoint),
      embeddingModel: redactor.redactText(c.embeddingModel), embeddingLlmPresetId: redactor.redactText(c.embeddingLlmPresetId),
    )));
  }
}
