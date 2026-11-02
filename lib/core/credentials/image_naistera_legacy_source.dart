import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../preferences/saved_preferences_owner.dart';
import '../preferences/tracked_shared_preferences.dart';
import 'credential_slot.dart';
import 'credential_vault.dart';
import 'image_naistera_destinations.dart';
import 'image_novelai_legacy_source.dart';
import 'secret_redaction_coordinator.dart';

/// Sole native flat key; standalone is eligible ONLY when the whole document
/// is absent and the original JS api-type selector exists. No cross-key refill.
final class ImageNaisteraLegacySource {
  ImageNaisteraLegacySource(Future<SharedPreferences> original)
    : _original = original,
      _custody = _capture(const []),
      _legacy = _capture(keys);
  static const settingsKey = 'gz_imggen_settings';
  static const standaloneKey = 'gz_imggen_naistera_api_key';
  static const apiTypeKey = 'gz_imggen_api_type';
  static const keys = {settingsKey, standaloneKey};
  final Future<SharedPreferences> _original;
  final SavedPreferencesLease _custody, _legacy;
  static SavedPreferencesLease _capture(Iterable<String> keys) {
    final owner = SavedPreferencesOwner.process;
    final store = owner.originalStore;
    return owner.capture(keys, store: store?.current == true ? store : null);
  }

  bool get current => _custody.current;
  SavedPreferencesLease captureSettings() {
    final lease = _custody.owner.capture(keys, store: _custody.store);
    if (!current) lease.retire();
    return lease;
  }

  Future<TrackedSharedPreferences> preferences(
    SavedPreferencesLease lease,
    bool Function() isCurrent,
  ) async {
    void check() {
      if (!current || !lease.current || !isCurrent()) {
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

  static Map<String, dynamic>? decode(Object? raw) {
    if (raw == null) return null;
    if (raw is String) {
      try {
        final root = jsonDecode(raw);
        if (root is Map<String, dynamic>) return root;
      } catch (_) {}
    }
    throw const CredentialVaultAdmissionDenied();
  }

  static String? candidate(
    Map<String, dynamic>? root,
    Object? standalone, {
    required bool apiTypeExists,
  }) {
    if (root != null) {
      final value = root['naisteraApiKey'];
      if (value == null) return ''; // Native codec's missing/null empty value.
      if (value is! String) throw const CredentialVaultAdmissionDenied();
      return value;
    }
    if (!apiTypeExists) return null;
    if (standalone != null && standalone is! String) {
      throw const CredentialVaultAdmissionDenied();
    }
    return standalone as String? ?? '';
  }

  static Map<String, dynamic> withoutSecret(Map<String, dynamic> root) =>
      {...root}..remove('naisteraApiKey');
  static String model(TrackedSharedPreferences prefs) {
    final root = decode(prefs.get(settingsKey));
    final raw = root == null
        ? (prefs.containsKey(apiTypeKey)
              ? prefs.get('gz_imggen_naistera_model')
              : null)
        : root['naisteraModel'];
    if (raw != null && raw is! String)
      throw const CredentialVaultAdmissionDenied();
    return raw as String? ?? 'grok';
  }

  void registerAliases(
    TrackedSharedPreferences prefs,
    SecretRedactionCoordinator redaction,
  ) {
    final root = decode(prefs.get(settingsKey));
    for (final value in [root?['naisteraApiKey'], prefs.get(standaloneKey)]) {
      if (value is String) redaction.registerSecret(value);
    }
  }

  Future<void> importIfAbsent({
    required CredentialVault vault,
    required CredentialSlot slot,
    required SecretRedactionCoordinator redaction,
    required ImageNaisteraDestinations destinations,
    required bool Function() isCurrent,
  }) => SavedPreferencesWrites.serializeImageRoutmy(() async {
    final prefs = await preferences(_legacy, isCurrent);
    registerAliases(prefs, redaction);
    final raw = candidate(
      decode(prefs.get(settingsKey)),
      prefs.get(standaloneKey),
      apiTypeExists: prefs.containsKey(apiTypeKey),
    );
    if (raw == null) return;
    await vault.importIfAbsentGuarded(
      slot,
      raw.trim().isEmpty ? '' : destinations.encode(raw),
      isCurrent: () => current && _legacy.current && isCurrent(),
    );
    if (!current || !_legacy.current || !isCurrent()) {
      throw const CredentialVaultAdmissionDenied();
    }
  });

  /// Same physical mixed-document producer, delegated to the accepted narrow
  /// merge/CAS implementation after excluding Naistera's private leaf ourselves.
  Future<void> saveSettings(
    Map<String, dynamic> patch, {
    required bool Function() isCurrent,
    required Future<bool> Function(bool Function()) hasNovelAiRecord,
    required Future<bool> Function(bool Function()) hasOpenRouterRecord,
  }) {
    late final Map<String, dynamic> admitted;
    try {
      admitted = jsonDecode(jsonEncode(patch)) as Map<String, dynamic>;
    } catch (_) {
      throw const CredentialVaultAdmissionDenied();
    }
    if (admitted.containsKey('naisteraApiKey')) {
      throw const CredentialVaultAdmissionDenied();
    }
    if (!current || !isCurrent()) throw const CredentialVaultAdmissionDenied();
    // The accepted delegate owns its issued mixed-document CAS revision. Only
    // the separate standalone source lease belongs in the external callback;
    // retaining the old mixed revision there would deny our own admitted write.
    final original = _custody.owner.capture(const [
      standaloneKey,
    ], store: _custody.store);
    return ImageNovelAiLegacySource(_original).saveSettings(
      admitted,
      isCurrent: () => current && original.current && isCurrent(),
      hasNativeRecord: hasNovelAiRecord,
      hasOpenRouterRecord: hasOpenRouterRecord,
    );
  }
}
