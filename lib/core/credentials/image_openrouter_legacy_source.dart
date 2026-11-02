import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../preferences/saved_preferences_owner.dart';
import '../preferences/tracked_shared_preferences.dart';
import 'credential_slot.dart';
import 'credential_vault.dart';
import 'image_openrouter_destinations.dart';
import 'secret_redaction_coordinator.dart';

/// The original plugin setter ran, but its completion was not verified. Never
/// report this as a pre-admission refusal or retry the write automatically.
final class ImageOpenRouterSettingsWriteUnverified implements Exception {
  const ImageOpenRouterSettingsWriteUnverified({required this.acknowledged});
  final bool acknowledged;

  @override
  String toString() => 'Image settings write completion is unverified';
}

/// The original settings write was acknowledged and read back, but its original
/// publication/receipt retired. This is not proof that no write happened.
final class ImageOpenRouterSettingsRetiredCommit implements Exception {
  const ImageOpenRouterSettingsRetiredCommit();

  @override
  String toString() => 'Image settings were written; publication retired';
}

/// Original native mixed image document. Uses its EXISTING physical FIFO.
/// No public saved-data port, other key source or plaintext cleanup is granted.
final class ImageOpenRouterLegacySource {
  ImageOpenRouterLegacySource(Future<SharedPreferences> original)
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

  static Map<String, dynamic> decode(Object? raw) {
    if (raw == null) return <String, dynamic>{};
    if (raw is String) {
      try {
        final json = jsonDecode(raw);
        if (json is Map<String, dynamic>) return json;
      } catch (_) {}
    }
    throw const CredentialVaultAdmissionDenied();
  }

  static Map<String, dynamic> config(Map<String, dynamic> root) {
    if (!root.containsKey('openrouter')) return <String, dynamic>{};
    final value = root['openrouter'];
    if (value is! Map<String, dynamic>) {
      throw const CredentialVaultAdmissionDenied();
    }
    return value;
  }

  static String? candidate(Map<String, dynamic> root) {
    final json = config(root);
    if (!json.containsKey('apiKey')) return null;
    final value = json['apiKey'];
    if (value is! String) throw const CredentialVaultAdmissionDenied();
    return value; // Present empty wins; wrong type is never absence.
  }

  static ImageOpenRouterDestinations destinations(Map<String, dynamic> root) {
    final json = config(root);
    final endpoint = json.containsKey('endpoint') ? json['endpoint'] : '';
    if (endpoint is! String) throw const CredentialVaultAdmissionDenied();
    return ImageOpenRouterDestinations(endpoint);
  }

  static Map<String, dynamic> withoutSecret(Map<String, dynamic> root) => {
    ...root,
    if (root.containsKey('openrouter'))
      'openrouter': {...config(root)}..remove('apiKey'),
  };

  void registerAliases(
    Map<String, dynamic> root,
    SecretRedactionCoordinator redaction,
  ) {
    final json = root['openrouter'];
    if (json is Map && json['apiKey'] is String) {
      redaction.registerSecret(json['apiKey'] as String);
    }
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
    final record = raw.trim().isEmpty ? '' : destinations(root).encode(raw);
    await vault.importIfAbsentGuarded(
      slot,
      record,
      isCurrent: () => isCurrent() && _legacy.current && current,
    );
    if (!isCurrent() || !_legacy.current || !current) {
      throw const CredentialVaultAdmissionDenied();
    }
  });

  /// Native ordinary leaf patch only. Retains unknown/private/other-provider
  /// leaves verbatim. Admission precedes enqueue, including endpoint ABA.
  Future<void> saveSettings(
    Map<String, dynamic> patch, {
    required bool Function() isCurrent,
    required Future<bool> Function(bool Function()) hasNativeRecord,
  }) {
    // Native settings patches are JSON documents. Detach all nested maps/lists
    // BEFORE validation/admission: callers retain no reference to queued input.
    late final Map<String, dynamic> admitted;
    try {
      admitted = jsonDecode(jsonEncode(patch)) as Map<String, dynamic>;
    } catch (_) {
      throw const CredentialVaultAdmissionDenied();
    }
    if (admitted.containsKey('novelai') ||
        admitted.containsKey('naisteraApiKey') ||
        admitted.containsKey('routmyApiKey') ||
        admitted.containsKey('ruRoutmyApiKey') ||
        (admitted.containsKey('openrouter') &&
            (admitted['openrouter'] is! Map<String, dynamic> ||
                (admitted['openrouter'] as Map).containsKey('apiKey')))) {
      throw const CredentialVaultAdmissionDenied();
    }
    final expected = captureSettings();
    final store = expected.store;
    if (!isCurrent() || !current || store == null) {
      throw const CredentialVaultAdmissionDenied();
    }
    final admission = store.owner.beginConditional(
      expected,
      store,
      settingsKey,
    );
    if (admission == null) throw const CredentialVaultAdmissionDenied();
    return SavedPreferencesWrites.serializeImageRoutmy(() async {
      var accepted = false, acknowledged = false, started = false;
      SavedPreferencesLease? receipt;
      String? value;
      try {
        final prefs = await preferences(
          _custody,
          () => isCurrent() && admission.current,
        );
        final root = decode(prefs.get(settingsKey));
        final updated = _merge(root, admitted);
        final endpointPatch = admitted['openrouter'];
        if (endpointPatch is Map && endpointPatch.containsKey('endpoint')) {
          final old = destinations(root);
          final next = destinations(updated);
          if (!old.same(next) &&
              candidate(root)?.trim().isNotEmpty == true &&
              !await hasNativeRecord(() => isCurrent() && admission.current)) {
            throw const CredentialVaultAdmissionDenied();
          }
        }
        value = jsonEncode(updated);
        if (!isCurrent() || !admission.current) {
          throw const CredentialVaultAdmissionDenied();
        }
        started = true;
        acknowledged = await prefs.delegate.setString(settingsKey, value);
        accepted = acknowledged && prefs.get(settingsKey) == value;
      } catch (_) {
        // Arbitrary plugin errors and raw private JSON never leave this source.
      } finally {
        receipt = started
            ? admission.finish(accepted)
            : admission.finishUnstarted();
      }
      if (!started) {
        throw const CredentialVaultAdmissionDenied();
      }
      if (!accepted) {
        throw ImageOpenRouterSettingsWriteUnverified(
          acknowledged: acknowledged,
        );
      }
      if (!isCurrent() || receipt?.current != true) {
        throw const ImageOpenRouterSettingsRetiredCommit();
      }
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
