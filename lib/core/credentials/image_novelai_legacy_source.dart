import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../preferences/saved_preferences_owner.dart';
import '../preferences/tracked_shared_preferences.dart';
import 'credential_slot.dart';
import 'credential_vault.dart';
import 'image_novelai_destinations.dart';
import 'image_openrouter_legacy_source.dart';
import 'secret_redaction_coordinator.dart';

/// Only the original nested image document is a legacy NovelAI key source.
final class ImageNovelAiLegacySource {
  ImageNovelAiLegacySource(Future<SharedPreferences> original)
    : _original = original,
      _custody = _capture(const []),
      _legacy = _capture(const [settingsKey]);

  static const settingsKey = 'gz_imggen_settings';
  final Future<SharedPreferences> _original;
  final SavedPreferencesLease _custody, _legacy;

  static SavedPreferencesLease _capture(Iterable<String> keys) {
    final owner = SavedPreferencesOwner.process;
    final store = owner.originalStore;
    return owner.capture(keys, store: store?.current == true ? store : null);
  }

  bool get current => _custody.current;
  SavedPreferencesLease captureSettings() {
    final lease = _custody.owner.capture(const [
      settingsKey,
    ], store: _custody.store);
    if (!current) lease.retire();
    return lease;
  }

  Future<TrackedSharedPreferences> preferences(
    SavedPreferencesLease lease,
    bool Function() isCurrent,
  ) async {
    void check() {
      if (!isCurrent() || !lease.current || !current) {
        throw const CredentialVaultAdmissionDenied();
      }
    }

    check();
    final prefs = await _original;
    check();
    if (prefs is! TrackedSharedPreferences ||
        !_custody.bindOriginalStore(prefs.store) ||
        !lease.bindOriginalStore(prefs.store)) {
      throw const CredentialVaultAdmissionDenied();
    }
    return prefs;
  }

  static Map<String, dynamic> decode(Object? raw) =>
      ImageOpenRouterLegacySource.decode(raw);
  static Map<String, dynamic> config(Map<String, dynamic> root) {
    if (!root.containsKey('novelai')) return <String, dynamic>{};
    final value = root['novelai'];
    if (value is! Map<String, dynamic>)
      throw const CredentialVaultAdmissionDenied();
    return value;
  }

  static String? candidate(Map<String, dynamic> root) {
    final json = config(root);
    if (!json.containsKey('apiKey')) return null;
    final value = json['apiKey'];
    if (value is! String) throw const CredentialVaultAdmissionDenied();
    return value; // Explicit empty is a tombstone; wrong type is not absence.
  }

  static ImageNovelAiDestinations destinations(Map<String, dynamic> root) {
    final json = config(root);
    final endpoint = json.containsKey('endpoint') ? json['endpoint'] : '';
    final model = json.containsKey('model') ? json['model'] : '';
    if (endpoint is! String || model is! String)
      throw const CredentialVaultAdmissionDenied();
    return ImageNovelAiDestinations(endpoint, model);
  }

  static Map<String, dynamic> withoutSecret(Map<String, dynamic> root) => {
    ...root,
    if (root.containsKey('novelai'))
      'novelai': {...config(root)}..remove('apiKey'),
  };

  void registerAliases(
    Map<String, dynamic> root,
    SecretRedactionCoordinator redaction,
  ) {
    final json = root['novelai'];
    if (json is Map && json['apiKey'] is String)
      redaction.registerSecret(json['apiKey'] as String);
  }

  Future<void> importIfAbsent({
    required CredentialVault vault,
    required CredentialSlot slot,
    required SecretRedactionCoordinator redaction,
    required bool Function() isCurrent,
  }) => SavedPreferencesWrites.serializeImageRoutmy(() async {
    final prefs = await preferences(_legacy, isCurrent);
    final root = decode(prefs.get(settingsKey));
    registerAliases(root, redaction);
    final raw = candidate(root);
    if (raw == null) return;
    await vault.importIfAbsentGuarded(
      slot,
      raw.trim().isEmpty ? '' : destinations(root).encode(raw),
      isCurrent: () => isCurrent() && _legacy.current && current,
    );
    if (!isCurrent() || !_legacy.current || !current)
      throw const CredentialVaultAdmissionDenied();
    // No legacy removal or rewriting, even after verified import.
  });

