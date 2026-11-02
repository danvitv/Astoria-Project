import 'dart:async';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../preferences/saved_preferences_owner.dart';
import '../preferences/tracked_shared_preferences.dart';
import 'credential_slot.dart';
import 'credential_vault.dart';
import 'datacat_account_preferences.dart';
import 'datacat_anonymous_preferences.dart';

/// The original physical device setter was invoked without a verified success.
/// No commit, rollback, secret, or underlying storage error is claimed here.
final class DatacatInstallationWriteUnverified implements Exception {
  const DatacatInstallationWriteUnverified._();

  @override
  String toString() => 'DataCat installation write outcome is unverified';
}

/// Original native device custody, shared ONLY by the exact injected producer
/// and vault. Another lookup of the same plugin cannot renew this read lease.
/// Construction does not read storage, generate a device, or start HTTP.
final class DatacatInstallationOwner {
  factory DatacatInstallationOwner({
    required CredentialVault vault,
    required Future<SharedPreferences> originalPreferences,
  }) {
    final producers = _originals[vault] ??= Expando<DatacatInstallationOwner>();
    return producers[originalPreferences] ??= DatacatInstallationOwner._(
      vault,
      originalPreferences,
    );
  }

  DatacatInstallationOwner._(CredentialVault vault, this._original)
    : _vault = vault,
      _binding = DatacatAccountPreferences.capture([_key]),
      _credentials = DatacatAccountPreferences.capture([
        ...DatacatAccountPreferences.keys.where((key) => key != _key),
        DatacatAnonymousPreferences.token,
      ]),
      _admission = _admissions[vault] ??= _InstallationAdmission();

  static const _key = DatacatAccountPreferences.device;
  static final _originals = Expando<Expando<DatacatInstallationOwner>>();
  static final _admissions = Expando<_InstallationAdmission>();
  static final _account = CredentialSlot(
    domain: 'catalog.datacat',
    id: 'account',
  );
  static final _anonymous = CredentialSlot(
    domain: 'catalog.datacat',
    id: 'anonymous',
  );
  final CredentialVault _vault;
  final Future<SharedPreferences> _original;
  final SavedPreferencesLease? _credentials;
  final _InstallationAdmission _admission;
  SavedPreferencesLease? _binding;
  SavedPreferencesConditionalWrite? _write;
  Completer<void>? _writing;

  // The finite issued write admission bridges ONLY its own pending revision.
  // Consumers still wait for the acknowledged receipt in preferences().
  bool get current => _write?.current ?? (_binding?.current == true);

  void _check(bool Function() isCurrent) {
    if (!current || !isCurrent()) throw const CredentialVaultAdmissionDenied();
  }

  Future<TrackedSharedPreferences> preferences(
    bool Function() isCurrent,
  ) async {
    _check(isCurrent);
    final prefs = await _original;
    _check(isCurrent);
    if (prefs is! TrackedSharedPreferences ||
        (_write == null && !_binding!.bindOriginalStore(prefs.store))) {
      throw const CredentialVaultAdmissionDenied();
    }
    final writing = _writing;
    if (writing != null) {
      await writing.future;
      _check(isCurrent);
    }
    // Known inherited/issued identity cannot become first-install permission
    // after deletion, even in a fresh native graph on this same stable vault.
    if (prefs.containsKey(_key)) _admission.established = true;
    return prefs;
  }

  /// An explicit credential retirement cannot later become first-install birth,
  /// even if secure tombstone persistence fails. No device is deleted here.
  void preventBirth() {
    _admission.prevented = true;
    _admission.epoch++;
  }

  /// Admission for ONLY native DataCat account/anonymous protected mutations.
  /// Called before their awaited store/import, not after a physical completion.
  /// A captured absence cannot survive a same-vault mutation queued meanwhile.
  /// This is isolate-local observed/issued custody, NOT durable deletion history
  /// or coordination with another vault, process, or unobserved backend writer.
  static void admitCredentialMutation(
    CredentialVault vault, {
    required bool Function() isCurrent,
  }) {
    var current = false;
    try {
      current = isCurrent();
    } catch (_) {
      // Never expose an arbitrary native guard failure.
    }
    if (!current) throw const CredentialVaultAdmissionDenied();
    final admission = _admissions[vault] ??= _InstallationAdmission();
    admission.prevented = true;
    admission.epoch++;
  }

