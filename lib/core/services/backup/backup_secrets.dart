import 'backup_secret_urls.dart';
import 'backup_secret_runtime.dart';
import 'backup_secret_preferences.dart';
import 'backup_secret_routes.dart';
import 'backup_secret_containers.dart';
import 'backup_secret_memory_history.dart';

/// Credential filtering for shareable backups, not a general content scrubber.
abstract final class BackupSecrets {
  static const includeApiKeysPrefKey = 'gz_backup_include_api_keys';
  static const manifestFlag = 'apiKeysIncluded';

  /// Includes legacy preferences still accepted by Astoria's import/migration
  /// paths. DataCat's device id is not secret, but must stay with its local token.
  static const prefKeys = {
    'gz_sync_tokens',
    'gz_chub_api_key',
    'gz_dc_device',
    'gz_dc_token',
    'gz_dc_user_token',
    'gz_saucepan_token',
    'gz_janny_token',
    'gz_cf_clearance_janitor',
    'gz_embedding_key',
    'gz_imggen_api_key',
    'gz_imggen_naistera_api_key',
    'gz_imggen_routmy_api_key',
    'api-key',
  };

  static const tableColumns = {
    'api_configs': ['api_key', 'embedding_api_key'],
  };
  static const tableJsonColumns = {
    'api_configs': ['extra_request_parameters_json'],
  };
  static const tableUrlColumns = {
    'api_configs': ['endpoint', 'embedding_endpoint'],
  };
  static const tableIdentityColumns = {
    'api_configs': 'config_id',
    'studio_preset_rows': 'preset_id',
  };

  // Old connection profiles used `key` for their API key. Do not interpret
  // arbitrary lore/regex/global-variable `key` fields as credentials.
  static const _plainEndpointPrefs = {
    'gz_imggen_endpoint',
    'gz_embedding_endpoint',
    'api-endpoint',
  };
  static const _secretNames = {
    'accesstoken',
    'refreshtoken',
    'idtoken',
    'authtoken',
    'sessiontoken',
    'usertoken',
    'devicetoken',
    'token',
    'password',
    'secret',
    'clientsecret',
    'authorization',
    'proxyauthorization',
    'cookie',
    'setcookie',
    'xauthtoken',
    'authentication',
    'bearertoken',
    'clientsecretkey',
  };
  static final _normalizer = RegExp(r'[^a-z0-9]');

  static bool isSecretField(String name) {
    final n = name.toLowerCase().replaceAll(_normalizer, '');
    return n.endsWith('apikey') || _secretNames.contains(n);
  }

  static bool isSecretPref(String key) => prefKeys.contains(key);

  static Map<String, dynamic> stripRow(
    String tableName,
    Map<String, dynamic> row,
  ) => {
    ...row,
    for (final column in tableColumns[tableName] ?? const <String>[])
      if (row.containsKey(column)) column: '',
    for (final column in tableJsonColumns[tableName] ?? const <String>[])
      if (row.containsKey(column))
        column: BackupSecretRuntime.stripParameters(row[column], isSecretField),
    for (final column in tableUrlColumns[tableName] ?? const <String>[])
      if (row[column] is String)
        column: BackupSecretUrls.strip(row[column] as String, isSecretField),
    if (tableName == 'studio_preset_rows' &&
        row.containsKey('runtime_settings_json'))
      'runtime_settings_json': BackupSecretRuntime.transformStudio(
        row['runtime_settings_json'],
        (value) => BackupSecretRuntime.stripParameters(value, isSecretField),
      ),
    if (tableName == 'memory_book_rows' && row.containsKey('settings_json'))
      'settings_json': BackupSecretMemoryHistory.strip(
        row['settings_json'],
        isSecretField,
      ),
  };

  static Map<String, dynamic> refillRow(
    String tableName,
    Map<String, dynamic> backup,
    Map<String, dynamic>? local, {
    bool embeddingRouteMatches = false,
    bool cleanerRouteMatches = false,
  }) => {
    ...backup,
    for (final column in tableColumns[tableName] ?? const <String>[])
      if (BackupSecretPreferences.isBlank(backup[column]) &&
          local?[column] != null &&
          (column == 'embedding_api_key'
              ? embeddingRouteMatches &&
                    !BackupSecretRoutes.flag(
                      backup['embedding_use_same'],
                      true,
                    ) &&
                    !BackupSecretRoutes.flag(
                      local?['embedding_use_same'],
                      true,
                    ) &&
                    backup['embedding_endpoint'] is String &&
                    (backup['embedding_endpoint'] as String).isNotEmpty
              : BackupSecretRoutes.sameLlm(backup, local, isSecretField)))
        column: local![column],
    for (final column in tableJsonColumns[tableName] ?? const <String>[])
      if (backup.containsKey(column))
        column: BackupSecretRuntime.refillParameters(
          backup[column],
          BackupSecretRoutes.sameLlm(backup, local, isSecretField)
              ? (local?[column])
              : null,
          isSecretField,
        ),
    for (final column in tableUrlColumns[tableName] ?? const <String>[])
      if (backup[column] is String && local?[column] is String)
        column: BackupSecretUrls.refill(
          backup[column] as String,
          local![column] as String,
          isSecretField,
        ),
    if (tableName == 'studio_preset_rows' &&
        backup.containsKey('runtime_settings_json'))
      'runtime_settings_json': BackupSecretRuntime.transformStudio(
        backup['runtime_settings_json'],
        (value) => BackupSecretRuntime.refillParameters(
          value,
          cleanerRouteMatches ? (local?['cleaner_parameters']) : null,
          isSecretField,
        ),
      ),
  };

  static Map<String, dynamic> stripPrefs(Map<String, dynamic> prefs) => {
    for (final entry in prefs.entries)
      if (!isSecretPref(entry.key))
        entry.key:
            _plainEndpointPrefs.contains(entry.key) && entry.value is String
            ? BackupSecretUrls.strip(entry.value as String, isSecretField)
            : BackupSecretContainers.preference(
                entry.key,
                entry.value,
                null,
                isSecretField,
                refill: false,
              ),
  };

  static Object? refillPref(Object? backup, Object? local, {String? key}) =>
      _plainEndpointPrefs.contains(key) && backup is String && local is String
      ? BackupSecretUrls.refill(backup, local, isSecretField)
      : BackupSecretContainers.preference(
          key ?? '',
          backup,
          local,
          isSecretField,
          refill: true,
        );

  /// Keep named credential parameters only in local restore snapshots.
  static Object? snapshotParameters(Object? raw) =>
      BackupSecretRuntime.snapshotParameters(raw, isSecretField);
}
