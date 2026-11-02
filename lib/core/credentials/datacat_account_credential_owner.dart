import 'package:shared_preferences/shared_preferences.dart';

import '../preferences/tracked_shared_preferences.dart';
import 'credential_slot.dart';
import 'credential_vault.dart';
import 'datacat_account_legacy_source.dart';
import 'datacat_account_preferences.dart';
import 'datacat_account_record.dart';
import 'datacat_installation_owner.dart';
import 'secret_redaction_coordinator.dart';

export 'datacat_account_record.dart' show DatacatCredentialAccount;

/// DataCat linked-account custody only. The anonymous and transfer-lease owners
/// remain separate; no LLM purpose, model-facing reader or secret DTO is added.
final class DatacatAccountCredentialOwner {
  DatacatAccountCredentialOwner({
    required CredentialVault vault,
    required SecretRedactionCoordinator redaction,
    required Future<SharedPreferences> originalPreferences,
  }) : _vault = vault,
       _redaction = redaction,
       _admission = _admissions[vault] ??= _DatacatAccountAdmission() {
    _installation = DatacatInstallationOwner(
      vault: vault,
      originalPreferences: originalPreferences,
    );
    _legacy = DatacatAccountLegacySource(originalPreferences, vault: vault);
    _epoch = _admission.epoch;
  }

  static final _slot = CredentialSlot(domain: 'catalog.datacat', id: 'account');
  // Shared only by owners of the same stable vault. An old live graph must not
  // overwrite a newer graph's explicit linked-account admission.
  static final _admissions = Expando<_DatacatAccountAdmission>();
  final CredentialVault _vault;
  final SecretRedactionCoordinator _redaction;
  late final DatacatInstallationOwner _installation;
  late final DatacatAccountLegacySource _legacy;
  final _DatacatAccountAdmission _admission;
  Future<void> _tail = Future<void>.value();
  int _epoch = 0;
  bool _disposed = false, _hydrated = false;

  bool _current(int epoch) =>
      !_disposed &&
      epoch == _epoch &&
      epoch == _admission.epoch &&
      _installation.current;
  int _begin() {
    // A disposed/retired producer cannot invalidate another live graph merely
    // by submitting a call that its own queue will later refuse.
    if (_disposed || !_installation.current) return _epoch;
    return _epoch = ++_admission.epoch;
  }

  bool Function() captureAuthGuard() {
    final epoch = _epoch;
    return () => _current(epoch);
  }

  void _check(int epoch) {
    if (!_current(epoch)) throw const CredentialVaultAdmissionDenied();
  }

