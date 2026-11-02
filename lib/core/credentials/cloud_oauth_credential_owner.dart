import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../preferences/saved_preferences_owner.dart';
import '../preferences/tracked_shared_preferences.dart';
import 'cloud_oauth_legacy_source.dart';
import 'cloud_oauth_preferences.dart';
import 'cloud_oauth_record.dart';
import 'credential_slot.dart';
import 'credential_vault.dart';
import 'secret_redaction_coordinator.dart';

/// Only the original cloud OAuth family. Stable-vault/provider admission is
/// synchronous BEFORE browser/HTTP/slot waits; network never holds a write FIFO.
final class CloudOAuthCredentialOwner {
  CloudOAuthCredentialOwner({
    required CredentialVault vault,
    required this.provider,
    required this.redaction,
    required Future<SharedPreferences> originalPreferences,
  }) : _vault = vault,
       _original = originalPreferences,
       _storeLease = CloudOAuthPreferences.capture(document: false),
       _legacy = CloudOAuthLegacySource(originalPreferences) {
    final graph = _admissions[vault] ??= {};
    _admission = graph[provider] ??= _CloudAdmission();
    _admission.redaction = redaction;
    _epoch = _admission.epoch;
    _slot = CredentialSlot(domain: 'cloud.oauth', id: provider.name);
  }

  static final _admissions =
      Expando<Map<CloudOAuthProvider, _CloudAdmission>>();
  final CredentialVault _vault;
  final CloudOAuthProvider provider;
  final SecretRedactionCoordinator redaction;
  final Future<SharedPreferences> _original;
  final SavedPreferencesLease? _storeLease;
  final CloudOAuthLegacySource _legacy;
  late final _CloudAdmission _admission;
  late final CredentialSlot _slot;
  late int _epoch;
  bool _disposed = false;
  CloudOAuthPair? _cached;
  final _receipts = Expando<_CloudCredentialReceipt>();
  bool get connected => _cached != null && current;
  CloudOAuthPair? get cached => current ? _cached : null;
  bool get current =>
      !_disposed && _epoch == _admission.epoch && _storeLease?.current == true;

  bool Function() captureGuard() {
    final epoch = _epoch;
    return () => current && epoch == _epoch;
  }

  /// Issued at the actual protected read/verified write, not a newest lookup.
  bool Function() credentialGuard(CloudOAuthPair pair) {
    final receipt = _receipts[pair];
    return () =>
        current &&
        receipt != null &&
        receipt.epoch == _epoch &&
        receipt.generation == _admission.generation;
  }

  void registerAliases(Object? value) {
    registerCloudOAuthAliases(value, redaction);
    final latest = _admission.redaction;
    if (latest != null && !identical(latest, redaction)) {
      registerCloudOAuthAliases(value, latest);
    }
  }

  void registerSecret(String value) {
    redaction.registerSecret(value);
    _admission.redaction?.registerSecret(value);
  }

  bool Function() beginOperation() {
    if (current) {
      _epoch = ++_admission.epoch;
      _cached = null;
    }
    return captureGuard();
  }

  bool Function() beginRefresh(bool Function() original) {
    check(original);
    final refresh = ++_admission.refresh;
    return () => original() && refresh == _admission.refresh;
  }

  void check(bool Function() guard) {
    if (!current || !guard()) throw const CredentialVaultAdmissionDenied();
  }

  Future<void> _bind(bool Function() guard) async {
    check(guard);
    final prefs = await _original;
    check(guard);
    if (prefs is! TrackedSharedPreferences ||
        !_storeLease!.bindOriginalStore(prefs.store)) {
      throw const CredentialVaultAdmissionDenied();
    }
  }

  Future<CloudOAuthPair?> load({bool Function()? isCurrent}) async {
    final guard = isCurrent ?? captureGuard();
    try {
      await _bind(guard);
      check(guard);
      final present = await _vault.hasStoredValue(_slot);
      check(guard);
      if (!present) {
        await _legacy.importIfAbsent(
          vault: _vault,
          slot: _slot,
          provider: provider,
          redaction: redaction,
          isCurrent: () => current && guard(),
        );
        check(guard);
      }
      return await CloudOAuthPreferences.serialize(() async {
        check(guard);
        final metadata = await _vault.metadata(_slot);
        check(guard);
        CloudOAuthPair? pair;
        if (metadata.configured) {
          await _vault.useSecret(_slot, (raw) async {
            check(guard);
            pair = decodeCloudOAuthPair(jsonDecode(raw), provider, redaction);
          });
          check(guard);
        }
        _cached = pair;
        final loadedPair = pair;
        if (loadedPair != null)
          _receipts[loadedPair] = _CloudCredentialReceipt(
            _epoch,
            _admission.generation,
          );
        return pair;
      });
    } catch (error) {
      if (current && guard())
        _cached = null; // Never erase a newer operation's cache.
      if (error is CloudOAuthRetiredCommit) rethrow;
      if (error is CredentialVaultAdmissionDenied) rethrow;
      check(guard);
      throw const CredentialVaultException(
        CredentialVaultFailure.storageUnavailable,
      );
    }
  }

