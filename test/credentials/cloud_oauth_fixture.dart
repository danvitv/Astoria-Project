import 'package:glaze_flutter/core/credentials/cloud_oauth_credential_owner.dart';
import 'package:glaze_flutter/core/credentials/cloud_oauth_record.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/preferences/tracked_shared_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'fake_credential_storage.dart';

/// Existing mock-plugin/fake-vault pattern; no SDK, browser or native storage.
final class CloudOAuthFixture {
  CloudOAuthFixture._(this.prefs)
    : storage = FakeCredentialStorage(), redaction = SecretRedactionCoordinator() {
    vault = CredentialVault(storage: storage, buildChannel: 'dev');
  }

  final TrackedSharedPreferences prefs;
  final FakeCredentialStorage storage;
  final SecretRedactionCoordinator redaction;
  late final CredentialVault vault;

  static Future<CloudOAuthFixture> create({Map<String, Object> values = const {},
      SharedPreferencesStorePlatform? backing}) async {
    SharedPreferences.setMockInitialValues(values);
    if (backing != null) SharedPreferencesStorePlatform.instance = backing;
    final prefs = await TrackedSharedPreferences.getInstance() as TrackedSharedPreferences;
    return CloudOAuthFixture._(prefs);
  }

  CloudOAuthCredentialOwner owner(CloudOAuthProvider provider,
    {Future<SharedPreferences>? original}) => CloudOAuthCredentialOwner(
      vault: vault, redaction: redaction, provider: provider,
      originalPreferences: original ?? Future.value(prefs));
}

final class CloudOAuthPreferencesBacking extends SharedPreferencesStorePlatform {
  CloudOAuthPreferencesBacking(Map<String, Object> initial)
    : values = {for (final entry in initial.entries) 'flutter.${entry.key}': entry.value};
  final Map<String, Object> values;
  final writes = <String>[];
  Future<void> Function()? beforeSet;
  bool acknowledgement = true;
  Object? setError;
  @override
  Future<Map<String, Object>> getAll() async => Map.of(values);
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    writes.add(key);
    await beforeSet?.call();
    values[key] = value;
    if (setError != null) throw setError!;
    return acknowledgement;
  }
  @override
  Future<bool> remove(String key) async { writes.add(key); values.remove(key); return true; }
  @override
  Future<bool> clear() async { writes.add('*'); values.clear(); return true; }
}
