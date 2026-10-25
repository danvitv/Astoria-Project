import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A trusted storage boundary. Never inject this interface into assistant tools.
/// Implementations must throw on failure, not silently use plaintext storage.
abstract interface class CredentialStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Applies scoped Android options and the macOS keychain mode on every operation.
/// Ordinary Android reads may initialize the native backend. Recovery must use
/// [FlutterSecureCredentialStorage.existingOnly] instead, never ordinary reads.
/// Inject the same build channel here and into the vault; no global lookup.
final class FlutterSecureCredentialStorage implements CredentialStorage {
  FlutterSecureCredentialStorage(
    FlutterSecureStorage storage, {
    required String buildChannel,
    AndroidOptions? androidOptions,
  }) : this._(
         storage,
         buildChannel: buildChannel,
         androidOptions: androidOptions,
         existingOnly: false,
       );

  /// Android recovery boundary: read existing material without initialization.
  /// Writes/deletes are refused locally; unsupported platforms do not fall back.
  FlutterSecureCredentialStorage.existingOnly(
    FlutterSecureStorage storage, {
    required String buildChannel,
    AndroidOptions? androidOptions,
  }) : this._(
         storage,
         buildChannel: buildChannel,
         androidOptions: androidOptions,
         existingOnly: true,
       );

  FlutterSecureCredentialStorage._(
    this._storage, {
    required String buildChannel,
    required bool existingOnly,
    AndroidOptions? androidOptions,
  }) : _existingOnly = existingOnly {
    if (!RegExp(r'^[a-z][a-z0-9_-]{0,31}$').hasMatch(buildChannel)) {
      throw const FormatException('Invalid credential build channel');
    }
    _androidOptions = (androidOptions ?? _storage.aOptions).copyWith(
      resetOnError: false,
      migrateWithBackup: true,
      storageNamespace: 'app.astoria.credentials.v1.$buildChannel',
    );
  }

  final FlutterSecureStorage _storage;
  final bool _existingOnly;
  late final AndroidOptions _androidOptions;
  static const _macOptions = MacOsOptions(usesDataProtectionKeychain: false);

  @override
  Future<String?> read(String key) => _perform(
    () => _existingOnly
        ? _storage.readExisting(key: key, aOptions: _androidOptions)
        : _storage.read(
            key: key,
            aOptions: _androidOptions,
            mOptions: _macOptions,
          ),
  );

  @override
  Future<void> write(String key, String value) => _perform(() {
    if (_existingOnly) throw StateError('Credential storage write denied');
    return _storage.write(
      key: key,
      value: value,
      aOptions: _androidOptions,
      mOptions: _macOptions,
    );
  });

  @override
  Future<void> delete(String key) => _perform(() {
    if (_existingOnly) throw StateError('Credential storage delete denied');
    return _storage.delete(
      key: key,
      aOptions: _androidOptions,
      mOptions: _macOptions,
    );
  });

  Future<T> _perform<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } catch (_) {
      // Platform exceptions may include arguments; never forward the cause.
      throw StateError('Credential storage operation failed');
    }
  }

  @override
  String toString() => 'FlutterSecureCredentialStorage';
}
