import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/credentials/credential_vault.dart';
import '../../core/credentials/saucepan_credential_owner.dart';
import 'services/saucepan_extractor.dart';

/// Persisted Saucepan account state. A configured bearer token *is* the
/// logged-in signal (the token, not a display name, gates local extraction);
/// [handle] is kept only to show "Logged in as …" in the menu.
class SaucepanAccount {
  final bool loggedIn;
  final String? handle;
  final bool credentialUnavailable, metadataUnavailable;
  const SaucepanAccount({
    this.loggedIn = false,
    this.handle,
    this.credentialUnavailable = false,
    this.metadataUnavailable = false,
  });

  bool get isLoggedIn => loggedIn;
}

/// Owns the Saucepan login lifecycle. Delegates the token to the shared
/// [SaucepanExtractor] (same instance used for extraction) and mirrors its
/// logged-in state, plus the display [handle], for the menu.
class SaucepanAccountNotifier extends Notifier<SaucepanAccount> {
  late SaucepanExtractor _extractor;
  int _generation = 0, _publication = 0;

  @override
  SaucepanAccount build() {
    _extractor = ref.watch(saucepanExtractorProvider);
    unawaited(_load(_extractor, ++_generation, ++_publication));
    return const SaucepanAccount();
  }

  bool _current(SaucepanExtractor ext, int generation, int publication) =>
      ref.mounted &&
      identical(ext, _extractor) &&
      generation == _generation &&
      publication == _publication;

  SaucepanAccount _account(SaucepanCredentialAccount value) => SaucepanAccount(
    loggedIn: value.authenticated,
    handle: value.handle,
    credentialUnavailable: value.unavailable,
    metadataUnavailable: value.metadataUnavailable,
  );

  Future<void> _load(
    SaucepanExtractor ext,
    int generation,
    int publication,
  ) async {
    try {
      await ext.loadToken();
      if (_current(ext, generation, publication)) state = _account(ext.account);
    } on CredentialVaultAdmissionDenied {
      // New native intent or retired original producer owns the completion.
      if (_current(ext, generation, publication)) {
        state = const SaucepanAccount(credentialUnavailable: true);
      }
    } catch (_) {
      if (_current(ext, generation, publication)) {
        state = const SaucepanAccount(credentialUnavailable: true);
      }
    }
  }

  Future<void> _mutate(
    Future<void> Function(
      SaucepanExtractor ext,
      void Function(SaucepanCredentialAccount) publish,
    )
    operation,
  ) async {
    final ext = _extractor, generation = _generation;
    final publication = ++_publication;
    void publish(SaucepanCredentialAccount value) {
      if (_current(ext, generation, publication)) state = _account(value);
    }

    // Invoke before await: login/setter/logout own their original admission.
    final pending = operation(ext, publish);
    final authCurrent = ext.captureAuthGuard();
    await pending;
    if (!_current(ext, generation, publication) || !authCurrent()) {
      throw const CredentialVaultAdmissionDenied();
    }
    publish(ext.account);
  }

  /// Logs in with handle + password; throws [SaucepanException] on failure.
  Future<void> login(String handle, String password) => _mutate(
    (ext, publish) => ext.login(handle, password, onCommitted: publish),
  );

  /// Stores a pasted bearer token directly (no handle).
  Future<void> setToken(String token) =>
      _mutate((ext, publish) => ext.setToken(token, onCommitted: publish));

  /// Clears the stored session.
  Future<void> logout() =>
      _mutate((ext, publish) => ext.logout(onCommitted: publish));
}

final saucepanAccountProvider =
    NotifierProvider<SaucepanAccountNotifier, SaucepanAccount>(
      SaucepanAccountNotifier.new,
    );
