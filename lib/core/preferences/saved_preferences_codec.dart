import 'dart:convert';

import '../models/pipeline_settings.dart';
import 'saved_preferences_schema.dart';

/// Pure typed decoding and complete-unit projection. Callbacks share ONE
/// bounded structural/JSON-string budget with the native source projection.
/// No notifier build/load, writes, script evaluation, provider or file access.
final class SavedPreferencesCodec {
  SavedPreferencesCodec({
    required this.decode,
    required this.text,
    required this.parameters,
    required this.authoredMap,
    required this.reference,
  });
  final Object? Function(String) decode;
  final String Function(String) text;
  final Object Function(Object?) parameters;
  final Object? Function(Object?) authoredMap;
  final int Function(String kind, String nativeId) reference;

  Map<String, Object?> project(String key, Object? raw) {
    if (raw == null) {
      return const {'savedState': 'missing', 'defaultsApplied': false};
    }
    try {
      final body = switch (key) {
        'memorySettings' => _memory(_map(raw)),
        'pipelineSettings' => _pipeline(_map(raw)),
        'gz_global_regex_scripts' => _regexes(_list(raw), studio: false),
        'gz_studio_regex_scripts' => _regexes(_list(raw), studio: true),
        'globalVars' || 'glaze.global_variables' => _variables(
          _map(raw),
          legacy: key == 'globalVars',
        ),
        'personaConnections' || 'presetConnections' => _connections(
          _map(raw),
          key == 'personaConnections' ? 'persona' : 'ordinaryPreset',
        ),
        'feature_studio_enabled' =>
          raw is bool ? raw : throw const FormatException(),
        _ => _selection(key, raw),
      };
      return {
        'savedState': 'saved',
        'value': body,
        'credentialsOmitted': true,
        'defaultsApplied': false,
        'scriptsExecuted': false,
      };
    } on FormatException {
      return const {'savedState': 'malformed', 'defaultsApplied': false};
    }
  }

  Map<String, Object?> _map(Object? raw) {
    final value = raw is String ? decode(raw) : raw;
    if (value is! Map<String, Object?>) throw const FormatException();
    return value;
  }

  List<Object?> _list(Object? raw) {
    final value = raw is String ? decode(raw) : raw;
    if (value is! List<Object?> || value.length > 512) {
      throw const FormatException();
    }
    return value;
  }

  Object? _scalar(Object? raw, Object? expected, {bool integer = false}) {
    if (raw == null && expected == null) return null;
    if (expected is bool && raw is bool) return raw;
    if ((integer || expected is int) && raw is int) return raw;
    if (!integer && expected is double && raw is num && raw.isFinite) {
      return raw;
    }
    if (expected is String && raw is String) return text(raw);
    throw const FormatException();
  }

  Map<String, Object?> _memory(Map<String, Object?> raw) {
    final result = <String, Object?>{};
    final missing = <String>[];
    for (final e in savedMemorySchema.entries) {
      if (!raw.containsKey(e.key)) {
        missing.add(e.key);
        continue;
      }
      result[e.key] = _scalar(
        raw[e.key],
        e.value,
        integer: e.key == 'maxInjectedTokens' && raw[e.key] != null,
      );
    }
    if (raw.containsKey('customPrompts')) {
      final prompts = _list(raw['customPrompts']);
      result['customPrompts'] = [
        for (final item in prompts) _prompt(_map(item)),
      ];
    } else {
      missing.add('customPrompts');
    }
    result['missingDefaultedFields'] = missing;
    result['unknownFieldsOmitted'] = raw.keys.any(
      (k) => !savedMemorySchema.containsKey(k) && k != 'customPrompts',
    );
    return result;
  }

  Map<String, Object?> _prompt(Map<String, Object?> raw) {
    final key = raw['key'];
    // Actual native custom identifiers are custom_<slug>[_<number>]. A generic
    // key/value credential container cannot attest a prompt discriminator.
    if (key is! String ||
        !(savedMemoryPromptKeys.contains(key) ||
            RegExp(r'^custom_[a-z0-9_]{1,100}$').hasMatch(key)) ||
        RegExp(
          r'(apikey|api_key|authorization|credential|secret|password|header|bearer|token)',
        ).hasMatch(key) ||
        text(key) != key ||
        raw['label'] is! String ||
        raw['prompt'] is! String) {
      throw const FormatException();
    }
    return {
      'promptIdentifier': key,
      'label': text(raw['label'] as String),
      'prompt': text(raw['prompt'] as String),
    };
  }

