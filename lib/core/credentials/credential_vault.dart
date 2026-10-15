import 'dart:async';

import 'credential_metadata.dart';
import 'credential_slot.dart';
import 'credential_storage.dart';

enum CredentialVaultFailure { storageUnavailable, verificationFailed, missing }

/// Deliberately has no underlying exception, storage key, or secret value.
final class CredentialVaultException implements Exception {
  const CredentialVaultException(this.failure);

  final CredentialVaultFailure failure;

  @override
  String toString() => 'CredentialVaultException(${failure.name})';
}

/// Feature-free, trusted secret owner; never expose it to model-facing tools.
///
/// Create one owner per storage/build-channel namespace in the composition root.
/// Operations on the same slot are FIFO, including reads and import-if-absent.
/// Different slots do not contend. This is not a cross-process transaction lock.
final class CredentialVault {
  CredentialVault({
    required CredentialStorage storage,
    required String buildChannel,
    // Keep the dependency private while preserving a public named argument.
    // ignore: prefer_initializing_formals
  }) : _storage = storage {
    if (!RegExp(r'^[a-z][a-z0-9_-]{0,31}$').hasMatch(buildChannel)) {
      throw const FormatException('Invalid credential build channel');
    }
    _namespace = 'app.astoria.credentials.v1.$buildChannel.';
  }

  final CredentialStorage _storage;
  late final String _namespace;
  final Map<String, Future<void>> _pending = {};

  Future<CredentialMetadata> metadata(CredentialSlot slot) =>
      _serialize(slot, (key) async {
        final secret = await _read(key);
        return CredentialMetadata.fromSecret(secret);
      });

  /// Native secret-entry path. This is an explicit replacement, not migration.
  Future<CredentialMetadata> store(CredentialSlot slot, String secret) =>
      _serialize(slot, (key) => _writeVerified(key, secret));

  /// Foundation for a later migration; no legacy/runtime data is read here.
  /// A failed read MUST NOT be interpreted as absence. Existing values, even an
  /// empty stored value, are preserved. Verification failure never clears keys.
  Future<CredentialMetadata> importIfAbsent(
    CredentialSlot slot,
    String secret,
  ) => _serialize(slot, (key) async {
    final current = await _read(key);
    if (current != null) return CredentialMetadata.fromSecret(current);
    return _writeVerified(key, secret);
  });

  Future<void> delete(CredentialSlot slot) => _serialize(slot, (key) async {
    try {
      await _storage.delete(key);
    } catch (_) {
      throw const CredentialVaultException(
        CredentialVaultFailure.storageUnavailable,
      );
    }
    if (await _read(key) != null) {
      throw const CredentialVaultException(
        CredentialVaultFailure.verificationFailed,
      );
    }
  });

  /// Only an injected, trusted native consumer may receive the ephemeral value.
  /// No secret-returning API or DTO is provided. Dart strings cannot be zeroed;
  /// consumers must not retain, return, capture in errors, or log this argument.
  Future<void> useSecret(
    CredentialSlot slot,
    Future<void> Function(String secret) consume,
  ) async {
    final secret = await _serialize(slot, _read);
    if (secret == null || secret.isEmpty) {
      throw const CredentialVaultException(CredentialVaultFailure.missing);
    }
    try {
      await consume(secret);
    } catch (_) {
      // A native consumer may accidentally throw an error containing the key.
      throw const CredentialVaultException(
        CredentialVaultFailure.storageUnavailable,
      );
    }
  }

  Future<String?> _read(String key) async {
    try {
      return await _storage.read(key);
    } catch (_) {
      throw const CredentialVaultException(
        CredentialVaultFailure.storageUnavailable,
      );
    }
  }

  Future<CredentialMetadata> _writeVerified(String key, String secret) async {
    try {
      await _storage.write(key, secret);
    } catch (_) {
      throw const CredentialVaultException(
        CredentialVaultFailure.storageUnavailable,
      );
    }
    if (await _read(key) != secret) {
      throw const CredentialVaultException(
        CredentialVaultFailure.verificationFailed,
      );
    }
    return CredentialMetadata.fromSecret(secret);
  }

  Future<T> _serialize<T>(
    CredentialSlot slot,
    Future<T> Function(String key) operation,
  ) {
    final key = '$_namespace${slot.storageSuffix}';
    final previous = _pending[key] ?? Future<void>.value();
    final result = previous.then((_) => operation(key));
    // The queue tail absorbs errors, while each caller receives its own error.
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _pending[key] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_pending[key], tail)) _pending.remove(key);
      }),
    );
    return result;
  }

  @override
  String toString() => 'CredentialVault';
}
