import 'package:shared_preferences/shared_preferences.dart';

import '../preferences/saved_preferences_owner.dart';
import '../preferences/tracked_shared_preferences.dart';
import 'credential_slot.dart';
import 'credential_vault.dart';
import 'datacat_account_preferences.dart';
import 'datacat_account_record.dart';
import 'datacat_installation_owner.dart';
import 'secret_redaction_coordinator.dart';

/// Original pre-await producer and exact private pair/metadata revisions.
/// No anonymous token/identify recovery or retirement/cleanup API exists here.
final class DatacatAccountLegacySource {
  DatacatAccountLegacySource(Future<SharedPreferences> original, {
    CredentialVault? vault,
  })
    : _original = original,
      _vault = vault,
      _installation = vault == null ? null : DatacatInstallationOwner(
        vault: vault, originalPreferences: original,
      ),
      _lease = DatacatAccountPreferences.capture(DatacatAccountPreferences.keys.where(
        (key) => vault == null || key != DatacatAccountPreferences.device,
      ));

  final Future<SharedPreferences> _original;
  final CredentialVault? _vault;
  final SavedPreferencesLease? _lease;
  final DatacatInstallationOwner? _installation;

  Future<void> importIfAbsent({
    required CredentialVault vault,
    required CredentialSlot slot,
    required SecretRedactionCoordinator redaction,
    required bool Function() isCurrent,
  }) => DatacatAccountPreferences.serialize(() async {
    bool current() => isCurrent() && (_installation?.current ?? true) &&
        (_vault == null || identical(_vault, vault));
    void check() => DatacatAccountPreferences.check(_lease, current);
    check();
    final prefs = _installation == null ? await _original : await _installation.preferences(current);
    check();
    if (prefs is! TrackedSharedPreferences ||
        !_lease!.bindOriginalStore(prefs.store)) {
      throw const CredentialVaultAdmissionDenied();
    }
    final raw = prefs.getString(DatacatAccountPreferences.token);
    if (raw == null) return;
    redaction.registerSecret(raw);
    final device = prefs.getString(DatacatAccountPreferences.device);
    if (raw.isNotEmpty && (device == null || !DatacatAccountPreferences.validDevice(device))) {
      throw const CredentialVaultException(CredentialVaultFailure.verificationFailed);
    }
    final envelope = raw.isEmpty ? '' : encodeDatacatAccount(
      raw,
      device!,
      name: prefs.getString(DatacatAccountPreferences.name),
      scopes: prefs.getStringList(DatacatAccountPreferences.scopes) ?? const [],
    );
    check();
    // FIFO holds the original source through absence/write/readback. An invoked
    // write settles verification even if later backup intent retires admission.
    DatacatInstallationOwner.admitCredentialMutation(vault,
      isCurrent: () => current() && _lease!.current);
    await vault.importIfAbsentGuarded(
      slot,
      envelope,
      isCurrent: () => current() && _lease!.current,
    );
    check();
  });
}
