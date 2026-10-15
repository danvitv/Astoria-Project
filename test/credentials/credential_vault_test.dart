import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_metadata.dart';
import 'package:glaze_flutter/core/credentials/credential_slot.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';

import 'fake_credential_storage.dart';

void main() {
  const canary = 'TEST_ONLY_CANARY_🔐_кириллица';
  final slot = CredentialSlot(domain: 'llm', id: 'connection-1');
  late FakeCredentialStorage storage;
  late CredentialVault vault;

  setUp(() {
    storage = FakeCredentialStorage();
    vault = CredentialVault(storage: storage, buildChannel: 'dev');
  });

  test('metadata counts Unicode code points, not UTF-16/graphemes', () {
    final metadata = CredentialMetadata.fromSecret('A🔐е\u0301');
    expect(metadata.characterCount, 4);
    expect(metadata.configured, isTrue);
    expect(
      jsonEncode(metadata.toJson()),
      '{"configured":true,"characterCount":4}',
    );
    expect(metadata.toString(), isNot(contains('🔐')));
    expect(CredentialMetadata.fromSecret('').toJson(), {
      'configured': false,
      'characterCount': 0,
    });
    expect(CredentialMetadata.fromSecret(null), CredentialMetadata.absent);
  });

  test(
    'store/read/use/delete expose only metadata outside native consumer',
    () async {
      final saved = await vault.store(slot, canary);
      expect(saved.characterCount, canary.runes.length);
      expect(jsonEncode(saved.toJson()), isNot(contains(canary)));
      expect((await vault.metadata(slot)).configured, isTrue);
      var consumed = false;
      await vault.useSecret(slot, (secret) async {
        expect(secret, canary);
        consumed = true;
      });
      expect(consumed, isTrue);
      await vault.delete(slot);
      expect((await vault.metadata(slot)).configured, isFalse);
      await expectLater(
        vault.useSecret(slot, (_) async => fail('must not run')),
        throwsA(isA<CredentialVaultException>()),
      );
      expect(vault.toString(), isNot(contains(canary)));
      expect(slot.toString(), 'CredentialSlot');
    },
  );

  test('injected channels isolate identical slots in shared storage', () async {
    final stable = CredentialVault(storage: storage, buildChannel: 'stable');
    await vault.store(slot, canary);
    expect((await stable.metadata(slot)).configured, isFalse);
    await stable.store(slot, 'STABLE_TEST_ONLY');
    expect(storage.values.length, 2);
    expect((await vault.metadata(slot)).characterCount, canary.runes.length);
    expect(
      () => CredentialVault(storage: storage, buildChannel: canary),
      throwsA(predicate((Object e) => !e.toString().contains(canary))),
    );
    expect(
      () => CredentialSlot(domain: canary, id: 'a'),
      throwsA(predicate((Object e) => !e.toString().contains(canary))),
    );
  });

  test('storage errors fail closed without secret-bearing causes', () async {
    storage.readError = StateError('storage $canary');
    await expectLater(
      vault.metadata(slot),
      throwsA(
        predicate(
          (Object e) =>
              e is CredentialVaultException && !e.toString().contains(canary),
        ),
      ),
    );
    await expectLater(
      vault.importIfAbsent(slot, canary),
      throwsA(isA<CredentialVaultException>()),
    );
    expect(storage.operations, ['read', 'read']);
    storage.readError = null;
    storage.writeError = StateError(canary);
    await expectLater(
      vault.store(slot, canary),
      throwsA(predicate((Object e) => !e.toString().contains(canary))),
    );
    storage.writeError = null;
    await vault.store(slot, canary);
    storage.deleteError = StateError(canary);
    await expectLater(
      vault.delete(slot),
      throwsA(predicate((Object e) => !e.toString().contains(canary))),
    );
    expect(storage.values.values.single, canary);
  });

  test(
    'writes/deletes require readback; no silent platform fallback',
    () async {
      storage.dropWrites = true;
      await expectLater(
        vault.store(slot, canary),
        throwsA(
          isA<CredentialVaultException>().having(
            (e) => e.failure,
            'failure',
            CredentialVaultFailure.verificationFailed,
          ),
        ),
      );
      storage.dropWrites = false;
      await vault.store(slot, canary);
      storage.dropDeletes = true;
      await expectLater(
        vault.delete(slot),
        throwsA(isA<CredentialVaultException>()),
      );
      expect(storage.values.values.single, canary);
    },
  );

  test(
    'failed migration read never overwrites a previously stored key',
    () async {
      await vault.store(slot, 'ORIGINAL_TEST_ONLY');
      storage.operations.clear();
      storage.readError = StateError(canary);
      await expectLater(
        vault.importIfAbsent(slot, canary),
        throwsA(isA<CredentialVaultException>()),
      );
      expect(storage.operations, ['read']);
      expect(storage.values.values.single, 'ORIGINAL_TEST_ONLY');
      storage.readError = null;
      await vault.importIfAbsent(slot, canary);
      expect(storage.values.values.single, 'ORIGINAL_TEST_ONLY');
    },
  );

  test(
    'failed migration readback retains written key for safe retry',
    () async {
      storage.beforeWrite = () async {
        storage.readError = StateError(canary);
      };
      await expectLater(
        vault.importIfAbsent(slot, canary),
        throwsA(isA<CredentialVaultException>()),
      );
      expect(storage.values.values.single, canary);
      storage.beforeWrite = null;
      storage.readError = null;
      storage.operations.clear();
      await vault.importIfAbsent(slot, 'DIFFERENT_TEST_ONLY');
      expect(storage.operations, ['read']);
      expect(storage.values.values.single, canary);
    },
  );

  test(
    'same-slot operations are FIFO, other slots progress independently',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var first = true;
      storage.beforeWrite = () async {
        if (first) {
          first = false;
          entered.complete();
          await release.future;
        }
      };
      final firstWrite = vault.store(slot, canary);
      await entered.future;
      final secondWrite = vault.store(slot, 'SECOND_TEST_ONLY');
      final queuedMetadata = vault.metadata(slot);
      await vault.store(
        CredentialSlot(domain: 'llm', id: 'other'),
        'OTHER_TEST',
      );
      expect(storage.operations, ['write', 'write', 'read']);
      release.complete();
      await firstWrite;
      await secondWrite;
      expect((await queuedMetadata).characterCount, 'SECOND_TEST_ONLY'.length);
    },
  );

  test(
    'simultaneous imports never overwrite the first completed import',
    () async {
      await Future.wait([
        vault.importIfAbsent(slot, canary),
        vault.importIfAbsent(slot, 'SECOND_TEST_ONLY'),
      ]);
      expect(storage.values.values.single, canary);
      expect(
        storage.operations.where((operation) => operation == 'write').length,
        1,
      );
    },
  );

  test(
    'migration preserves an existing empty value rather than replacing it',
    () async {
      await vault.store(slot, '');
      storage.operations.clear();
      final result = await vault.importIfAbsent(slot, canary);
      expect(result.configured, isFalse);
      expect(storage.values.values.single, '');
      expect(storage.operations, ['read']);
    },
  );

  test(
    'failed queued operation does not poison subsequent operations',
    () async {
      storage.writeError = StateError(canary);
      await expectLater(
        vault.store(slot, canary),
        throwsA(isA<CredentialVaultException>()),
      );
      storage.writeError = null;
      expect((await vault.store(slot, canary)).configured, isTrue);
      await expectLater(
        vault.useSecret(slot, (_) async {
          throw StateError(canary);
        }),
        throwsA(predicate((Object e) => !e.toString().contains(canary))),
      );
    },
  );
}
