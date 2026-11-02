import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/credentials/chub_credential_owner.dart';
import '../../core/credentials/credential_vault.dart';
import '../../core/state/credential_vault_provider.dart';
import '../../core/state/shared_prefs_provider.dart';
import 'services/chub_provider.dart';

/// Last-known Chub account, persisted across launches.
///
/// The protected API key is the logged-in signal: each Chub catalog request carries
/// it as `CH-API-KEY` (and the parallel `samwise` header the site itself sends),
/// which unlocks account-scoped results — most importantly NSFL, which the
/// public API refuses to return without a session. Only the display [userName]
/// is kept here; the key stays in the vault and never in account/provider state.
class ChubAccount {
  final String? userName;

  /// Historical display metadata, explicitly not identity of the current key.
  final String? lastKnownUserName;
  final bool isLoggedIn;
  final bool credentialUnavailable;
  final bool metadataUnavailable;

  /// Account-event counter, not a secret hash/equality projection.
  final int authRevision;

  /// Account-level NSFL opt-in, the app's counterpart to the `no_nsfl` flag the
  /// site stores on the user profile. chub.ai serves NSFL only to a signed-in
  /// account, and asks per search on top of that — so this is the persistent
  /// "I want it" and the filter sheet's NSFL toggle is the per-search narrowing.
  /// It is ORed into every search.
  final bool nsfl;

  const ChubAccount({
    this.userName,
    this.lastKnownUserName,
    this.isLoggedIn = false,
    this.credentialUnavailable = false,
    this.metadataUnavailable = false,
    this.authRevision = 0,
    this.nsfl = false,
  });
}

final chubCredentialOwnerProvider = Provider<ChubCredentialOwner>((ref) {
  resetChubTagCache();
  final owner = ChubCredentialOwner(
    vault: ref.watch(credentialVaultProvider),
    redaction: ref.watch(secretRedactionCoordinatorProvider),
    originalPreferences: ref.watch(sharedPreferencesProvider.future),
    onAuthAdmission: resetChubTagCache,
  );
  ref.onDispose(owner.dispose);
  return owner;
});

/// Auth already committed; callers must not describe this as a failed login or
/// undo the credential. No backend exception or account material is retained.
final class ChubAccountMetadataException implements Exception {
  const ChubAccountMetadataException();

  @override
  String toString() =>
      'Chub authentication committed, but account metadata could not be saved';
}

/// Native account summary plus mutation entry points. Async publications retain
/// their original owner/build and cannot repaint a newer setter/logout/rebuild.
class ChubAccountNotifier extends Notifier<ChubAccount> {
  late ChubCredentialOwner _owner;
  int _generation = 0, _publication = 0;

  @override
  ChubAccount build() {
    _owner = ref.watch(chubCredentialOwnerProvider);
    final owner = _owner, generation = ++_generation;
    final publication = ++_publication;
    unawaited(_load(owner, generation, publication));
    return const ChubAccount();
  }

  bool _current(ChubCredentialOwner owner, int generation, int publication) =>
      ref.mounted &&
      identical(_owner, owner) &&
      generation == _generation &&
      publication == _publication;

  ChubAccount _account(ChubCredentialAccount value) => ChubAccount(
    userName: value.userName,
    lastKnownUserName: value.lastKnownUserName,
    nsfl: value.nsfl,
    isLoggedIn: value.authenticated,
    credentialUnavailable: value.unavailable,
    metadataUnavailable: value.metadataUnavailable,
    authRevision: value.authRevision,
  );

  Future<void> _load(
    ChubCredentialOwner owner,
    int generation,
    int publication,
  ) async {
    try {
      final value = await owner.load();
      if (_current(owner, generation, publication)) state = _account(value);
    } on CredentialVaultAdmissionDenied {
      // A native setter/logout or original producer retirement owns the result.
    } catch (_) {
      if (_current(owner, generation, publication)) {
        state = const ChubAccount(credentialUnavailable: true);
      }
    }
  }

  Future<void> _mutate(
    Future<ChubCredentialAccount> Function(
      void Function(ChubCredentialAccount) publish,
    )
    operation,
  ) async {
    final owner = _owner, generation = _generation;
    final publication = ++_publication;
    void publish(ChubCredentialAccount value) {
      if (_current(owner, generation, publication)) state = _account(value);
    }

    final value = await operation(publish);
    if (!_current(owner, generation, publication)) return;
    publish(value);
    if (value.metadataUnavailable) throw const ChubAccountMetadataException();
  }

  /// Stores [key] in the vault (clearing the account when null/empty). A supplied
  /// [userName] is kept alongside it, so the menu can show who is signed in.
  Future<void> setApiKey(String? key, {String? userName}) => _mutate(
    (publish) =>
        _owner.setApiKey(key, userName: userName, onCommitted: publish),
  );

  /// Updates only the display name, leaving the stored key untouched.
  Future<void> setUserName(String? name) =>
      _mutate((_) => _owner.setUserName(name));

  /// Turns the account-level NSFL opt-in on or off.
  Future<void> setNsfl(bool value) => _mutate((_) => _owner.setNsfl(value));

  /// Clears the display name and NSFL, leaving a protected empty logout tombstone.
  /// Preserved legacy material cannot revive the account on the next launch.
  Future<void> logout() =>
      _mutate((publish) => _owner.logout(onCommitted: publish));

  /// Trusted catalog callback only; no key-returning account API.
  Future<T> withApiKey<T>(Future<T> Function(String? key) consume) =>
      _owner.withApiKey(consume);

  /// Multi-request native consumers retain account AND notifier-build ownership
  /// before the first await, and recheck before every HTTP/cache publication.
  Future<T> withApiKeyGuarded<T>(
    Future<T> Function(String? key, bool Function() isCurrent) consume,
  ) {
    final owner = _owner;
    final current = captureProbeGuard();
    return owner.withApiKey((key) => consume(key, current));
  }

  /// Used by a WebView probe which has not yet admitted an auth mutation.
  bool Function() captureProbeGuard() {
    final owner = _owner, generation = _generation;
    final authCurrent = owner.captureAuthGuard();
    return () =>
        ref.mounted &&
        identical(_owner, owner) &&
        generation == _generation &&
        authCurrent();
  }
}

final chubAccountProvider = NotifierProvider<ChubAccountNotifier, ChubAccount>(
  ChubAccountNotifier.new,
);
