import 'credential_metadata.dart';
import 'credential_route.dart';
import 'secret_redactor.dart';

/// Explicit allowlist for connection diagnostics. It deliberately accepts no
/// ApiConfig, raw API key, headers, transport config, or generic model.toJson.
/// Native callers supply only these selected fields and vault-derived metadata.
final class ConnectionMetadataProjection {
  // Keep the secret-aware dependency private, with a public injection name.
  const ConnectionMetadataProjection({required SecretRedactor redactor})
    // ignore: prefer_initializing_formals
    : _redactor = redactor;

  final SecretRedactor _redactor;

  Map<String, Object?> project({
    required String connectionId,
    required String displayName,
    required String endpoint,
    required CredentialProtocol protocol,
    required CredentialMetadata credential,
    String? modelId,
    Map<String, Object?> diagnosticParameters = const {},
  }) => {
    'connectionId': _redactor.redactText(connectionId),
    'displayName': _redactor.redactText(displayName),
    'endpoint': _redactor.redactUrl(endpoint),
    'protocol': protocol.name,
    'credential': credential.toJson(),
    if (modelId != null) 'modelId': _redactor.redactText(modelId),
    // This is an explicitly opted-in diagnostic subset, NOT extraParams passthrough.
    // The caller must select relevant non-PII fields before this defense in depth.
    'diagnosticParameters': _redactor.redactJson(diagnosticParameters),
  };

  @override
  String toString() => 'ConnectionMetadataProjection';
}
