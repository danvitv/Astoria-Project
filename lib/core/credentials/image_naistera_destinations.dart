import 'dart:convert';

import 'credential_vault.dart';
import 'image_openrouter_destinations.dart';
import 'secret_redactor.dart';

/// Exact Naistera client recipients, including the existing full-route sibling.
/// The base is a trusted client seam, never the image UI's custom LLM endpoint.
final class ImageNaisteraDestinations {
  ImageNaisteraDestinations([String baseUrl = defaultBase]) {
    base = baseUrl.replaceAll(RegExp(r'/+$'), '');
    generation = base.endsWith('/api/generate') ? base : '$base/api/generate';
    models = '$base/api/models';
    check = models;
    for (final value in [base, generation, models]) {
      ImageOpenRouterDestinations.validate(value);
    }
  }

  static const defaultBase = 'https://naistera.org';
  static const protocol = 'naistera-image-generate';

  /// The original client's finite aliases, never a general provider registry.
  static String normalizeModel(String? model) {
    final trimmed = (model ?? '').trim();
    if (trimmed.isEmpty) return 'grok';
    switch (trimmed.toLowerCase()) {
      case 'grok pro':
      case 'grok-pro':
      case 'grok-imagine-pro':
      case 'imagine-pro':
        return 'grok-pro';
      case 'nano-banana':
      case 'nano banana':
      case 'nano banana pro':
      case 'nano-banana-pro':
      case 'nano-banana-2':
      case 'nano banana 2':
        return 'nano banana 2';
      case 'novel ai':
      case 'novelai':
        return 'novelai';
    }
    return trimmed;
  }

  late final String base, generation, models, check;
  String job(String id) {
    if (id.isEmpty ||
        RegExp(r'[\\\x00-\x1f\x7f]').hasMatch(id) ||
        RegExp(r'%(?![a-fA-F0-9]{2})').hasMatch(id)) {
      throw const CredentialVaultAdmissionDenied();
    }
    final url = '$generation/jobs/${Uri.encodeComponent(id)}';
    ImageOpenRouterDestinations.validate(url);
    return url;
  }

  bool same(ImageNaisteraDestinations other) =>
      generation == other.generation &&
      models == other.models &&
      check == other.check;
  String encode(String key) => jsonEncode({
    'version': 1,
    'protocol': protocol,
    'generation': generation,
    'models': models,
    'check': check,
    'key': key,
  });

  String keyFromRecord(String record) {
    final key = recordKey(record);
    final json = jsonDecode(record) as Map;
    if (json['generation'] != generation ||
        json['models'] != models ||
        json['check'] != check ||
        key.trim().isEmpty) {
      throw const CredentialVaultAdmissionDenied();
    }
    return key;
  }

  static String recordKey(String record) {
    try {
      final json = jsonDecode(record);
      if (json is Map &&
          json['version'] == 1 &&
          json['protocol'] == protocol &&
          json['key'] is String) {
        for (final field in ['generation', 'models', 'check']) {
          if (json[field] is! String)
            throw const CredentialVaultAdmissionDenied();
          ImageOpenRouterDestinations.validate(json[field] as String);
        }
        return json['key'] as String;
      }
    } catch (_) {}
    throw const CredentialVaultAdmissionDenied();
  }

  static bool knownSecretFreeValue(SecretRedactor policy, String value) =>
      ImageOpenRouterDestinations.knownSecretFreeValue(policy, value);
}
