import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A trusted storage boundary. Never inject this interface into assistant tools.
/// Implementations must throw on failure, not silently use plaintext storage.
abstract interface class CredentialStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Enforces non-destructive Android recovery and the macOS keychain mode on
/// every operation, even if the injected plugin has unsafe default options.
/// Inject the same build channel here and into the vault; no global lookup.
final class FlutterSecureCredentialStorage implements CredentialStorage {
  FlutterSecureCredentialStorage(
    this._storage, {
    required String buildChannel,
    AndroidOptions? androidOptions,
  }) {
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
  late final AndroidOptions _androidOptions;
  static const _macOptions = MacOsOptions(usesDataProtectionKeychain: false);

  @override
  Future<String?> read(String key) => _perform(
    () => _storage.read(
      key: key,
      aOptions: _androidOptions,
      mOptions: _macOptions,
    ),
  );

  @override
  Future<void> write(String key, String value) => _perform(
    () => _storage.write(
      key: key,
      value: value,
      aOptions: _androidOptions,
      mOptions: _macOptions,
    ),
  );

  @override
  Future<void> delete(String key) => _perform(
    () => _storage.delete(
      key: key,
      aOptions: _androidOptions,
      mOptions: _macOptions,
    ),
  );

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
