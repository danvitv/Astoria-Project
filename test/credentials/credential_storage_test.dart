import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_storage.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';

final class _SyntheticSecureStorage extends FlutterSecureStorage {
  _SyntheticSecureStorage();

  final values = <String, String>{};
  final androidCalls = <AndroidOptions?>[];
  final macCalls = <AppleOptions?>[];
  final existingCalls = <AndroidOptions?>[];
  bool fail = false;

  @override
  Future<String?> readExisting({
    required String key,
    AndroidOptions? aOptions,
  }) async {
    existingCalls.add(aOptions);
    if (fail) throw StateError('ADAPTER_TEST_ONLY_CANARY');
    return values[key];
  }

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
  for (final fixture in [
    (label: 'missing', value: null, failure: SupportCipherFailure.keyMissing),
    (label: 'empty', value: '', failure: SupportCipherFailure.keyMissing),
    (
      label: 'malformed',
      value: 'TEST_ONLY_BAD_KEY',
      failure: SupportCipherFailure.invalidKey,
    ),
    (
      label: 'short',
      value: base64UrlEncode(List<int>.filled(31, 5)),
      failure: SupportCipherFailure.invalidKey,
    ),
  ]) {
    test(
      'existing-only key preflight refuses ${fixture.label} without mutation',
      () async {
        final platform = _SyntheticSecureStorage();
        final storageKey =
            'app.astoria.credentials.v1.dev.${SupportPayloadCipher.installKeySlot.storageSuffix}';
        final value = fixture.value;
        if (value != null) platform.values[storageKey] = value;
        final before = Map<String, String>.of(platform.values);
        final cipher = SupportPayloadCipher(
          vault: CredentialVault(
            storage: FlutterSecureCredentialStorage.existingOnly(
              platform,
              buildChannel: 'dev',
            ),
            buildChannel: 'dev',
          ),
        );
        await expectLater(
          cipher.requireExistingInstallationKey(),
          throwsA(
            isA<SupportCipherException>().having(
              (error) => error.failure,
              'failure',
              fixture.failure,
            ),
          ),
        );
        expect(platform.values, before);
        expect(platform.existingCalls, hasLength(1));
        expect(platform.androidCalls, isEmpty);
        expect(platform.macCalls, isEmpty);
      },
    );
  }

  test(
    'existing-only key supports genuine decrypt without ordinary storage',
    () async {
      final platform = _SyntheticSecureStorage();
      final storageKey =
          'app.astoria.credentials.v1.dev.${SupportPayloadCipher.installKeySlot.storageSuffix}';
      platform.values[storageKey] = base64UrlEncode(List<int>.filled(32, 5));
      final before = Map<String, String>.of(platform.values);
      final cipher = SupportPayloadCipher(
        vault: CredentialVault(
          storage: FlutterSecureCredentialStorage.existingOnly(
            platform,
            buildChannel: 'dev',
          ),
          buildChannel: 'dev',
        ),
      );
      // Synthetic fixture preparation: the known key already exists; no mint/write.
      final envelope = await cipher.encrypt(
        plaintext: 'TEST_ONLY_BODY',
        table: 'support_messages',
        rowId: 'test_row',
        field: 'body',
      );
      final readOnly = SupportPayloadCipher.readOnly(
        delegate: cipher,
        gate: (work) => work(),
      );
      await readOnly.requireExistingInstallationKey();
      expect(
        await readOnly.decrypt(
          envelopeText: envelope,
          table: 'support_messages',
          rowId: 'test_row',
          field: 'body',
        ),
        'TEST_ONLY_BODY',
      );
      await expectLater(
        readOnly.encrypt(
          plaintext: 'NO_WRITE',
          table: 'support_messages',
          rowId: 'test_row',
          field: 'body',
        ),
        throwsA(isA<SupportCipherException>()),
      );
      expect(platform.values, before);
      expect(platform.androidCalls, isEmpty);
      expect(platform.macCalls, isEmpty);
      expect(platform.existingCalls, isNotEmpty);
    },
  );

  test(
    'existing-only adapter never invokes ordinary storage or mutations',
    () async {
      final platform = _SyntheticSecureStorage();
      platform.values['synthetic'] = 'TEST_ONLY_EXISTING';
      final adapter = FlutterSecureCredentialStorage.existingOnly(
        platform,
        buildChannel: 'dev',
      );
      expect(await adapter.read('synthetic'), 'TEST_ONLY_EXISTING');
      expect(await adapter.read('absent'), isNull);
      await expectLater(
        adapter.write('synthetic', 'REPLACEMENT'),
        throwsStateError,
      );
      await expectLater(adapter.delete('synthetic'), throwsStateError);
      expect(platform.values, {'synthetic': 'TEST_ONLY_EXISTING'});
      expect(platform.androidCalls, isEmpty);
      expect(platform.macCalls, isEmpty);
      expect(platform.existingCalls, hasLength(2));
      for (final options in platform.existingCalls) {
        expect(options!.storageNamespace, 'app.astoria.credentials.v1.dev');
      }
      platform.fail = true;
      await expectLater(
        adapter.read('synthetic'),
        throwsA(
          predicate((Object error) => !error.toString().contains('CANARY')),
        ),
      );
    },
  );

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
