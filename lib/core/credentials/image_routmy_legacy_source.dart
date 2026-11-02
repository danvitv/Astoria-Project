import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../preferences/saved_preferences_owner.dart';
import '../preferences/tracked_shared_preferences.dart';
import 'credential_slot.dart';
import 'credential_vault.dart';
import 'secret_redaction_coordinator.dart';

/// Original native image settings producer. No cleanup, saved-data read port,
/// shared-LLM key import, or arbitrary endpoint transfer is exposed here.
final class ImageRoutmyLegacySource {
  ImageRoutmyLegacySource(Future<SharedPreferences> original)
    : _original = original,
      _custody = _capture(const []),
      _legacy = _capture(keys);

  static const settingsKey = 'gz_imggen_settings';
  static const standaloneKey = 'gz_imggen_routmy_api_key';
  static const keys = {settingsKey, standaloneKey};
  static const credentialFields = {'routmyApiKey', 'ruRoutmyApiKey'};
  final Future<SharedPreferences> _original;
  final SavedPreferencesLease? _custody, _legacy;

  /// Original producer lifetime only, not permission to read changed keys.
  bool get current => _custody?.current == true;

  static SavedPreferencesLease? _capture(Iterable<String> keys) {
    // Parent composition must track these exact native sources. Missing hooks
    // refuse admission rather than silently claiming untracked revisions.
    if (!keys.every(PrivatePreferenceKeys.tracked.contains)) return null;
    final owner = SavedPreferencesOwner.process;
    final store = owner.originalStore;
    return owner.capture(keys, store: store?.current == true ? store : null);
  }

  void _check(SavedPreferencesLease? lease, bool Function() current) {
    if (!current() || lease?.current != true || _custody?.current != true) {
      throw const CredentialVaultAdmissionDenied();
    }
  }

  SavedPreferencesLease? captureSettings() {
    if (_custody?.current != true) return null;
    return _capture(const [settingsKey]);
  }

  SavedPreferencesLease? captureCredential() {
    if (_custody?.current != true) return null;
    return _capture(keys);
  }

  Future<TrackedSharedPreferences> preferences(
    SavedPreferencesLease? lease,
    bool Function() current,
  ) async {
    _check(lease, current);
    final prefs = await _original;
    _check(lease, current);
    if (prefs is! TrackedSharedPreferences ||
        !_custody!.bindOriginalStore(prefs.store) ||
        !lease!.bindOriginalStore(prefs.store)) {
      throw const CredentialVaultAdmissionDenied();
    }
    return prefs;
  }