  Future<T> _run<T>(Future<T> Function() operation) {
    final admission = _epoch;
    final result = _tail.then((_) async {
      try {
        _check(admission);
        final value = await operation();
        _check(admission);
        return value;
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
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<TrackedSharedPreferences> _prefs(int epoch) async {
    _check(epoch);
    final prefs = await _installation.preferences(() => _current(epoch));
    _check(epoch);
    return prefs;
  }

  String _device(SharedPreferences prefs) {
    final device = prefs.getString(DatacatAccountPreferences.device);
    if (device == null || !DatacatAccountPreferences.validDevice(device)) {
      // Birth belongs to the explicit original-native installation producer;
      // migration and token replacement never repair/regenerate a binding.
      throw const CredentialVaultException(
        CredentialVaultFailure.verificationFailed,
      );
    }
    return device;
  }

  Future<DatacatCredentialAccount> _load(int epoch) async {
    final prefs = await _prefs(epoch);
    final present = await _vault.hasStoredValue(_slot);
    _check(epoch);
    if (!present && !_hydrated) {
      await _legacy.importIfAbsent(
        vault: _vault,
        slot: _slot,
        redaction: _redaction,
        isCurrent: () => _current(epoch),
      );
      _check(epoch);
    }
    final metadata = await _vault.metadata(_slot);
    _check(epoch);
    var account = const DatacatCredentialAccount();
    if (metadata.configured) {
      await _use(epoch, prefs, (token, summary) async {
        account = summary;
      });
      _check(epoch);
    }
    _hydrated = true;
    return account;
  }

  Future<T> _use<T>(
    int epoch,
    SharedPreferences prefs,
    Future<T> Function(String token, DatacatCredentialAccount account) consume,
  ) async {
    late T result;
    try {
      await _vault.useSecret(_slot, (raw) async {
        _check(epoch);
        result = await useDatacatAccount(
          raw,
          expectedDevice: _device(prefs),
          redaction: _redaction,
          consume: (token, account) async {
            _check(epoch);
            final value = await consume(token, account);
            _check(epoch);
            return value;
          },
        );
        _check(epoch);
      });
    } catch (_) {
      _check(epoch); // Retirement survives vault consumer-error wrapping.
      rethrow;
    }
    _check(epoch);
    return result;
  }

  Future<DatacatCredentialAccount> load() {
    final epoch = _epoch;
    return _run(() async {
      try {
        return await _load(epoch);
      } on CredentialVaultException {
        _check(epoch);
        return const DatacatCredentialAccount(unavailable: true);
      }
    });
  }

  /// Verified absence/tombstone alone allows an optional anonymous read. A
  /// failed secure read, invalid binding or retired source NEVER calls consume.
  Future<T> withAccount<T>(
    Future<T> Function(
      String? token,
      String? device,
      DatacatCredentialAccount account,
      bool Function() current,
    )
    consume, {
    bool requiredAccount = false,
  }) async {
    final epoch = _epoch;
    final account = await _run(() => _load(epoch));
    _check(epoch);
    if (!account.authenticated) {
      if (requiredAccount)
        throw const CredentialVaultException(CredentialVaultFailure.missing);
      final value = await consume(null, null, account, () => _current(epoch));
      _check(epoch);
      return value;
    }
    final prefs = await _prefs(epoch);
    _check(epoch);
    return _use(
      epoch,
      prefs,
      (token, summary) =>
          consume(token, _device(prefs), summary, () => _current(epoch)),
    );
  }

  Future<DatacatCredentialAccount> _store(
    int epoch,
    String token,
    String device, {
    String? name,
    List<String> scopes = const [],
    required bool Function() operationCurrent,
  }) => _run(() async {
    final prefs = await _prefs(epoch);
    bool current() =>
        _current(epoch) && operationCurrent() && _device(prefs) == device;
    if (!current()) throw const CredentialVaultAdmissionDenied();
    DatacatInstallationOwner.admitCredentialMutation(
      _vault,
      isCurrent: current,
    );
    await _vault.storeGuarded(
      _slot,
      token.isEmpty
          ? ''
          : encodeDatacatAccount(token, device, name: name, scopes: scopes),
      isCurrent: current,
    );
    if (!current()) throw const CredentialVaultAdmissionDenied();
    _hydrated = true;
    final account = token.isEmpty
        ? const DatacatCredentialAccount()
        : await useDatacatAccount(
            encodeDatacatAccount(token, device, name: name, scopes: scopes),
            expectedDevice: device,
            redaction: _redaction,
            consume: (_, account) async => account,
          );
    if (!current()) throw const CredentialVaultAdmissionDenied();
    return account;
  });

  /// Exact native replacement. Device comes with the submitted token, but must
  /// equal this installation's original binding; preferences are never rewritten.
  Future<DatacatCredentialAccount> setToken(
    String token, {
    required String installationId,
    String? name,
    List<String> scopes = const [],
  }) {
    _redaction.registerSecret(token);
    return _store(
      _begin(),
      token,
      installationId,
      name: name,
      scopes: List.of(scopes),
      operationCurrent: () => true,
    );
  }

  /// Admission starts BEFORE HTTP; network waits never hold the mutation FIFO.
  Future<DatacatCredentialAccount> link(
    Future<void> Function(
      String device,
      bool Function() current,
      Future<void> Function(String token, String? name, List<String> scopes)
      commit,
    )
    approve, {
    bool Function()? isCancelled,
  }) async {
    final epoch = _begin();
    bool current() => _current(epoch) && !(isCancelled?.call() ?? false);
    final account = await _run(() => _load(epoch));
    _check(epoch);
    if (!current() || account.unavailable)
      throw const CredentialVaultAdmissionDenied();
    final device = await _installation.initialize(current);
    _check(epoch);
    DatacatCredentialAccount? committed;
    await approve(device, current, (token, name, scopes) async {
      _redaction.registerSecret(token);
      if (!current()) throw const CredentialVaultAdmissionDenied();
      committed = await _store(
        epoch,
        token,
        device,
        name: name,
        scopes: scopes,
        operationCurrent: current,
      );
      if (!current()) throw const CredentialVaultAdmissionDenied();
    });
    if (!current() || committed == null)
      throw const CredentialVaultAdmissionDenied();
    return committed!;
  }

  /// Remote revocation only on explicit unlink. Failure is not anonymous retry;
  /// local unlink still requires a verified EMPTY secure tombstone.
  Future<DatacatCredentialAccount> unlink(
    Future<void> Function(String token, String device, bool Function() current)
    revoke,
  ) async {
    final epoch = _begin();
    if (_current(epoch)) _installation.preventBirth();
    final prefs = await _prefs(epoch);
    _check(epoch);
    try {
      final account = await _run(() => _load(epoch));
      _check(epoch);
      if (account.authenticated) {
        await _use(
          epoch,
          prefs,
          (token, _) => revoke(token, _device(prefs), () => _current(epoch)),
        );
        _check(epoch);
      }
    } catch (_) {
      _check(epoch); // Never let an old revoke erase a newer native admission.
    }
    return _run(() async {
      _check(epoch);
      DatacatInstallationOwner.admitCredentialMutation(
        _vault,
        isCurrent: () => _current(epoch),
      );
      await _vault.storeGuarded(_slot, '', isCurrent: () => _current(epoch));
      _check(epoch);
      _hydrated = true;
      return const DatacatCredentialAccount();
    });
  }

  /// A passive server response may retire only its own original account view.
  /// This writes a verified local tombstone, never a remote revoke or prefs cleanup.
  Future<void> forgetRevoked({required bool Function() isCurrent}) {
    final epoch = _epoch;
    return _run(() async {
      _check(epoch);
      if (!isCurrent()) throw const CredentialVaultAdmissionDenied();
      DatacatInstallationOwner.admitCredentialMutation(
        _vault,
        isCurrent: () => _current(epoch) && isCurrent(),
      );
      await _vault.storeGuarded(
        _slot,
        '',
        isCurrent: () => _current(epoch) && isCurrent(),
      );
      _check(epoch);
      if (!isCurrent()) throw const CredentialVaultAdmissionDenied();
      _hydrated = true;
    });
  }

  void dispose() {
    _disposed = true;
    _epoch++;
  }
}

final class _DatacatAccountAdmission {
  int epoch = 0;
}
