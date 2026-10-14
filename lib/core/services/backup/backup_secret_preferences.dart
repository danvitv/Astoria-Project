import 'dart:convert';

import 'backup_secret_urls.dart';

/// JSON preference credentials with stable-owner and URL destination guards.
class BackupSecretPreferences {
  final bool Function(String) credential;
  final bool legacyKey;
  final bool endpoints;
  final Set<String>? fields;
  final Set<String> children;
  final bool allowRefill;

  const BackupSecretPreferences(
    this.credential, {
    this.legacyKey = false,
    this.endpoints = false,
    this.fields,
    this.children = const {},
    this.allowRefill = true,
  });

  static bool isBlank(Object? v) =>
      v == null || (v is String && v.trim().isEmpty);

  bool _secret(String field, bool parameter) =>
      (fields == null ? credential(field) : fields!.contains(field)) ||
      (legacyKey && !parameter && (field == 'key' || field == 'embedding_key'));

  bool _parameter(Map<dynamic, dynamic> value) =>
      value['key'] is String &&
      credential(value['key'] as String) &&
      value.containsKey('value');

  bool _endpoint(Object? key) =>
      endpoints &&
      const {
        'endpoint',
        'embedding_endpoint',
        'embeddingEndpoint',
        'generationEndpoint',
        'customEndpoint',
      }.contains(key);

  Object? strip(Object? value) {
    if (value is String) return _mapJson(value, strip);
    if (value is Map) {
      final parameter = _parameter(value);
      return {
        for (final e in value.entries)
          e.key:
              e.key is String &&
                  (_secret(e.key as String, parameter) ||
                      (parameter && e.key == 'value'))
              ? (e.value is String ? '' : null)
              : _endpoint(e.key) && e.value is String
              ? BackupSecretUrls.strip(e.value as String, credential)
              : (fields == null && children.isEmpty) || children.contains(e.key)
              ? strip(e.value)
              : e.value,
      };
    }
    if (value is List) return value.map(strip).toList();
    return value;
  }

  // Strong identities only: never transfer credentials by list index or name.
  static const _identityFields = [
    'id',
    'profileId',
    'profile_id',
    'configId',
    'config_id',
    'accountId',
    'account_id',
    'userId',
    'user_id',
  ];
  static const _accountFields = [
    'username',
    'userName',
    'email',
    'providerId',
    'provider_id',
  ];

  static Object? _document(Object? v) => v is String ? _decode(v) ?? v : v;

  bool _sameOwner(Map<dynamic, dynamic> backup, Map<dynamic, dynamic> local) {
    for (final field in [..._identityFields, ..._accountFields]) {
      if (!isBlank(backup[field]) || !isBlank(local[field])) {
        if (backup[field] != local[field]) return false;
      }
    }
    for (final e in backup.entries) {
      if (_endpoint(e.key) &&
          e.value is String &&
          local[e.key] is String &&
          e.value != local[e.key] &&
          !BackupSecretUrls.sameDestination(
            e.value as String,
            local[e.key] as String,
            credential,
          )) {
        return false;
      }
    }
    return true;
  }

  Object? _listMatch(
    Object? backup,
    List<dynamic> local,
    List<dynamic> siblings,
  ) {
    final b = _document(backup);
    if (b is! Map) return null;
    final identity = _identityFields.where((f) => !isBlank(b[f])).toList();
    // Named extra request parameters are not account/profile list slots.
    if (identity.isEmpty && _parameter(b)) identity.add('key');
    if (identity.isEmpty) return null;
    bool matches(Object? candidate) {
      final c = _document(candidate);
      return c is Map && identity.every((f) => c[f] == b[f]);
    }

    if (siblings.where(matches).length != 1) return null;
    final candidates = local.where(matches).toList();
    return candidates.length == 1 ? candidates.single : null;
  }

  Object? refill(Object? backup, Object? local) {
    if (backup is String) {
      return _mapJson(backup, (b) => refill(b, _document(local)));
    }
    if (backup is Map && local is Map) {
      if (!_sameOwner(backup, local)) return backup;
      final parameter = _parameter(backup);
      return {
        for (final e in backup.entries)
          e.key:
              e.key is String &&
                  (_secret(e.key as String, parameter) ||
                      (parameter && e.key == 'value'))
              ? (allowRefill &&
                        _credentialRoute(e.key.toString(), backup, local) &&
                        isBlank(e.value)
                    ? local[e.key] ?? e.value
                    : e.value)
              : _endpoint(e.key) && e.value is String && local[e.key] is String
              ? BackupSecretUrls.refill(
                  e.value as String,
                  local[e.key] as String,
                  credential,
                )
              : (fields == null && children.isEmpty) || children.contains(e.key)
              ? refill(e.value, local[e.key])
              : e.value,
      };
    }
    if (backup is List && local is List) {
      return [for (final v in backup) refill(v, _listMatch(v, local, backup))];
    }
    return backup;
  }

  bool _credentialRoute(
    String field,
    Map<dynamic, dynamic> b,
    Map<dynamic, dynamic> l,
  ) {
    if (!endpoints) return false;
    if (field == 'embedding_key' || field == 'embeddingApiKey') {
      if (b['embedding_use_same'] != l['embedding_use_same']) return false;
    }
    final endpoint = field == 'embedding_key' || field == 'embeddingApiKey'
        ? (b.containsKey('embedding_endpoint')
              ? 'embedding_endpoint'
              : 'endpoint')
        : field == 'generationApiKey'
        ? 'generationEndpoint'
        : field == 'customApiKey'
        ? 'customEndpoint'
        : 'endpoint';
    return b[endpoint] is String &&
        l[endpoint] is String &&
        (b[endpoint] as String).isNotEmpty &&
        BackupSecretUrls.sameDestination(
          b[endpoint] as String,
          l[endpoint] as String,
          credential,
        );
  }

  static String _mapJson(String raw, Object? Function(Object?) transform) {
    final decoded = _decode(raw);
    if (decoded == null) return raw;
    final encoded = jsonEncode(transform(decoded));
    return encoded == jsonEncode(decoded) ? raw : encoded;
  }

  static Object? _decode(String raw) {
    final s = raw.trimLeft();
    if (!s.startsWith('{') && !s.startsWith('[')) return null;
    try {
      final decoded = jsonDecode(s);
      return decoded is Map || decoded is List ? decoded : null;
    } on FormatException {
      return null;
    }
  }
}
