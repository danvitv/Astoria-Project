import 'dart:convert';

import 'credential_vault.dart';
import 'image_openrouter_destinations.dart';
import 'secret_redactor.dart';

/// Exact existing NovelAI image recipients, never an LLM endpoint policy.
final class ImageNovelAiDestinations {
  ImageNovelAiDestinations(String endpoint, String selectedModel) {
    final trimmed = endpoint.trim().replaceFirst(RegExp(r'/+$'), '');
    base = trimmed.isEmpty ? defaultEndpoint : trimmed;
    model = selectedModel.trim().isEmpty ? defaultModel : selectedModel.trim();
    generation = '$base/ai/generate-image';
    check =
        '$generation/suggest-tags?model=${Uri.encodeComponent(model)}&prompt=a';
    for (final value in [base, generation, check]) {
      ImageOpenRouterDestinations.validate(value);
    }
  }

  static const defaultEndpoint = 'https://image.novelai.net';
  static const defaultModel = 'nai-diffusion-4-5-full';
  static const protocol = 'novelai-image-generate';
  late final String base, generation, check, model;

  bool same(ImageNovelAiDestinations other) =>
      generation == other.generation &&
      check == other.check &&
      model == other.model;

  String encode(String key) => jsonEncode({
    'version': 1,
    'protocol': protocol,
    'generation': generation,
    'check': check,
    'model': model,
    'key': key,
  });

  String keyFromRecord(String record) {
    try {
      final json = jsonDecode(record);
      if (json is Map &&
          json['version'] == 1 &&
          json['protocol'] == protocol &&
          json['generation'] == generation &&
          json['check'] == check &&
          json['model'] == model &&
          json['key'] is String &&
          (json['key'] as String).trim().isNotEmpty) {
        return json['key'] as String;
      }
    } catch (_) {}
    throw const CredentialVaultAdmissionDenied();
  }

  static String recordKey(String record) {
    try {
      final json = jsonDecode(record);
      if (json is Map &&
          json['version'] == 1 &&
          json['protocol'] == protocol &&
          json['generation'] is String &&
          json['check'] is String &&
          json['model'] is String &&
          json['key'] is String) {
        ImageOpenRouterDestinations.validate(json['generation'] as String);
        ImageOpenRouterDestinations.validate(json['check'] as String);
        return json['key'] as String;
      }
    } catch (_) {}
    throw const CredentialVaultAdmissionDenied();
  }

  static bool knownSecretFreeValue(SecretRedactor policy, String value) =>
      ImageOpenRouterDestinations.knownSecretFreeValue(policy, value);
}
