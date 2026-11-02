import 'dart:convert';

import 'backup_secret_urls.dart';

/// v48 retained these original pipeline credentials in Memory book settings.
/// They are not current Memory consumers, but raw table export still carries them.
/// Filter only their audited top-level paths; entry prose and unknown nested
/// content remain inert. No local row or legacy material is changed or refilled.
abstract final class BackupSecretMemoryHistory {
  static const _keys = {
    'generationApiKey',
    'auxApiKey',
    'sidecarApiKey',
    'postCleanerApiKey',
    'consolidationApiKey',
  };
  static const _endpoints = {
    'generationEndpoint',
    'auxEndpoint',
    'sidecarEndpoint',
    'postCleanerEndpoint',
    'consolidationEndpoint',
  };

  static Object? strip(Object? raw, bool Function(String) credential) {
    if (raw == null) return null;
    Object? document = raw;
    if (raw is String) {
      try {
        document = jsonDecode(raw);
      } on FormatException {
        // This credential-bearing column cannot be selectively attested when
        // malformed. Omit its settings in a keyless export, not in the database.
        return '{}';
      }
    }
    if (document is! Map) return raw is String ? '{}' : <String, Object?>{};
    final safe = <Object?, Object?>{
      for (final entry in document.entries)
        entry.key: _keys.contains(entry.key)
            ? ''
            : _endpoints.contains(entry.key) && entry.value is String
            ? BackupSecretUrls.strip(entry.value as String, credential)
            : entry.value,
    };
    if (raw is! String) return safe;
    return jsonEncode(safe) == jsonEncode(document) ? raw : jsonEncode(safe);
  }
}