  /// Only explicit original-native link/identify calls this. Missing is distinct
  /// from empty/invalid, and either secure slot or ANY inherited binding refuses.
  Future<String> initialize(bool Function() isCurrent) {
    _check(isCurrent); // A retired caller cannot invalidate a newer birth.
    final epoch = ++_admission.epoch;
    return DatacatAccountPreferences.serialize(() async {
      void check() => _check(isCurrent);
      try {
        check();
        final prefs = await preferences(isCurrent);
        check();
        final existing = prefs.getString(_key);
        if (existing != null) {
          if (!DatacatAccountPreferences.validDevice(existing)) {
            throw const CredentialVaultException(
              CredentialVaultFailure.verificationFailed,
            );
          }
          return existing;
        }
        void absent() {
          check();
          if (epoch != _admission.epoch)
            throw const CredentialVaultAdmissionDenied();
          if (_admission.prevented ||
              _admission.established ||
              _credentials?.current != true ||
              !_credentials!.bindOriginalStore(prefs.store) ||
              _credentials.revisions.keys.any(prefs.containsKey) ||
              prefs.containsKey(_key)) {
            throw const CredentialVaultException(
              CredentialVaultFailure.verificationFailed,
            );
          }
        }

        absent();
        if (await _vault.hasStoredValue(_account)) {
          check();
          throw const CredentialVaultException(
            CredentialVaultFailure.verificationFailed,
          );
        }
        absent();
        if (await _vault.hasStoredValue(_anonymous)) {
          check();
          throw const CredentialVaultException(
            CredentialVaultFailure.verificationFailed,
          );
        }
        absent(); // Failed reads never reach the original write invocation.
        final device = _uuid();
        final write = prefs.store.owner.beginConditional(
          _binding!,
          prefs.store,
          _key,
        );
        if (write == null) throw const CredentialVaultAdmissionDenied();
        _write = write;
        final writing = _writing = Completer<void>();
        var accepted = false;
        try {
          absent();
          // Already inside the ORIGINAL device FIFO. The facade setter would
          // re-enter that tail and destroy the single issued admission. Retain
          // its actual producer and settle its acknowledgement, including throws.
          _admission.established = true;
          try {
            accepted = await prefs.delegate.setString(_key, device);
          } catch (_) {
            throw const DatacatInstallationWriteUnverified._();
          }
        } finally {
          _binding = write.finish(accepted);
          _write = null;
          _writing = null;
          writing.complete();
        }
        // False/throw describes an INVOKED unknown write, even if finish()
        // quarantined the binding or another caller retired us during the wait.
        // Do not overwrite it with the pre-invocation no-write refusal below.
        if (!accepted) throw const DatacatInstallationWriteUnverified._();
        // Device acknowledgement does not certify a credential backup admitted
        // while that write waited. Retire this producer's issued receipt rather
        // than letting its next call borrow the newly arrived legacy binding.
        if (_credentials?.current != true ||
            _credentials!.revisions.keys.any(prefs.containsKey)) {
          _binding?.retire();
          throw const CredentialVaultAdmissionDenied();
        }
        check();
        if (epoch != _admission.epoch)
          throw const CredentialVaultAdmissionDenied();
        if (prefs.getString(_key) != device) {
          throw const CredentialVaultException(
            CredentialVaultFailure.verificationFailed,
          );
        }
        return device;
      } on DatacatInstallationWriteUnverified {
        rethrow;
      } on CredentialVaultAdmissionDenied {
        rethrow;
      } on CredentialVaultException {
        rethrow;
      } catch (_) {
        throw const CredentialVaultException(
          CredentialVaultFailure.storageUnavailable,
        );
      }
    });
  }

  static String _uuid() {
    final random = Random();
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replaceAllMapped(
      RegExp('[xy]'),
      (match) {
        final value = random.nextInt(16);
        return (match.group(0) == 'x' ? value : (value & 0x3 | 0x8))
            .toRadixString(16);
      },
    );
  }
}

final class _InstallationAdmission {
  int epoch = 0;
  bool prevented = false, established = false;
}
