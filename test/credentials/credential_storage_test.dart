import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_storage.dart';

final class _SyntheticSecureStorage extends FlutterSecureStorage {
  _SyntheticSecureStorage();

  final values = <String, String>{};
  final androidCalls = <AndroidOptions?>[];
  final macCalls = <AppleOptions?>[];
  bool fail = false;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WindowsOptions? wOptions,
    AppleOptions? mOptions,
    WebOptions? webOptions,
  }) async {
    androidCalls.add(aOptions);
    macCalls.add(mOptions);
    if (fail) throw StateError('ADAPTER_TEST_ONLY_CANARY');
    return values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WindowsOptions? wOptions,
    AppleOptions? mOptions,
    WebOptions? webOptions,
  }) async {
    androidCalls.add(aOptions);
    macCalls.add(mOptions);
    if (fail) throw StateError('ADAPTER_TEST_ONLY_CANARY');
    if (value != null) values[key] = value;
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WindowsOptions? wOptions,
    AppleOptions? mOptions,
    WebOptions? webOptions,
  }) async {
    androidCalls.add(aOptions);
    macCalls.add(mOptions);
    if (fail) throw StateError('ADAPTER_TEST_ONLY_CANARY');
    values.remove(key);
  }
}

void main() {
  test(
    'platform adapter delegates only scoped operations and suppresses causes',
    () async {
      final platform = _SyntheticSecureStorage();
      final adapter = FlutterSecureCredentialStorage(
        platform,
        buildChannel: 'dev',
      );
      const canary = 'ADAPTER_TEST_ONLY_CANARY';
      await adapter.write('synthetic', canary);
      expect(await adapter.read('synthetic'), canary);
      await adapter.delete('synthetic');
      expect(await adapter.read('synthetic'), isNull);
      platform.fail = true;
      for (final operation in [
        () => adapter.read('synthetic'),
        () => adapter.write('synthetic', canary),
        () => adapter.delete('synthetic'),
      ]) {
        await expectLater(
          operation(),
          throwsA(
            predicate((Object error) => !error.toString().contains(canary)),
          ),
        );
      }
      expect(adapter.toString(), isNot(contains(canary)));
    },
  );

  test(
    'all operations override unsafe defaults with fail-closed options',
    () async {
      final platform = _SyntheticSecureStorage();
      expect(platform.aOptions.toMap()['resetOnError'], 'true');
      final adapter = FlutterSecureCredentialStorage(
        platform,
        buildChannel: 'dev',
      );
      await adapter.read('synthetic');
      await adapter.write('synthetic', 'TEST_ONLY');
      await adapter.delete('synthetic');
      expect(platform.androidCalls, hasLength(3));
      expect(platform.macCalls, hasLength(3));
      for (final options in platform.androidCalls) {
        expect(options!.toMap()['resetOnError'], 'false');
        expect(options.toMap()['migrateWithBackup'], 'true');
        expect(options.storageNamespace, 'app.astoria.credentials.v1.dev');
      }
      for (final options in platform.macCalls) {
        expect(options, isA<MacOsOptions>());
        expect(options!.toMap()['usesDataProtectionKeychain'], 'false');
      }
    },
  );

  test(
    'explicit unsafe options cannot re-enable reset or replace namespace',
    () async {
      final platform = _SyntheticSecureStorage();
      final adapter = FlutterSecureCredentialStorage(
        platform,
        buildChannel: 'stable',
        androidOptions: const AndroidOptions(
          resetOnError: true,
          migrateWithBackup: false,
          storageNamespace: 'unsafe',
          enforceBiometrics: true,
        ),
      );
      await adapter.read('synthetic');
      await adapter.write('synthetic', 'TEST_ONLY');
      await adapter.delete('synthetic');
      for (final options in platform.androidCalls) {
        expect(options!.toMap()['resetOnError'], 'false');
        expect(options.toMap()['migrateWithBackup'], 'true');
        expect(options.toMap()['enforceBiometrics'], 'true');
        expect(options.storageNamespace, 'app.astoria.credentials.v1.stable');
      }
      expect(
        () => FlutterSecureCredentialStorage(
          platform,
          buildChannel: 'bad channel',
        ),
        throwsFormatException,
      );
    },
  );
}