  /// One physical mixed-document write, with both protected route admissions.
  Future<void> saveSettings(
    Map<String, dynamic> patch, {
    required bool Function() isCurrent,
    required Future<bool> Function(bool Function()) hasNativeRecord,
    required Future<bool> Function(bool Function()) hasOpenRouterRecord,
  }) {
    late final Map<String, dynamic> admitted;
    try {
      admitted = jsonDecode(jsonEncode(patch)) as Map<String, dynamic>;
    } catch (_) {
      throw const CredentialVaultAdmissionDenied();
    }
    if (admitted.containsKey('routmyApiKey') ||
        admitted.containsKey('naisteraApiKey') ||
        admitted.containsKey('ruRoutmyApiKey')) {
      throw const CredentialVaultAdmissionDenied();
    }
    for (final family in ['novelai', 'openrouter']) {
      if (admitted.containsKey(family) &&
          (admitted[family] is! Map<String, dynamic> ||
              (admitted[family] as Map).containsKey('apiKey'))) {
        throw const CredentialVaultAdmissionDenied();
      }
    }
    final expected = captureSettings(); // Before FIFO/await, including ABA.
    final store = expected.store;
    if (!isCurrent() || !current || store == null)
      throw const CredentialVaultAdmissionDenied();
    final admission = store.owner.beginConditional(
      expected,
      store,
      settingsKey,
    );
    if (admission == null) throw const CredentialVaultAdmissionDenied();
    return SavedPreferencesWrites.serializeImageRoutmy(() async {
      var accepted = false, acknowledged = false, started = false;
      SavedPreferencesLease? receipt;
      try {
        final prefs = await preferences(
          _custody,
          () => isCurrent() && admission.current,
        );
        final root = decode(prefs.get(settingsKey));
        final updated = _merge(root, admitted);
        final novelai = admitted['novelai'];
        if (novelai is Map &&
            (novelai.containsKey('endpoint') || novelai.containsKey('model')) &&
            !destinations(root).same(destinations(updated)) &&
            candidate(root)?.trim().isNotEmpty == true &&
            !await hasNativeRecord(() => isCurrent() && admission.current)) {
          throw const CredentialVaultAdmissionDenied();
        }
        final openrouter = admitted['openrouter'];
        if (openrouter is Map &&
            openrouter.containsKey('endpoint') &&
            !ImageOpenRouterLegacySource.destinations(
              root,
            ).same(ImageOpenRouterLegacySource.destinations(updated)) &&
            ImageOpenRouterLegacySource.candidate(root)?.trim().isNotEmpty ==
                true &&
            !await hasOpenRouterRecord(
              () => isCurrent() && admission.current,
            )) {
          throw const CredentialVaultAdmissionDenied();
        }
        final value = jsonEncode(updated);
        if (!isCurrent() || !admission.current)
          throw const CredentialVaultAdmissionDenied();
        started = true;
        acknowledged = await prefs.delegate.setString(settingsKey, value);
        accepted = acknowledged && prefs.get(settingsKey) == value;
      } catch (_) {
        // Private JSON/plugin errors stay inside the original producer.
      } finally {
        receipt = started
            ? admission.finish(accepted)
            : admission.finishUnstarted();
      }
      if (!started) throw const CredentialVaultAdmissionDenied();
      if (!accepted)
        throw ImageOpenRouterSettingsWriteUnverified(
          acknowledged: acknowledged,
        );
      if (!isCurrent() || receipt?.current != true)
        throw const ImageOpenRouterSettingsRetiredCommit();
    });
  }

  static Map<String, dynamic> _merge(
    Map<String, dynamic> original,
    Map<String, dynamic> patch,
  ) => {
    ...original,
    for (final entry in patch.entries)
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