  Map<String, Object?> _pipeline(Map<String, Object?> raw) {
    final defaults =
        jsonDecode(jsonEncode(const PipelineSettings()))
            as Map<String, dynamic>;
    final result = <String, Object?>{};
    final nested = raw.containsKey('studioAgent');
    for (final section in savedPipelineFields.entries) {
      final input = nested
          ? (raw[section.key] == null
                ? <String, Object?>{}
                : _map(raw[section.key]!))
          : raw;
      final schema = defaults[section.key] as Map<String, dynamic>;
      final fields = <String, Object?>{};
      final missing = <String>[];
      for (final key in section.value) {
        if (!input.containsKey(key)) {
          missing.add(key);
          continue;
        }
        final value = input[key];
        if (key.endsWith('ExtraRequestParameters')) {
          fields[key] = parameters(value);
        } else if (key == 'apiConfigId') {
          fields['apiConfigurationReference'] = _nativeRef(
            'apiConfiguration',
            value,
          );
        } else if (key == 'generationEndpoint') {
          if (value is! String) throw const FormatException();
          // Endpoint is intentionally not a network/filesystem capability.
          fields[key] = value.isEmpty ? '' : '[redacted endpoint]';
        } else if (schema[key] == null && value != null) {
          fields[key] = key == 'generationMaxTokens'
              ? _scalar(value, 0)
              : _scalar(value, 0.0);
        } else {
          fields[key] = _scalar(value, schema[key]);
        }
      }
      fields['missingDefaultedFields'] = missing;
      fields['unknownFieldsOmitted'] = input.keys.any(
        (k) => !section.value.contains(k),
      );
      result[section.key] = fields;
    }
    result['storedFormat'] = nested ? 'nested' : 'legacy_flat';
    return result;
  }

  List<Object?> _regexes(List<Object?> raw, {required bool studio}) => [
    for (final item in raw) _regex(_map(item), studio: studio),
  ];
  Map<String, Object?> _regex(
    Map<String, Object?> raw, {
    required bool studio,
  }) {
    if (studio) {
      final script = raw['script'];
      if (script == null) throw const FormatException();
      final stages = raw['stages'];
      if (stages != null &&
          (stages is! List<Object?> || stages.any((v) => v is! String))) {
        throw const FormatException();
      }
      return {
        'script': _regex(_map(script), studio: false),
        'stages': stages == null
            ? []
            : (stages as List<Object?>)
                  .where(savedStudioRegexStages.contains)
                  .toList(),
      };
    }
    final result = <String, Object?>{};
    for (final e in savedRegexSchema.entries) {
      final value = raw[e.key] ?? raw[savedRegexAliases[e.key]];
      if (value == null && !raw.containsKey(e.key)) continue;
      if (e.value is List) {
        if (value is! List<Object?> || value.any((v) => v is! int)) {
          throw const FormatException();
        }
        result[e.key] = value;
      } else {
        result[e.key] = _scalar(
          value,
          e.value,
          integer: value != null && e.value == null,
        );
      }
    }
    result['unknownFieldsOmitted'] = raw.keys.any(
      (k) =>
          k != 'id' &&
          !savedRegexSchema.containsKey(k) &&
          !savedRegexAliases.values.contains(k),
    );
    return result;
  }

  Object? _variables(Map<String, Object?> raw, {required bool legacy}) {
    if (legacy && raw.values.any((v) => v is! String)) {
      throw const FormatException();
    }
    // Authored names are data values, not attested JSON/schema selector keys.
    final safe = authoredMap(raw);
    if (safe is! Map<String, Object?>) throw const FormatException();
    Object? content(Object? value) {
      if (value is Map<String, Object?>) {
        return [
          for (final e in value.entries)
            {'variableName': text(e.key), 'value': content(e.value)},
        ];
      }
      if (value is List<Object?>)
        return value.map(content).toList(growable: false);
      return value;
    }

    return content(safe);
  }

  Object _selection(String key, Object? raw) {
    final kind = switch (key) {
      'activePresetId' || 'active_preset_id' => 'ordinaryPreset',
      'activePersonaId' => 'persona',
      'activeStudioPresetId' => 'studioPreset',
      'activeApiConfigId' || 'activeEmbeddingConfigId' => 'apiConfiguration',
      _ => throw const FormatException(),
    };
    return {
      'kind': kind,
      'reference': _nativeRef(kind, raw),
      if (key == 'active_preset_id') 'legacyMigrationSpelling': true,
    };
  }

  int? _nativeRef(String kind, Object? raw) {
    if (raw is! String || raw.length > 512) throw const FormatException();
    return raw.isEmpty ? null : reference(kind, raw);
  }

  List<Object?> _connections(Map<String, Object?> raw, String kind) {
    final result = <Object?>[];
    for (final scope in const ['character', 'chat']) {
      final values = raw[scope];
      if (values == null) continue;
      final map = _map(values);
      for (final e in map.entries) {
        result.add({
          'scope': scope,
          'targetReference': _nativeRef(scope, e.key),
          'selectionKind': kind,
          'selectionReference': _nativeRef(kind, e.value),
        });
      }
    }
    return result;
  }
}
