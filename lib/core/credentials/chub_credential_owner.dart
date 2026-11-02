import 'package:shared_preferences/shared_preferences.dart';

import '../preferences/tracked_shared_preferences.dart';
import 'chub_legacy_credential_source.dart';
import 'credential_slot.dart';
import 'credential_vault.dart';
import 'secret_redaction_coordinator.dart';

/// Native account summary only: neither key, envelope, fingerprint nor length.
final class ChubCredentialAccount {
  const ChubCredentialAccount({
    this.userName,
    this.lastKnownUserName,
    this.nsfl = false,
    this.authenticated = false,
    this.unavailable = false,
    this.metadataUnavailable = false,
    this.authRevision = 0,
  });
  final String? userName;

  /// Persisted display metadata alone never proves the current key's identity.
  final String? lastKnownUserName;
  final bool nsfl, authenticated, unavailable, metadataUnavailable;
  // An account-event counter, never a secret equality/hash answer.
  final int authRevision;
}

/// Chub-only trusted owner. No LLM broker purpose, route permit, model tool or
/// saved-application dataset is used for catalog authentication.
final class ChubCredentialOwner {
  ChubCredentialOwner({
    required CredentialVault vault,
    required SecretRedactionCoordinator redaction,
    required Future<SharedPreferences> originalPreferences,
    void Function()? onAuthAdmission,
  }) : _vault = vault,
       _redaction = redaction,
       _originalPreferences = originalPreferences,
       _onAuthAdmission = onAuthAdmission,
       _legacy = ChubLegacyCredentialSource(originalPreferences);

  static final _slot = CredentialSlot(domain: 'catalog.chub', id: 'account');
  static const _nameKey = 'gz_chub_user_name', _nsflKey = 'gz_chub_nsfl';
  final CredentialVault _vault;
  final SecretRedactionCoordinator _redaction;
  final Future<SharedPreferences> _originalPreferences;
  final ChubLegacyCredentialSource _legacy;
  final void Function()? _onAuthAdmission;
  Future<void> _tail = Future<void>.value();
  int _authEpoch = 0;
  bool _disposed = false, _hydrated = false;
  bool _nativeNameIntent = false;
  String? _boundUserName;
  bool? _nsflOverride;

  bool _current(int epoch) => !_disposed && epoch == _authEpoch;
  bool Function() captureAuthGuard() {
    final epoch = _authEpoch;
    return () => _current(epoch);
  }

  void _check(int epoch) {
    if (!_current(epoch)) throw const CredentialVaultAdmissionDenied();
  }

