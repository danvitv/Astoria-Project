import 'package:shared_preferences/shared_preferences.dart';

import '../preferences/saved_preferences_owner.dart';
import '../preferences/tracked_shared_preferences.dart';
import 'credential_slot.dart';
import 'credential_vault.dart';
import 'saucepan_legacy_credential_source.dart';
import 'secret_redaction_coordinator.dart';

/// Native account metadata only; no token, envelope, fingerprint or length.
final class SaucepanCredentialAccount {
  const SaucepanCredentialAccount({
    this.authenticated = false,
    this.handle,
    this.unavailable = false,
    this.metadataUnavailable = false,
  });
  final bool authenticated, unavailable, metadataUnavailable;
  // Display metadata is not evidence of token validity or account identity.
  final String? handle;
}

/// Saucepan-only trusted custody. No LLM broker/purpose or model-facing reader.
final class SaucepanCredentialOwner {
  SaucepanCredentialOwner({
    required CredentialVault vault,
    required SecretRedactionCoordinator redaction,
    required Future<SharedPreferences> originalPreferences,
  }) : _vault = vault,
       _redaction = redaction,
       _originalPreferences = originalPreferences,
       _preferencesOwner = _capturePreferencesOwner(),
       _legacy = SaucepanLegacyCredentialSource(originalPreferences);

  static SavedPreferencesLease _capturePreferencesOwner() {
    final owner = SavedPreferencesOwner.process;
    final store = owner.originalStore;
    // Store custody only: native entry may follow a tracked backup write, but
    // must never adopt a replacement preference producer after its first await.
    return owner.capture(
      const [],
      store: store?.current == true ? store : null,
    );
  }

  static final _slot = CredentialSlot(
    domain: 'catalog.saucepan',
    id: 'account',
  );
  static const _handleKey = 'gz_saucepan_handle';
  final CredentialVault _vault;
  final SecretRedactionCoordinator _redaction;
  final Future<SharedPreferences> _originalPreferences;
  final SavedPreferencesLease _preferencesOwner;
  final SaucepanLegacyCredentialSource _legacy;
  Future<void> _tail = Future<void>.value();
  int _epoch = 0;
  bool _disposed = false, _hydrated = false;

