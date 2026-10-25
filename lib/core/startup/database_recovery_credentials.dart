import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../constants/build_channel.dart';
import '../credentials/credential_storage.dart';
import '../credentials/credential_vault.dart';
import '../db/repositories/database_restore_repo.dart';
import '../support/support_payload_cipher.dart';

/// Construct only after a fresh picker. Retain this storage/vault/cipher owner
/// through accepted handoff, rather than replacing a read-only vault afterwards.
final class DatabaseRecoveryCredentials {
  DatabaseRecoveryCredentials({required this.storage, required String channel})
    : vault = CredentialVault(storage: storage, buildChannel: channel) {
    cipher = SupportPayloadCipher(vault: vault);
  }

  factory DatabaseRecoveryCredentials.native() => Platform.isAndroid
      ? DatabaseRecoveryCredentials.android(
          storage: const FlutterSecureStorage(),
          channel: buildChannel,
        )
      : DatabaseRecoveryCredentials(
          storage: FlutterSecureCredentialStorage(
            const FlutterSecureStorage(),
            buildChannel: buildChannel,
          ),
          channel: buildChannel,
        );

  /// Both backends use the SAME native instance, algorithms and namespace.
  /// Creation calls no platform method and grants no ordinary storage access.
  factory DatabaseRecoveryCredentials.android({
    required FlutterSecureStorage storage,
    required String channel,
  }) => DatabaseRecoveryCredentials(
    storage: _RecoveryCredentialStorage(
      existing: FlutterSecureCredentialStorage.existingOnly(
        storage,
        buildChannel: channel,
      ),
      ordinary: FlutterSecureCredentialStorage(storage, buildChannel: channel),
    ),
    channel: channel,
  );

  final CredentialStorage storage;
  final CredentialVault vault;
  late final SupportPayloadCipher cipher;

  /// A real accepted capability for the SAME startup owner is required. A flag,
  /// proposal, completed key read or caller boolean cannot enable ordinary IO.
  void enableNormalStorage(
    AcceptedDatabaseRestore accepted,
    NativeDatabaseStartupOwner startup,
  ) {
    if (!accepted.belongsToStartup(startup)) {
      throw const DatabaseRestoreException(DatabaseRestoreCode.stale);
    }
    if (storage case final _RecoveryCredentialStorage scoped) {
      scoped._accept(accepted, startup);
    }
  }
}

final class _RecoveryCredentialStorage implements CredentialStorage {
  _RecoveryCredentialStorage({required this.existing, required this.ordinary});
  final CredentialStorage existing;
  final CredentialStorage ordinary;
  AcceptedDatabaseRestore? _accepted;

  void _accept(
    AcceptedDatabaseRestore accepted,
    NativeDatabaseStartupOwner startup,
  ) {
    if (_accepted != null || !accepted.belongsToStartup(startup)) {
      throw const DatabaseRestoreException(DatabaseRestoreCode.stale);
    }
    _accepted = accepted; // Irreversible, before normal provider installation.
  }

  CredentialStorage get _current => _accepted == null ? existing : ordinary;
  @override
  Future<String?> read(String key) => _current.read(key);
  @override
  Future<void> write(String key, String value) => _current.write(key, value);
  @override
  Future<void> delete(String key) => _current.delete(key);
  @override
  String toString() => 'RecoveryCredentialStorage(opaque)';
}
