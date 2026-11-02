import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/memory_book_api_settings.dart';
import '../preferences/saved_preferences_owner.dart';
import '../preferences/tracked_shared_preferences.dart';
import 'credential_slot.dart';
import 'credential_vault.dart';
import 'secret_redaction_coordinator.dart';

/// Only the original native pipeline document is a current compatibility
/// consumer. Historical memorySettings keys are not an alternate key source.
final class MemoryCustomApiLegacySource {
  MemoryCustomApiLegacySource(Future<SharedPreferences> original)
    : _original = original,
      _custody = _capture(const []),
      _legacy = _capture(const [settingsKey]);

  static const settingsKey = 'pipelineSettings';
  static const partitions = [
    'studioAgent',
    'cleaner',
    'ledger',
    'memoryPipeline',
    'memoryBookApi',
    'cardRewriter',
  ];
  static bool isNested(Map<String, dynamic> root) =>
      partitions.any(root.containsKey);
  final Future<SharedPreferences> _original;
  final SavedPreferencesLease _custody, _legacy;

  static SavedPreferencesLease _capture(Iterable<String> keys) {
    final owner = SavedPreferencesOwner.process;
    final store = owner.originalStore;
    return owner.capture(keys, store: store?.current == true ? store : null);
  }

  bool get current => _custody.current;
  SavedPreferencesLease captureSettings() {
    // The producer retained by this source is never replaced by process.current.
    final lease = _custody.owner.capture(const [
      settingsKey,
    ], store: _custody.store);
    if (!_custody.current) lease.retire();
    return lease;
  }

  Future<TrackedSharedPreferences> preferences(
    SavedPreferencesLease lease,
    bool Function() isCurrent,
  ) async {
    void check() {
      if (!isCurrent() || !lease.current || !_custody.current) {
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
        final value = jsonDecode(raw);
        if (value is Map<String, dynamic>) return value;
      } catch (_) {}
    }
    throw const CredentialVaultAdmissionDenied();
  }

  static Map<String, dynamic> slotJson(Map<String, dynamic> root) {
    if (root.containsKey('memoryBookApi')) {
      final value = root['memoryBookApi'];
      if (value is! Map<String, dynamic>) {
        throw const CredentialVaultAdmissionDenied();
      }
      return value;
    }
    return isNested(root) ? <String, dynamic>{} : root;
  }

  static String? candidate(Map<String, dynamic> root) {
    final slot = slotJson(root);
    if (!slot.containsKey('generationApiKey')) return null;
    final value = slot['generationApiKey'];
    if (value is! String) throw const CredentialVaultAdmissionDenied();
    return value; // A present empty value wins; no historic fallback.
  }

  static MemoryBookApiSettings settings(Map<String, dynamic> root) =>
      MemoryBookApiSettings.fromJson({
        ...slotJson(root),
        'generationApiKey': '',
      });

  /// Provider publication only. The original document stays private/verbatim.
  static Map<String, dynamic> withoutSecret(Map<String, dynamic> root) => {
    ...root,
    if (root.containsKey('generationApiKey')) 'generationApiKey': '',
    if (root.containsKey('memoryBookApi'))
      'memoryBookApi': {...slotJson(root), 'generationApiKey': ''},
  };

  void registerAliases(
    Map<String, dynamic> root,
    SecretRedactionCoordinator redaction,
  ) {
    // Register before parsing can throw or any secure/queued work begins.
    final flat = root['generationApiKey'];
    if (flat is String) redaction.registerSecret(flat);
    final nested = root['memoryBookApi'];
    if (nested is Map && nested['generationApiKey'] is String) {
      redaction.registerSecret(nested['generationApiKey'] as String);
    }
  }

  Future<void> importIfAbsent({
    required CredentialVault vault,
    required CredentialSlot slot,
    required SecretRedactionCoordinator redaction,
    required bool Function() isCurrent,
    required String Function(String key, MemoryBookApiSettings settings) encode,
  }) => SavedPreferencesWrites.serializeMemoryCustomApi(() async {
    final prefs = await preferences(_legacy, isCurrent);
    final root = decode(prefs.get(settingsKey));
    registerAliases(root, redaction);
    final raw = candidate(root);
    if (raw == null) return;
    final selected = settings(root);
    if (raw.trim().isNotEmpty && selected.generationSource != 'custom') return;
    final record = raw.trim().isEmpty ? '' : encode(raw, selected);
    await vault.importIfAbsentGuarded(
      slot,
      record,
      isCurrent: () => isCurrent() && _legacy.current && _custody.current,
    );
    if (!isCurrent() || !_legacy.current || !_custody.current) {
      throw const CredentialVaultAdmissionDenied();
    }
    // Never clean up, regenerate or write the legacy JSON here.
  });

