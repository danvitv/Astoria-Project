import 'dart:convert';
import 'backup_secret_preferences.dart';
import 'backup_secret_runtime.dart';
import 'backup_secret_routes.dart';
import 'backup_secret_urls.dart';

/// Audited live preference paths; prompts and arbitrary variables are inert.
abstract final class BackupSecretContainers {
  static const profiles = {
    'gz_provider_profiles',
    'gz_api_connection_presets',
    'gz_connection_presets',
    'sc_api_connection_presets',
    'silly_cradle_api_presets',
    'api_connection_presets',
  };
  static const imageFields = {
    'apiKey',
    'customApiKey',
    'routmyApiKey',
    'ruRoutmyApiKey',
    'naisteraApiKey',
  };
  static const providers = {
    'xai',
    'openrouter',
    'electronhub',
    'a1111',
    'novelai',
    'comfyui',
  };
  static const memoryFields = {'generationApiKey'};
  static const profileFields = {
    'apiKey',
    'embeddingApiKey',
    'generationApiKey',
    'key',
    'embedding_key',
  };
  static const pairs = {
    'gz_imggen_api_key': 'gz_imggen_endpoint',
    'gz_embedding_key': 'gz_embedding_endpoint',
    'api-key': 'api-endpoint',
  };

  static Object? document(Object? raw) {
    if (raw is! String) return raw;
    try {
      return jsonDecode(raw);
    } on FormatException {
      return raw;
    }
  }

  static Object? transform(Object? raw, Object? Function(Object?) action) {
    final decoded = document(raw);
    final result = action(decoded);
    if (raw is! String || decoded is String) return result;
    return jsonEncode(result) == jsonEncode(decoded) ? raw : jsonEncode(result);
  }

  /// Even a partial keyless archive can reroute APIs while leaving globals on
  /// the device. These universal overrides have no single proven owner.
  static Object? discardGlobalOverrides(
    Object? raw,
    bool Function(String) credential,
  ) => transform(raw, (value) {
    if (value is! Map) return value;
    final result = Map<dynamic, dynamic>.from(value);
    void strip(Map<dynamic, dynamic> map) {
      for (final field in [
        'postCleanerExtraRequestParameters',
        'studioControllerExtraRequestParameters',
        'studioFinalExtraRequestParameters',
      ]) {
        if (map.containsKey(field)) {
          map[field] = BackupSecretRuntime.stripParameters(
            map[field],
            credential,
          );
        }
      }
    }

    strip(result);
    for (final section in ['cleaner', 'studioAgent']) {
      if (value[section] is Map) {
        final map = Map<dynamic, dynamic>.from(value[section] as Map);
        strip(map);
        result[section] = map;
      }
    }
    return result;
  });

  static Object? preference(
    String key,
    Object? backup,
    Object? local,
    bool Function(String) credential, {
    required bool refill,
  }) {
    BackupSecretPreferences policy(
      Set<String> fields, {
      Set<String> children = const {},
      bool legacy = false,
    }) => BackupSecretPreferences(
      credential,
      fields: fields,
      children: children,
      legacyKey: legacy,
      endpoints: true,
    );
    final handler = profiles.contains(key)
        ? policy(
            profileFields,
            children: const {'profiles', 'presets', 'items'},
            legacy: true,
          )
        : key == 'gz_imggen_settings'
        ? policy(imageFields, children: providers)
        : key == 'memorySettings'
        ? policy(memoryFields)
        : null;
    if (handler != null) {
      return refill ? handler.refill(backup, local) : handler.strip(backup);
    }
    if (key != 'pipelineSettings') return backup;
    final l = document(local);
    return transform(backup, (value) {
      if (value is! Map) return value;
      final result = Map<dynamic, dynamic>.from(value);
      // These overrides apply across arbitrary sessions/agents, not one proven
      // global route. Never refill them from the device without ownership.
      void parameters(Map<dynamic, dynamic> map, String field) {
        if (!refill && map.containsKey(field)) {
          map[field] = BackupSecretRuntime.stripParameters(
            map[field],
            credential,
          );
        }
      }

      for (final section in ['cleaner', 'studioAgent']) {
        if (value[section] is! Map) continue;
        final map = Map<dynamic, dynamic>.from(value[section] as Map);
        for (final field in [
          'postCleanerExtraRequestParameters',
          'studioControllerExtraRequestParameters',
          'studioFinalExtraRequestParameters',
        ]) {
          parameters(map, field);
        }
        result[section] = map;
      }
      for (final field in [
        'postCleanerExtraRequestParameters',
        'studioControllerExtraRequestParameters',
        'studioFinalExtraRequestParameters',
      ]) {
        parameters(result, field);
      }
      if (value['memoryBookApi'] != null) {
        final p = policy(memoryFields);
        result['memoryBookApi'] = refill
            ? p.refill(
                value['memoryBookApi'],
                l is Map ? l['memoryBookApi'] : null,
              )
            : p.strip(value['memoryBookApi']);
      }
      // Accepted old flat pipeline keys are stripped but their retired routing
      // is not guessed on restore.
      if (!refill) {
        for (final field in [
          'auxApiKey',
          'sidecarApiKey',
          'generationApiKey',
        ]) {
          if (result.containsKey(field)) result[field] = '';
        }
        for (final field in [
          'auxEndpoint',
          'sidecarEndpoint',
          'generationEndpoint',
        ]) {
          if (result[field] is String) {
            result[field] = BackupSecretUrls.strip(
              result[field] as String,
              credential,
            );
          }
        }
      }
      return result;
    });
  }

  /// A missing credential-only field must not retain the device key under a
  /// newly restored URL. Write blanks before restoring preferences when unproven.
  static Map<String, Object?> pairUpdates(
    Map<String, dynamic> backup,
    Map<String, dynamic> local,
    bool Function(String) credential,
  ) => {
    for (final pair in pairs.entries)
      if (backup.containsKey(pair.value) &&
          !BackupSecretRoutes.same(
            backup[pair.value] is String ? backup[pair.value] as String : null,
            local[pair.value] is String ? local[pair.value] as String : null,
            credential,
          ))
        pair.key: '',
  };
}
