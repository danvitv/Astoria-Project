import 'dart:convert';

import 'credential_vault.dart';
import 'secret_redactor.dart';

/// The image transport's existing normalization, not LLM route normalization.
/// Complete chat URLs retain the existing (even unusual) models siblings.
final class ImageOpenRouterDestinations {
  ImageOpenRouterDestinations(String endpoint) {
    base = (endpoint.trim().isEmpty ? defaultEndpoint : endpoint.trim())
        .replaceFirst(RegExp(r'/+$'), '');
    generation = base.endsWith('/chat/completions')
        ? base
        : '$base/chat/completions';
    models = '$base/models';
    imageModels =
        '$models?input_modalities=image%2Ctext&output_modalities=image';
    for (final value in [base, generation, models, imageModels]) {
      validate(value);
    }
  }

  // Must match OpenRouterConstants.defaultEndpoint; no dependency on feature UI.
  static const defaultEndpoint = 'https://openrouter.ai/api/v1';
  static const protocol = 'openrouter-image-chat-completions';
  late final String base, generation, models, imageModels;

  static void validate(String value) => _validate(value, signedDownload: false);

  /// Signed asset queries are transport capabilities, not API route bindings.
  /// Callers separately check complete original/current known-secret coverage.
  static void validateDownload(String value) =>
      _validate(value, signedDownload: true);

  static void _validate(String value, {required bool signedDownload}) {
    try {
      final uri = Uri.parse(value);
      if (!uri.hasAuthority ||
          uri.host.isEmpty ||
          !const ['https', 'http'].contains(uri.scheme) ||
          uri.port < 1 ||
          uri.port > 65535 ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment ||
          RegExp(r'[\s\\]').hasMatch(value) ||
          RegExp(r'%(?![a-fA-F0-9]{2})').hasMatch(value) ||
          !signedDownload &&
              uri.queryParameters.keys.any(SecretRedactor.isSecretField)) {
        throw const CredentialVaultAdmissionDenied();
      }
    } catch (_) {
      throw const CredentialVaultAdmissionDenied();
    }
  }

  /// Inspect the WHOLE original value before a one-layer decoded inspection.
  /// This also accepts local paths, HTML and instruction JSON. Download syntax
  /// is admitted separately at the actual HTTP boundary. Decoded text is never
  /// published or used as a rewritten download URL.
  static bool knownSecretFreeValue(SecretRedactor policy, String value) {
    if (!policy.isKnownSecretFree(value)) return false;
    try {
      // A public scalar may contain a literal percent sign alongside encoded
      // fields. Escape only that inspection ambiguity; never rewrite the value.
      final inspection = value.replaceAll(
        RegExp(r'%(?![a-fA-F0-9]{2})'),
        '%25',
      );
      return policy.isKnownSecretFree(Uri.decodeComponent(inspection)) &&
          policy.isKnownSecretFree(Uri.decodeQueryComponent(inspection));
    } catch (_) {
      return false;
    }
  }

  bool same(ImageOpenRouterDestinations other) =>
      generation == other.generation &&
      models == other.models &&
      imageModels == other.imageModels;

  String encode(String key) => jsonEncode({
    'version': 1,
    'protocol': protocol,
    'generation': generation,
    'models': models,
    'imageModels': imageModels,
    'key': key,
  });

  String keyFromRecord(String record) {
    try {
      final json = jsonDecode(record);
      if (json is Map &&
          json['version'] == 1 &&
          json['protocol'] == protocol &&
          json['generation'] == generation &&
          json['models'] == models &&
          json['imageModels'] == imageModels &&
          json['key'] is String &&
          (json['key'] as String).trim().isNotEmpty) {
        return json['key'] as String;
      }
    } catch (_) {}
    throw const CredentialVaultAdmissionDenied();
  }

  /// Register even a record bound to a retired route; it remains a known secret.
  static String recordKey(String record) {
    try {
      final json = jsonDecode(record);
      if (json is Map &&
          json['version'] == 1 &&
          json['protocol'] == protocol &&
          json['key'] is String &&
          json['generation'] is String &&
          json['models'] is String &&
          json['imageModels'] is String) {
        for (final field in ['generation', 'models', 'imageModels']) {
          validate(json[field] as String);
        }
        return json['key'] as String;
      }
    } catch (_) {}
    throw const CredentialVaultAdmissionDenied();
  }
}
