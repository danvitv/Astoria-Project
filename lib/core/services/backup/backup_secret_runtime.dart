import 'dart:convert';

/// Narrow live cleaner override handling, excluding inert Studio state.
abstract final class BackupSecretRuntime {
  static Object? _document(Object? raw) {
    if (raw is! String) return raw;
    try {
      return jsonDecode(raw);
    } on FormatException {
      return raw;
    }
  }

  static Object? _transform(Object? raw, Object? Function(Object?) transform) {
    final value = _document(raw);
    final result = transform(value);
    if (raw is! String || value is String) return result;
    return jsonEncode(result) == jsonEncode(value) ? raw : jsonEncode(result);
  }

  static bool isCredentialParameter(
    Map<dynamic, dynamic> value,
    bool Function(String) credential,
  ) =>
      value['key'] is String &&
      credential(value['key'] as String) &&
      value.containsKey('value');

  static Object? stripParameters(
    Object? raw,
    bool Function(String) credential,
  ) => _transform(
    raw,
    (value) => value is List
        ? [
            for (final item in value)
              if (item is Map && isCredentialParameter(item, credential))
                {...item, 'value': item['value'] is String ? '' : null}
              else
                item,
          ]
        : value,
  );

  /// Retain only authentication values and their names, not prompts/settings.
  static Object? snapshotParameters(
    Object? raw,
    bool Function(String) credential,
  ) {
    final value = _document(raw);
    if (value is! List) return null;
    return [
      for (final item in value)
        if (item is Map && isCredentialParameter(item, credential))
          {'key': item['key'], 'value': item['value']},
    ];
  }

  static Object? refillParameters(
    Object? raw,
    Object? local,
    bool Function(String) credential,
  ) => _transform(raw, (value) {
    final localValues = _document(local);
    if (value is! List || localValues is! List) return value;
    return [
      for (final item in value)
        if (item is Map && isCredentialParameter(item, credential))
          _refillParameter(item, value, localValues)
        else
          item,
    ];
  });

  static Map<dynamic, dynamic> _refillParameter(
    Map<dynamic, dynamic> item,
    List<dynamic> backup,
    List<dynamic> local,
  ) {
    final value = item['value'];
    if (value != null && (value is! String || value.trim().isNotEmpty)) {
      return item;
    }
    bool matches(Object? candidate) =>
        candidate is Map && candidate['key'] == item['key'];
    final candidates = local.where(matches).toList();
    if (candidates.length != 1 || backup.where(matches).length != 1) {
      return item;
    }
    return {...item, 'value': (candidates.single as Map)['value'] ?? value};
  }

  static Object? transformStudio(
    Object? raw,
    Object? Function(Object?) transform,
  ) => _transform(raw, (value) {
    if (value is! Map) return value;
    const field = 'postCleanerExtraRequestParameters';
    final cleaner = value['cleaner'];
    return {
      ...value,
      if (cleaner is Map && cleaner.containsKey(field))
        'cleaner': {...cleaner, field: transform(cleaner[field])},
    };
  });
}