  /// Original native pipeline leaf patch, not a saved-read credential writer. Its
  /// conditional admission starts synchronously BEFORE enqueue/first await.
  /// Unknown fields and the raw legacy key survive ordinary edits verbatim.
  Future<MemoryCustomApiSavedSettings> savePipeline(
    Map<String, dynamic> patch, {
    required bool Function() isCurrent,
    Future<bool> Function(bool Function() isCurrent)? hasNativeRecord,
  }) {
    _denySecretPatch(patch);
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
    return SavedPreferencesWrites.serializeMemoryCustomApi(() async {
      var accepted = false, started = false;
      SavedPreferencesLease? receipt;
      String? value;
      try {
        final prefs = await preferences(
          _custody,
          () => isCurrent() && admission.current,
        );
        final original = decode(prefs.get(settingsKey));
        final previousSlot = slotJson(original);
        final changedSlot = patch['memoryBookApi'];
        final changesDestination =
            changedSlot is Map &&
            const ['generationEndpoint', 'generationSource'].any(
              (key) =>
                  changedSlot.containsKey(key) &&
                  changedSlot[key] != previousSlot[key],
            );
        if (changesDestination &&
            candidate(original)?.trim().isNotEmpty == true) {
          // Preserve raw legacy leaves, but never let that preservation mint a
          // new destination binding after restart. The user must first explicitly
          // set/clear the key on the old connection, creating a durable record.
          if (hasNativeRecord == null ||
              !await hasNativeRecord(() => isCurrent() && admission.current))
            throw const CredentialVaultAdmissionDenied();
        }
        final updates = Map<String, dynamic>.of(patch);
        // A flat document must be partitioned from the original raw document,
        // not a DTO round-trip. Every raw leaf, including opaque future fields,
        // remains at the root and in its compatibility partition.
        if (!isNested(original)) {
          for (final name in partitions) {
            updates[name] = _merge(
              original,
              updates[name] as Map<String, dynamic>? ?? const {},
            );
          }
        }
        value = jsonEncode(_merge(original, updates));
        if (!isCurrent() || !admission.current) {
          throw const CredentialVaultAdmissionDenied();
        }
        // Already inside the physical FIFO: facade reentry would deadlock.
        started = true;
        accepted = await prefs.delegate.setString(settingsKey, value);
        if (prefs.get(settingsKey) != value) accepted = false;
      } catch (_) {
        // No raw JSON or arbitrary producer exception leaves this owner.
      } finally {
        receipt = started
            ? admission.finish(accepted)
            : admission.finishUnstarted();
      }
      final status = !started
          ? MemoryCustomApiWriteStatus.denied
          : !accepted
          ? MemoryCustomApiWriteStatus.unknown
          : !isCurrent() || receipt?.current != true
          ? MemoryCustomApiWriteStatus.verifiedRetired
          : MemoryCustomApiWriteStatus.verified;
      return MemoryCustomApiSavedSettings(
        status,
        status == MemoryCustomApiWriteStatus.verified && value != null
            ? withoutSecret(decode(value))
            : null,
        receipt,
      );
    });
  }

  static void _denySecretPatch(Map<String, dynamic> patch) {
    for (final entry in patch.entries) {
      if (entry.key == 'generationApiKey') {
        // Even empty is not an ordinary credential setter or cleanup action.
        throw const CredentialVaultAdmissionDenied();
      }
      if (entry.value is Map<String, dynamic>) {
        _denySecretPatch(entry.value as Map<String, dynamic>);
      }
    }
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

final class MemoryCustomApiSavedSettings {
  const MemoryCustomApiSavedSettings(this.status, this.ordinary, this.receipt);
  final MemoryCustomApiWriteStatus status;
  final Map<String, dynamic>? ordinary;
  final SavedPreferencesLease? receipt;
}

enum MemoryCustomApiWriteStatus { denied, unknown, verified, verifiedRetired }

final class MemoryCustomApiWriteException implements Exception {
  const MemoryCustomApiWriteException(this.status);
  final MemoryCustomApiWriteStatus status;
  @override
  String toString() => 'Memory settings write: ${status.name}';
}