  Future<void> store(CloudOAuthPair? pair, bool Function() guard) async {
    CloudOAuthCommitReceipt? settled;
    if (pair != null) {
      registerSecret(pair.accessToken);
      registerSecret(pair.refreshToken);
      decodeCloudOAuthPair(
        jsonDecode(pair.encode(provider)),
        provider,
        redaction,
      );
    }
    await _bind(guard);
    check(guard);
    await CloudOAuthPreferences.serialize(() async {
      check(guard);
      try {
        await _vault.storeGuarded(
          _slot,
          pair?.encode(provider) ?? '',
          isCurrent: () => current && guard(),
        );
        settled = CloudOAuthCommitReceipt._(
          provider,
          disconnected: pair == null,
        );
        // Physical verified replacement, not refresh-attempt admission, retires
        // tokens previously admitted by other workflows on this stable graph.
        _admission.generation++;
      } catch (error) {
        if (current && guard()) _cached = null;
        // storeGuarded reports admission denial only BEFORE backend invocation.
        // Its storage/verification exception means an invoked write whose
        // durable outcome was not established, even if ownership is now gone.
        if (error is CredentialVaultException && (!current || !guard())) {
          throw CloudOAuthCommitUnknown._(provider, error.failure);
        }
        check(guard);
        rethrow;
      }
      if (!current || !guard()) {
        throw CloudOAuthCommittedButRetired._(settled!);
      }
      _cached = pair;
      if (pair != null)
        _receipts[pair] = _CloudCredentialReceipt(
          _epoch,
          _admission.generation,
        );
    });
    if (!current || !guard()) throw CloudOAuthCommittedButRetired._(settled!);
  }

  /// Binding updates read the CURRENT protected pair inside the same cloud FIFO.
  /// A folder/account callback cannot write back an older refreshed token pair.
  Future<void> bindMetadata(
    bool Function() guard, {
    String? folderId,
    String? accountId,
  }) async {
    CloudOAuthCommitReceipt? settled;
    await _bind(guard);
    check(guard);
    await CloudOAuthPreferences.serialize(() async {
      check(guard);
      late CloudOAuthPair pair;
      try {
        await _vault.useSecret(_slot, (raw) async {
          check(guard);
          pair = decodeCloudOAuthPair(jsonDecode(raw), provider, redaction);
        });
      } catch (_) {
        if (current && guard()) _cached = null;
        check(guard);
        rethrow;
      }
      check(guard);
      if (accountId != null &&
          pair.accountId != null &&
          pair.accountId != accountId) {
        throw const CredentialVaultException(
          CredentialVaultFailure.verificationFailed,
        );
      }
      if (folderId != null) pair = pair.withFolder(folderId);
      if (accountId != null) pair = pair.withAccount(accountId);
      final encoded = pair.encode(provider);
      decodeCloudOAuthPair(jsonDecode(encoded), provider, redaction);
      try {
        await _vault.storeGuarded(
          _slot,
          encoded,
          isCurrent: () => current && guard(),
        );
      } catch (error) {
        if (current && guard()) _cached = null;
        if (error is CredentialVaultException && (!current || !guard())) {
          throw CloudOAuthCommitUnknown._(provider, error.failure);
        }
        check(guard);
        rethrow;
      }
      settled = CloudOAuthCommitReceipt._(provider);
      if (!current || !guard()) {
        throw CloudOAuthCommittedButRetired._(settled!);
      }
      _cached = pair;
      _receipts[pair] = _CloudCredentialReceipt(_epoch, _admission.generation);
    });
    if (!current || !guard()) throw CloudOAuthCommittedButRetired._(settled!);
  }

  /// Explicit disconnect captures the old pair, then immediately retires users.
  /// Local verified tombstone is settled BEFORE best-effort remote revocation.
  Future<CloudOAuthDisconnectOutcome> disconnect(
    Future<void> Function(String token, bool Function() guard) revoke,
  ) async {
    final old = _cached;
    final guard = beginOperation();
    _cached = null;
    await store(null, guard);
    check(guard);
    if (old != null) {
      try {
        await revoke(old.accessToken, guard);
      } catch (_) {
        check(guard);
        return const CloudOAuthDisconnectOutcome(remoteComplete: false);
      }
      check(guard);
    }
    return const CloudOAuthDisconnectOutcome(remoteComplete: true);
  }

  void dispose() {
    _disposed = true;
    _cached = null;
  }

  @override
  String toString() => 'CloudOAuthCredentialOwner';
}

final class _CloudAdmission {
  int epoch = 0, refresh = 0, generation = 0;
  SecretRedactionCoordinator? redaction;
}

final class _CloudCredentialReceipt {
  const _CloudCredentialReceipt(this.epoch, this.generation);
  final int epoch, generation;
}

/// A native acknowledgement, never JSON authority or a credential grant.
final class CloudOAuthCommitReceipt {
  const CloudOAuthCommitReceipt._(this.provider, {this.disconnected = false});
  final CloudOAuthProvider provider;
  final bool disconnected;
  bool get committed => true;
  @override
  String toString() => 'Cloud OAuth commit receipt';
}

abstract interface class CloudOAuthRetiredCommit implements Exception {}

/// An invoked secure write failed to establish its original readback. No
/// credential grant, success acknowledgement, rollback or no-effect claim.
final class CloudOAuthCommitUnknown implements CloudOAuthRetiredCommit {
  const CloudOAuthCommitUnknown._(this.provider, this.failure);
  final CloudOAuthProvider provider;
  final CredentialVaultFailure failure;
  bool get writeInvoked => true;
  bool? get committed => null;
  @override
  String toString() =>
      'Cloud OAuth write invoked; commit unknown; operation retired';
}

final class CloudOAuthCommittedButRetired implements CloudOAuthRetiredCommit {
  const CloudOAuthCommittedButRetired._(this.receipt);
  final CloudOAuthCommitReceipt receipt;
  @override
  String toString() => 'Cloud OAuth storage committed; operation retired';
}

final class CloudOAuthDisconnectOutcome {
  const CloudOAuthDisconnectOutcome({required this.remoteComplete});
  bool get localDisconnected => true;
  final bool remoteComplete;
  String? get warning => remoteComplete
      ? null
      : 'Disconnected locally; remote revocation could not be confirmed';
}