  static Map<String, dynamic>? decode(Object? raw) {
    if (raw == null) return null;
    if (raw is! String) throw const CredentialVaultAdmissionDenied();
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) return json;
    } catch (_) {}
    throw const CredentialVaultAdmissionDenied();
  }

  /// Finite precedence mirrors the native codec: current JSON field, RU field
  /// only for retired ruRoutmy settings, then standalone. Native-codec RU
  /// fallback is preserved when its current field is empty. Otherwise a
  /// present empty JSON value wins over a historic standalone key;
  /// corrupt/incorrectly typed higher-priority material is never skipped.
  static String? candidate(Map<String, dynamic>? json, Object? standalone) {
    String? current, ru;
    if (json?.containsKey('routmyApiKey') == true) {
      final value = json!['routmyApiKey'];
      if (value is! String) throw const CredentialVaultAdmissionDenied();
      current = value;
      if (current.isNotEmpty) return current;
    }
    if (json?['apiType'] == 'ruRoutmy' &&
        json?.containsKey('ruRoutmyApiKey') == true) {
      final value = json!['ruRoutmyApiKey'];
      if (value is! String) throw const CredentialVaultAdmissionDenied();
      ru = value;
      if (ru.isNotEmpty) return ru;
    }
    if (current != null) return current;
    if (ru != null) return ru;
    if (standalone != null && standalone is! String) {
      throw const CredentialVaultAdmissionDenied();
    }
    return standalone as String?;
  }

  Future<void> importIfAbsent({
    required CredentialVault vault,
    required CredentialSlot slot,
    required SecretRedactionCoordinator redaction,
    required bool Function() isCurrent,
  }) => SavedPreferencesWrites.serializeImageRoutmy(() async {
    final prefs = await preferences(_legacy, isCurrent);
    final json = decode(prefs.get(settingsKey));
    for (final field in credentialFields) {
      final value = json?[field];
      if (value is String) redaction.registerSecret(value);
    }
    final standalone = prefs.get(standaloneKey);
    if (standalone is String) redaction.registerSecret(standalone);
    final raw = candidate(json, standalone);
    _check(_legacy, isCurrent);
    if (raw == null) return;
    await vault.importIfAbsentGuarded(
      slot,
      raw,
      isCurrent: () => isCurrent() && _legacy!.current && _custody!.current,
    );
    _check(_legacy, isCurrent);
    // Retain both JSON fields and the standalone key, including empty values.
  });

  /// Native ordinary settings only. The caller supplies NO rout.my credential;
  /// merge under the source FIFO retains both legacy fields verbatim, all
  /// unknown fields, and unknown nested provider settings. No whole-key generic
  /// CAS/read projection is granted credential mutation privileges.
  Future<void> saveSettings(
    Map<String, dynamic> ordinary, {
    required bool Function() isCurrent,
  }) {
    late final Map<String, dynamic> admitted;
    try {
      admitted = jsonDecode(jsonEncode(ordinary)) as Map<String, dynamic>;
    } catch (_) {
      throw const CredentialVaultAdmissionDenied();
    }
    // OpenRouter and NovelAI have exact destination/credential admission. Even a
    // trusted direct caller cannot bypass it through this older native helper.
    if (admitted.keys.any(credentialFields.contains) ||
        admitted.containsKey('naisteraApiKey') ||
        admitted.containsKey('openrouter') ||
        admitted.containsKey('novelai')) {
      throw const CredentialVaultAdmissionDenied();
    }
    final lease = captureSettings(); // Original revisions before queue/await.
    return SavedPreferencesWrites.serializeImageRoutmy(() async {
      final prefs = await preferences(lease, isCurrent);
      final raw = prefs.get(settingsKey);
      final preserved = decode(raw) ?? <String, dynamic>{};
      final value = jsonEncode(_merge(preserved, admitted));
      _check(lease, isCurrent);
      final admission = prefs.store.owner.beginConditional(
        lease!,
        prefs.store,
        settingsKey,
      );
      if (admission == null) throw const CredentialVaultAdmissionDenied();
      var accepted = false;
      SavedPreferencesLease? receipt;
      try {
        if (!isCurrent() ||
            !admission.current ||
            prefs.get(settingsKey) != raw) {
          throw const CredentialVaultAdmissionDenied();
        }
        // Already inside the original physical FIFO. Reentering facade setters
        // would deadlock. Readback/acknowledgement settles on this same producer.
        accepted = await prefs.delegate.setString(settingsKey, value);
      } catch (_) {
        // Neither JSON, original credentials nor arbitrary plugin errors leave.
      } finally {
        receipt = admission.finish(accepted);
      }
      if (!accepted ||
          !isCurrent() ||
          receipt?.current != true ||
          prefs.get(settingsKey) != value) {
        throw const CredentialVaultAdmissionDenied();
      }
    });
  }

  static Map<String, dynamic> _merge(
    Map<String, dynamic> original,
    Map<String, dynamic> updates,
  ) => {
    ...original,
    for (final entry in updates.entries)
      entry.key:
          original[entry.key] is Map<String, dynamic> &&
              entry.value is Map<String, dynamic>
          ? _merge(
              original[entry.key] as Map<String, dynamic>,
              entry.value as Map<String, dynamic>,
            )
          : entry.value,
  };
}
