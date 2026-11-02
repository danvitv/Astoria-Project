import 'package:shared_preferences/shared_preferences.dart';

import '../preferences/saved_preferences_owner.dart';
import '../preferences/tracked_shared_preferences.dart';
import 'credential_slot.dart';
import 'credential_vault.dart';
import 'datacat_account_preferences.dart';
import 'datacat_anonymous_legacy_source.dart';
import 'datacat_anonymous_preferences.dart';
import 'datacat_installation_owner.dart';
import 'secret_redaction_coordinator.dart';

typedef DatacatAnonymousIdentify =
    Future<void> Function(
      String device,
      bool Function() current,
      Future<void> Function(String token) commit,
    );

/// A single original native job. Only its own identify/recovery can advance its
/// admission; an old HTTP completion cannot borrow a newer operation's token.
final class DatacatAnonymousOperation {
  DatacatAnonymousOperation._(this._owner, this._epoch, this._externalCurrent);
  final DatacatAnonymousCredentialOwner _owner;
  final bool Function() _externalCurrent;
  int _epoch;
  bool _retired = false;
  DatacatInstallationWriteUnverified? _deviceWriteUnverified;
  bool get current {
    if (_retired || _deviceWriteUnverified != null) return false;
    try {
      if (!_owner._current(_epoch) || !_externalCurrent()) _retired = true;
    } catch (_) {
      _retired = true;
    }
    return !_retired;
  }

  void check() {
    // Retain only THIS invoked device outcome through the original extractor's
    // error settlement. It grants no current/read/write authority or new lease.
    final unverified = _deviceWriteUnverified;
    if (unverified != null) throw unverified;
    if (!current) throw const CredentialVaultAdmissionDenied();
  }
}

/// Anonymous extraction token only. Device birth belongs to the separate exact
/// original producer; no regeneration, linked token or model-facing authority.
final class DatacatAnonymousCredentialOwner {
  DatacatAnonymousCredentialOwner({
    required CredentialVault vault,
    required SecretRedactionCoordinator redaction,
    required Future<SharedPreferences> originalPreferences,
  }) : _vault = vault,
       _redaction = redaction,
       _binding = DatacatAnonymousPreferences.capture([
         DatacatAnonymousPreferences.token,
       ]),
       _legacy = DatacatAnonymousLegacySource(originalPreferences),
       _admission = _admissions[vault] ??= _AnonymousAdmission() {
    _installation = DatacatInstallationOwner(
      vault: vault,
      originalPreferences: originalPreferences,
    );
    _epoch = _admission.epoch;
  }

  static final _slot = CredentialSlot(
    domain: 'catalog.datacat',
    id: 'anonymous',
  );
  static final _admissions = Expando<_AnonymousAdmission>();
  final CredentialVault _vault;
  final SecretRedactionCoordinator _redaction;
  final SavedPreferencesLease? _binding;
  late final DatacatInstallationOwner _installation;
  final DatacatAnonymousLegacySource _legacy;
  final _AnonymousAdmission _admission;
  int _epoch = 0;
  bool _disposed = false;

  bool _current(int epoch) =>
      !_disposed &&
      epoch == _epoch &&
      epoch == _admission.epoch &&
      _binding?.current == true &&
      _installation.current;

  DatacatAnonymousOperation captureOperation({bool Function()? isCurrent}) =>
      DatacatAnonymousOperation._(this, _epoch, isCurrent ?? () => true);

  void _check(DatacatAnonymousOperation operation) {
    if (!identical(operation._owner, this)) {
      throw const CredentialVaultAdmissionDenied();
    }
    operation.check();
  }

  Future<TrackedSharedPreferences> _prefs(DatacatAnonymousOperation op) async {
    _check(op);
    final prefs = await _installation.preferences(() => op.current);
    _check(op);
    if (!_binding!.bindOriginalStore(prefs.store)) {
      throw const CredentialVaultAdmissionDenied();
    }
    return prefs;
  }

