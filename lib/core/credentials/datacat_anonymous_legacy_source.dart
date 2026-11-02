import 'package:shared_preferences/shared_preferences.dart';

import '../preferences/saved_preferences_owner.dart';
import '../preferences/tracked_shared_preferences.dart';
import 'credential_slot.dart';
import 'credential_vault.dart';
import 'datacat_anonymous_preferences.dart';
import 'datacat_installation_owner.dart';
import 'secret_redaction_coordinator.dart';

/// Original pre-await anonymous producer. Copies exact bytes, never deletes,
/// adopts a linked user token, reloads, or renews a retired source lease.
final class DatacatAnonymousLegacySource {
  DatacatAnonymousLegacySource(Future<SharedPreferences> original)
    : _original = original,
      _lease = DatacatAnonymousPreferences.capture([
        DatacatAnonymousPreferences.token,
      ]);

  final Future<SharedPreferences> _original;
  final SavedPreferencesLease? _lease;

  Future<void> importIfAbsent({
    required CredentialVault vault,
    required CredentialSlot slot,
    required SecretRedactionCoordinator redaction,
    required bool Function() isCurrent,
  }) => DatacatAnonymousPreferences.serialize(() async {
    void check() => DatacatAnonymousPreferences.check(_lease, isCurrent);
    try {
      check();
      final prefs = await _original;
      check();
      if (prefs is! TrackedSharedPreferences ||
          !_lease!.bindOriginalStore(prefs.store)) {
        throw const CredentialVaultAdmissionDenied();
      }
      final raw = prefs.getString(DatacatAnonymousPreferences.token);
      check();
      if (raw == null) return;
      redaction.registerSecret(raw);
      // Vault absence-read/write/readback stays inside the CENTRAL source FIFO.
      // Existing protected emptiness is present, and must never be resurrected.
      DatacatInstallationOwner.admitCredentialMutation(vault,
        isCurrent: () => isCurrent() && _lease.current);
      await vault.importIfAbsentGuarded(
        slot,
        raw,
        isCurrent: () => isCurrent() && _lease.current,
      );
      check();
    } on CredentialVaultAdmissionDenied {
      rethrow;
    } on CredentialVaultException {
      check();
      rethrow;
    } catch (_) {
      check();
      throw const CredentialVaultException(
        CredentialVaultFailure.storageUnavailable,
      );
    }
  });
}