  bool _current(int epoch) =>
      !_disposed && epoch == _epoch && _preferencesOwner.current;
  bool Function() captureAuthGuard() {
    final epoch = _epoch;
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

  Future<TrackedSharedPreferences> _prefs(int epoch) async {
    _check(epoch);
    final prefs = await _originalPreferences;
    _check(epoch);
    if (prefs is! TrackedSharedPreferences ||
        !_preferencesOwner.bindOriginalStore(prefs.store)) {
      throw const CredentialVaultAdmissionDenied();
    }
    return prefs;
  }

  Future<bool> _authenticate(int epoch) async {
    _check(epoch);
    await _prefs(epoch);
    _check(epoch);
    // Secure read failure is never absence and never permits legacy fallback.
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
    var authenticated = false;
    if (metadata.configured) {
      await _vault.useSecret(_slot, (token) async {
        _check(epoch);
        _redaction.registerSecret(token);
        // Old Saucepan login gating trimmed, but legacy storage did not.
        authenticated = token.trim().isNotEmpty;
      });
      _check(epoch);
    }
    _hydrated = true;
    return authenticated;
  }

  Future<SaucepanCredentialAccount> load() {
    final epoch = _epoch;
    return _run(() async {
      final prefs = await _prefs(epoch);
      final display = _readHandle(prefs);
      try {
        final authenticated = await _authenticate(epoch);
        _check(epoch);
        return SaucepanCredentialAccount(
          authenticated: authenticated,
          handle: display.handle,
          metadataUnavailable: display.unavailable,
        );
      } catch (_) {
        _check(epoch);
        return SaucepanCredentialAccount(
          unavailable: true,
          handle: display.handle,
          metadataUnavailable: display.unavailable,
        );
      }
    });
  }

  /// Display metadata is independent of protected authentication. Imported
  /// wrong-type values must not hide a verified token or turn load into failure.
  ({String? handle, bool unavailable}) _readHandle(
    TrackedSharedPreferences prefs,
  ) {
    try {
      return (handle: prefs.getString(_handleKey), unavailable: false);
    } catch (_) {
      return (handle: null, unavailable: true);
    }
  }

  Future<SaucepanCredentialAccount> _store(
    int epoch,
    String token, {
    String? handle,
    bool logout = false,
    void Function(SaucepanCredentialAccount)? onCommitted,
  }) => _run(() async {
    final prefs = await _prefs(epoch);
    final trimmed = token.trim();
    // Empty protected value is durable logout; legacy plaintext remains untouched.
    await _vault.storeGuarded(_slot, trimmed, isCurrent: () => _current(epoch));
    _check(epoch);
    _hydrated = true;
    final display = logout
        ? (handle: null, unavailable: false)
        : handle == null
        ? _readHandle(prefs)
        : (handle: handle, unavailable: false);
    final committed = SaucepanCredentialAccount(
      authenticated: trimmed.isNotEmpty,
      handle: display.handle,
    );
    onCommitted?.call(committed);
    var metadataUnavailable = display.unavailable;
    if (logout || handle != null) {
      try {
        _check(epoch);
        final saved = logout
            ? await prefs.remove(_handleKey)
            : await prefs.setString(_handleKey, handle!);
        _check(epoch);
        if (!prefs.store.current) throw const CredentialVaultAdmissionDenied();
        metadataUnavailable = !saved;
      } on CredentialVaultAdmissionDenied {
        rethrow;
      } catch (_) {
        _check(epoch);
        metadataUnavailable = true;
      }
    }
    _check(epoch);
    return SaucepanCredentialAccount(
      authenticated: committed.authenticated,
      handle: display.handle,
      metadataUnavailable: metadataUnavailable,
    );
  });

  Future<SaucepanCredentialAccount> setToken(
    String token, {
    void Function(SaucepanCredentialAccount)? onCommitted,
  }) {
    _redaction.registerSecret(
      token,
    ); // Synchronous, including failed submissions.
    return _store(++_epoch, token, onCommitted: onCommitted);
  }

  Future<SaucepanCredentialAccount> logout({
    void Function(SaucepanCredentialAccount)? onCommitted,
  }) => _store(++_epoch, '', logout: true, onCommitted: onCommitted);

  /// Login owns its admission BEFORE HTTP. Network waits do not hold the mutation
  /// FIFO; a manual setter/logout can finish while an old response is outstanding.
  /// The trusted consumer passes a returned token only to this ephemeral commit.
  Future<SaucepanCredentialAccount> login(
    String handle,
    Future<void> Function(
      Future<void> Function(String token) commit,
      bool Function() isCurrent,
    )
    authenticate, {
    void Function(SaucepanCredentialAccount)? onCommitted,
  }) async {
    final epoch = ++_epoch;
    SaucepanCredentialAccount? result;
    await authenticate((token) async {
      _redaction.registerSecret(token);
      _check(epoch);
      result = await _store(
        epoch,
        token,
        handle: handle.trim(),
        onCommitted: onCommitted,
      );
      _check(epoch);
    }, () => _current(epoch));
    _check(epoch);
    if (result == null) throw const CredentialVaultAdmissionDenied();
    return result!;
  }

  /// Only trusted native HTTP consumers receive the ephemeral token and guard.
  /// No anonymous callback is invoked for missing/unavailable credentials.
  Future<T> withToken<T>(
    Future<T> Function(String token, bool Function() isCurrent) consume,
  ) async {
    final epoch = _epoch;
    final authenticated = await _run(() => _authenticate(epoch));
    _check(epoch);
    if (!authenticated) {
      throw const CredentialVaultException(CredentialVaultFailure.missing);
    }
    late T result;
    try {
      await _vault.useSecret(_slot, (token) async {
        _check(epoch);
        _redaction.registerSecret(token);
        result = await consume(token, () => _current(epoch));
        _check(epoch);
      });
    } catch (_) {
      _check(
        epoch,
      ); // Preserve terminal retirement despite vault error wrapping.
      rethrow;
    }
    _check(epoch);
    return result;
  }

  void dispose() {
    _disposed = true;
    _epoch++;
  }
}
