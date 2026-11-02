import 'package:shared_preferences/shared_preferences.dart';

import '../preferences/saved_preferences_owner.dart';
import '../preferences/tracked_shared_preferences.dart';
import 'credential_slot.dart';
import 'credential_vault.dart';
import 'secret_redaction_coordinator.dart';

/// Native-only migration source. Retains the producer BEFORE its first await;
/// never renews a retired lease against a replacement store or fresh lookup.
/// Raw material remains private, outside every saved-data family/read port.
final class ChubLegacyCredentialSource {
  ChubLegacyCredentialSource(Future<SharedPreferences> original)
    : _original = original,
      _lease = _captureOriginal();

  static SavedPreferencesLease _captureOriginal() {
    final owner = SavedPreferencesOwner.process;
    final store = owner.originalStore;
    // A backend already retired BEFORE this producer starts is not its owner.
    // An unbound original ticket may bind its first actual plugin attachment,
    // but keeps the pre-await revisions and never adopts a second attachment.
    return owner.capture([
      PrivatePreferenceKeys.chubApiKey,
    ], store: store?.current == true ? store : null);
  }

  final Future<SharedPreferences> _original;
  final SavedPreferencesLease _lease;

  void _check(bool Function() isCurrent) {
    if (!isCurrent() || !_lease.current) {
      throw const CredentialVaultAdmissionDenied();
    }
  }

  Future<TrackedSharedPreferences> _preferences(
    bool Function() isCurrent,
  ) async {
    _check(isCurrent);
    final prefs = await _original;
    _check(isCurrent);
    if (prefs is! TrackedSharedPreferences ||
        !_lease.bindOriginalStore(prefs.store)) {
      throw const CredentialVaultAdmissionDenied();
    }
    return prefs;
  }

  /// The private key's physical FIFO stays held throughout import. A tracked
  /// backup cannot replace its original material during vault read/write/readback.
  /// Native account setters/logout have their own shared family FIFO; a newer
  /// intent fences publication, and any admitted import settles before them.
  Future<void> importIfAbsent({
    required CredentialVault vault,
    required CredentialSlot slot,
    required SecretRedactionCoordinator redaction,
    required bool Function() isCurrent,
  }) => SavedPreferencesWrites.serializeChub(() async {
    final prefs = await _preferences(isCurrent);
    final raw = prefs.getString(PrivatePreferenceKeys.chubApiKey);
    _check(isCurrent);
    if (raw == null) return;
    redaction.registerSecret(raw);
    // No normalization: empty/whitespace legacy values keep their old meaning.
    // The vault's atomic absent check preserves any existing/native empty value.
    await vault.importIfAbsentGuarded(
      slot,
      raw,
      isCurrent: () => isCurrent() && _lease.current,
    );
    _check(isCurrent);
    // Deliberately NO legacy remove here, even after a verified import.
  });

  /// Source support for a future explicit native user decision, not migration
  /// cleanup. False means refused/unproved retirement, never permission to retry
  /// against a new revision. Both original source and exact vault copy must hold.
  Future<bool> retireWithNativeConsent({
    required bool confirmed,
    required CredentialVault vault,
    required CredentialSlot slot,
    required SecretRedactionCoordinator redaction,
    required bool Function() isCurrent,
  }) async {
    if (!confirmed) return false;
    try {
      final prefs = await _preferences(isCurrent);
      final raw = prefs.getString(PrivatePreferenceKeys.chubApiKey);
      _check(isCurrent);
      if (raw == null) return false;
      redaction.registerSecret(raw);
      var exact = false;
      if (raw.isEmpty) {
        exact =
            await vault.hasStoredValue(slot) &&
            !(await vault.metadata(slot)).configured;
      } else {
        await vault.useSecret(slot, (actual) async {
          redaction.registerSecret(actual);
          exact = actual == raw;
        });
      }
      _check(isCurrent);
      if (!exact) return false;
      return await prefs.retireChubApiKey(
        expectedRaw: raw,
        expected: _lease,
        isCurrent: isCurrent,
      );
    } catch (_) {
      return false;
    }
  }
}