  Future<T> _run<T>(Future<T> Function() operation) {
    final result = _tail.then((_) async {
      try {
        return await operation();
      } on CredentialVaultException {
        rethrow;
      } on CredentialVaultAdmissionDenied {
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

  Future<TrackedSharedPreferences> _prefs() async {
    final prefs = await _originalPreferences;
    if (_disposed ||
        prefs is! TrackedSharedPreferences ||
        !prefs.store.current) {
      throw const CredentialVaultAdmissionDenied();
    }
    return prefs;
  }

  Future<bool> _authenticate(int epoch) async {
    _check(epoch);
    // A failed secure read propagates. It never authorizes reading/using legacy.
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
    if (metadata.configured) {
      await _vault.useSecret(_slot, (key) async {
        _check(epoch);
        _redaction.registerSecret(key);
      });
      _check(epoch);
    }
    _hydrated = true;
    return metadata.configured;
  }

  ChubCredentialAccount _summary(
    SharedPreferences prefs, {
    bool authenticated = false,
    bool unavailable = false,
    bool metadataUnavailable = false,
  }) => ChubCredentialAccount(
    userName: authenticated ? _boundUserName : null,
    lastKnownUserName: _nativeNameIntent ? null : prefs.getString(_nameKey),
    nsfl: _nsflOverride ?? prefs.getBool(_nsflKey) ?? false,
    authenticated: authenticated,
    unavailable: unavailable,
    metadataUnavailable: metadataUnavailable,
    authRevision: _authEpoch,
  );

  Future<ChubCredentialAccount> load() {
    final epoch = _authEpoch;
    return _run(() async {
      final prefs = await _prefs();
      _check(epoch);
      try {
        final authenticated = await _authenticate(epoch);
        _check(epoch);
        return _summary(prefs, authenticated: authenticated);
      } catch (_) {
        _check(epoch);
        // Keep last-known display metadata/NSFL when storage is unavailable.
        return _summary(prefs, unavailable: true);
      }
    });
  }

  /// Explicit native entry is replacement, not a hydration store. Register even
  /// rejected submissions synchronously before diagnostic/error publication.
  Future<ChubCredentialAccount> setApiKey(
    String? key, {
    String? userName,
    void Function(ChubCredentialAccount)? onCommitted,
  }) {
    if (key != null) _redaction.registerSecret(key);
    final epoch = ++_authEpoch;
    _onAuthAdmission?.call();
    final trimmed = key?.trim() ?? '';
    return _run(() async {
      final prefs = await _prefs();
      _check(epoch);
      await _vault.storeGuarded(
        _slot,
        trimmed,
        isCurrent: () => _current(epoch),
      );
      _check(epoch);
      _hydrated = true;
      final name = userName?.trim() ?? '';
      _nativeNameIntent = true;
      _boundUserName = trimmed.isNotEmpty && name.isNotEmpty ? name : null;
      // Auth truth is already verified. Metadata cannot roll it back or leave
      // the notifier/account scope using the previous key while it settles.
      onCommitted?.call(_summary(prefs, authenticated: trimmed.isNotEmpty));
      final metadataSaved = await _writeMetadata(
        epoch,
        prefs,
        () => _boundUserName == null
            ? prefs.remove(_nameKey)
            : prefs.setString(_nameKey, _boundUserName!),
      );
      _check(epoch);
      return _summary(
        prefs,
        authenticated: trimmed.isNotEmpty,
        metadataUnavailable: !metadataSaved,
      );
    });
  }

  Future<ChubCredentialAccount> setUserName(String? name) {
    final epoch = _authEpoch;
    return _run(() async {
      final prefs = await _prefs();
      _check(epoch);
      final trimmed = name?.trim() ?? '';
      await _write(
        prefs,
        () => trimmed.isEmpty
            ? prefs.remove(_nameKey)
            : prefs.setString(_nameKey, trimmed),
      );
      _check(epoch);
      // Explicit native attribution applies only to this auth epoch.
      _nativeNameIntent = true;
      _boundUserName = trimmed.isEmpty ? null : trimmed;
      return _metadataSummary(prefs);
    });
  }

  Future<ChubCredentialAccount> setNsfl(bool value) {
    final epoch = _authEpoch;
    return _run(() async {
      final prefs = await _prefs();
      _check(epoch);
      await _write(prefs, () => prefs.setBool(_nsflKey, value));
      _check(epoch);
      _nsflOverride = null;
      return _metadataSummary(prefs);
    });
  }

  Future<ChubCredentialAccount> _metadataSummary(
    SharedPreferences prefs,
  ) async {
    final epoch = _authEpoch;
    try {
      final authenticated = await _authenticate(epoch);
      _check(epoch);
      return _summary(prefs, authenticated: authenticated);
    } catch (_) {
      _check(epoch);
      return _summary(prefs, unavailable: true);
    }
  }

  Future<void> _write(
    TrackedSharedPreferences prefs,
    Future<bool> Function() write,
  ) async {
    if (_disposed || !prefs.store.current || !await write()) {
      throw const CredentialVaultException(
        CredentialVaultFailure.storageUnavailable,
      );
    }
    if (_disposed || !prefs.store.current) {
      throw const CredentialVaultAdmissionDenied();
    }
  }

  Future<bool> _writeMetadata(
    int epoch,
    TrackedSharedPreferences prefs,
    Future<bool> Function() write,
  ) async {
    _check(epoch);
    try {
      await _write(prefs, write);
      _check(epoch);
      return true;
    } on CredentialVaultAdmissionDenied {
      rethrow;
    } catch (_) {
      _check(epoch);
      // Fixed, separately reported metadata failure; secure commit stands.
      return false;
    }
  }

  Future<ChubCredentialAccount> logout({
    void Function(ChubCredentialAccount)? onCommitted,
  }) {
    final epoch = ++_authEpoch;
    _onAuthAdmission?.call();
    return _run(() async {
      final prefs = await _prefs();
      _check(epoch);
      // An EMPTY protected value is a durable native logout tombstone. Deleting
      // the slot would let preserved plaintext/backup material sign in again.
      await _vault.storeGuarded(_slot, '', isCurrent: () => _current(epoch));
      _check(epoch);
      _hydrated = true;
      _nativeNameIntent = true;
      _boundUserName = null;
      _nsflOverride = false;
      onCommitted?.call(_summary(prefs));
      final nameSaved = await _writeMetadata(
        epoch,
        prefs,
        () => prefs.remove(_nameKey),
      );
      final nsflSaved = await _writeMetadata(
        epoch,
        prefs,
        () => prefs.remove(_nsflKey),
      );
      _check(epoch);
      if (nsflSaved) _nsflOverride = null;
      return _summary(prefs, metadataUnavailable: !nameSaved || !nsflSaved);
    });
  }

  /// Only trusted Chub catalog consumers receive this ephemeral argument. It
  /// never returns a secret and never stores one in provider/account state.
  Future<T> withApiKey<T>(Future<T> Function(String? key) consume) async {
    final epoch = _authEpoch;
    final authenticated = await _run(() => _authenticate(epoch));
    _check(epoch);
    if (!authenticated) {
      final result = await consume(null);
      _check(epoch);
      return result;
    }
    late T result;
    await _vault.useSecret(_slot, (key) async {
      _check(epoch);
      _redaction.registerSecret(key);
      result = await consume(key);
    });
    _check(epoch);
    return result;
  }

  /// Not wired to a screen or automatic cleanup. Requires a later explicit
  /// native user decision and refuses original-source/revision/vault mismatch.
  Future<bool> retireLegacyWithNativeConsent({required bool confirmed}) {
    final epoch = _authEpoch;
    return _run(
      () => _legacy.retireWithNativeConsent(
        confirmed: confirmed,
        vault: _vault,
        slot: _slot,
        redaction: _redaction,
        isCurrent: () => _current(epoch),
      ),
    );
  }

  void dispose() {
    _disposed = true;
    _authEpoch++;
  }
}