  /// A failed secure read never means absence. Repeating a verified import is
  /// harmless and avoids a cached absence becoming permission after corruption.
  Future<({bool present, bool configured})> _presence(
    DatacatAnonymousOperation op,
  ) async {
    final prefs = await _prefs(op);
    _check(op);
    var present = await _vault.hasStoredValue(_slot);
    _check(op);
    if (present || prefs.containsKey(DatacatAnonymousPreferences.token)) {
      final device = prefs.getString(DatacatAnonymousPreferences.device);
      if (device == null || !DatacatAccountPreferences.validDevice(device)) {
        throw const CredentialVaultException(
          CredentialVaultFailure.verificationFailed,
        );
      }
    }
    if (!present) {
      await _legacy.importIfAbsent(
        vault: _vault,
        slot: _slot,
        redaction: _redaction,
        isCurrent: () => op.current,
      );
      _check(op);
      present = await _vault.hasStoredValue(_slot);
      _check(op);
    }
    final metadata = await _vault.metadata(_slot);
    _check(op);
    return (present: present, configured: metadata.configured);
  }

  /// Admission advances synchronously BEFORE HTTP. Network does not hold the
  /// private FIFO, so a newer original-native identify can retire an old reply.
  Future<void> initialize(
    DatacatAnonymousOperation op,
    DatacatAnonymousIdentify identify,
  ) {
    _check(op);
    op._epoch = _epoch = ++_admission.epoch;
    return _initialize(op, identify);
  }

  Future<void> _initialize(
    DatacatAnonymousOperation op,
    DatacatAnonymousIdentify identify,
  ) async {
    try {
      final presence = await _presence(op);
      _check(op);
      if (presence.present && !presence.configured) {
        throw const CredentialVaultException(CredentialVaultFailure.missing);
      }
      final String device;
      try {
        device = await _installation.initialize(() => op.current);
      } on DatacatInstallationWriteUnverified catch (outcome) {
        // Retain the original installation-issued outcome, not an error from
        // a later identify/consume callback or another anonymous operation.
        op._deviceWriteUnverified = outcome;
        rethrow;
      }
      _check(op);
      var submitted = false, committed = false;
      await identify(device, () => op.current, (token) {
        _redaction.registerSecret(token); // Even stale/failed returned aliases.
        _check(op);
        if (submitted) throw const CredentialVaultAdmissionDenied();
        submitted = true;
        return DatacatAnonymousPreferences.serialize(() async {
          _check(op);
          if (token.isEmpty) {
            throw const CredentialVaultException(
              CredentialVaultFailure.verificationFailed,
            );
          }
          DatacatInstallationOwner.admitCredentialMutation(
            _vault,
            isCurrent: () => op.current,
          );
          await _vault.storeGuarded(_slot, token, isCurrent: () => op.current);
          _check(op);
          committed = true;
        });
      });
      _check(op);
      if (!committed) throw const CredentialVaultAdmissionDenied();
    } on DatacatInstallationWriteUnverified {
      rethrow; // Invoked device uncertainty survives original job retirement.
    } on CredentialVaultAdmissionDenied {
      rethrow;
    } on CredentialVaultException {
      _check(op);
      rethrow;
    } catch (_) {
      _check(op);
      throw const CredentialVaultException(
        CredentialVaultFailure.storageUnavailable,
      );
    }
  }

  Future<T> withToken<T>(
    DatacatAnonymousOperation op,
    DatacatAnonymousIdentify identify,
    Future<T> Function(String token, bool Function() current) consume,
  ) async {
    try {
      final presence = await _presence(op);
      _check(op);
      if (!presence.configured) {
        if (presence.present) {
          throw const CredentialVaultException(CredentialVaultFailure.missing);
        }
        await initialize(op, identify);
        _check(op);
      }
      late T result;
      await _vault.useSecret(_slot, (token) async {
        _check(op);
        _redaction.registerSecret(token);
        result = await consume(token, () => op.current);
        _check(op);
      });
      _check(op);
      return result;
    } on DatacatInstallationWriteUnverified {
      rethrow;
    } on CredentialVaultAdmissionDenied {
      rethrow;
    } on CredentialVaultException {
      _check(op);
      rethrow;
    } catch (_) {
      _check(op); // Retirement survives vault consumer-error wrapping.
      throw const CredentialVaultException(
        CredentialVaultFailure.storageUnavailable,
      );
    }
  }

  void dispose() {
    _disposed = true;
  }
}

final class _AnonymousAdmission {
  int epoch = 0;
}
