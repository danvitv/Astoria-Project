import 'package:shared_preferences/shared_preferences.dart';

import '../preferences/saved_preferences_owner.dart';
import '../preferences/tracked_shared_preferences.dart';
import 'credential_slot.dart';
import 'credential_vault.dart';
import 'secret_redaction_coordinator.dart';

/// Native-only, original pre-await producer. This private key is never a saved
/// application-data family. A retired lease is terminal, including same-value ABA.
final class SaucepanLegacyCredentialSource {
  SaucepanLegacyCredentialSource(Future<SharedPreferences> original)
    : _original = original,
      _lease = _captureOriginal();

  static SavedPreferencesLease _captureOriginal() {
    final owner = SavedPreferencesOwner.process;
    final store = owner.originalStore;
    return owner.capture([
      PrivatePreferenceKeys.saucepanToken,
    ], store: store?.current == true ? store : null);
  }

  final Future<SharedPreferences> _original;
  final SavedPreferencesLease _lease;

  void _check(bool Function() isCurrent) {
    if (!isCurrent() || !_lease.current) {
      throw const CredentialVaultAdmissionDenied();
    }
  }

  /// Holds the private physical FIFO across vault absence-read/write/readback.
  /// Backup intent may retire admission, but cannot overwrite the source mid-copy.
  /// No delete/retirement API or automatic plaintext cleanup is introduced.
  Future<void> importIfAbsent({
    required CredentialVault vault,
    required CredentialSlot slot,
    required SecretRedactionCoordinator redaction,
    required bool Function() isCurrent,
  }) => SavedPreferencesWrites.serializeSaucepan(() async {
    _check(isCurrent);
    final prefs = await _original;
    _check(isCurrent);
    if (prefs is! TrackedSharedPreferences ||
        !_lease.bindOriginalStore(prefs.store)) {
      throw const CredentialVaultAdmissionDenied();
    }
    final raw = prefs.getString(PrivatePreferenceKeys.saucepanToken);
    _check(isCurrent);
    if (raw == null) return;
    redaction.registerSecret(raw);
    // Preserve exact original bytes; existing protected emptiness is a tombstone.
    await vault.importIfAbsentGuarded(
      slot,
      raw,
      isCurrent: () => isCurrent() && _lease.current,
    );
    _check(isCurrent);
  });
}
