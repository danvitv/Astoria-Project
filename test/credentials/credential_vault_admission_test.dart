import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_slot.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';

import 'fake_credential_storage.dart';

/// Mandatory constructor-injected in-memory storage: no default/plugin/file/
/// network path exists in these vault operations. All values are synthetic.
void main() {
  const synthetic = 'SYNTHETIC_NATIVE_ENTRY_🔐_е\u0301';
  final slot = CredentialSlot(
    domain: 'api_config.native_llm',
    id: 'synthetic-1',
  );
  late FakeCredentialStorage storage;
  late CredentialVault vault;

  setUp(() {
    storage = FakeCredentialStorage();
    vault = CredentialVault(storage: storage, buildChannel: 'dev');
  });

  test(
    'presence distinguishes physically empty from absent without seeding',
    () async {
      expect(await vault.hasStoredValue(slot), isFalse);
      await vault.store(slot, '');
      storage.operations.clear();
      expect(await vault.hasStoredValue(slot), isTrue);
      expect((await vault.metadata(slot)).configured, isFalse);
      expect(storage.values.values.single, isEmpty);
      expect(storage.operations, ['read', 'read']);
      await vault.store(slot, synthetic);
      storage.operations.clear();
      expect(await vault.hasStoredValue(slot), isTrue);
      expect(storage.operations, ['read']);
      expect(storage.values.values.single, synthetic);
    },
  );

  test(
    'presence failure is not absence or a secret-bearing exception',
    () async {
      storage.readError = StateError(synthetic);
      await expectLater(
        vault.hasStoredValue(slot),
        throwsA(
          predicate(
            (Object e) =>
                e is CredentialVaultException &&
                !e.toString().contains(synthetic),
          ),
        ),
      );
      expect(storage.operations, ['read']);
      expect(storage.values, isEmpty);
    },
  );

  test('revocation before slot execution invokes no backend write', () async {
    var current = true;
    final queued = vault.storeGuarded(
      slot,
      synthetic,
      isCurrent: () => current,
    );
    final refused = expectLater(
      queued,
      throwsA(isA<CredentialVaultAdmissionDenied>()),
    );
    current = false;
    await refused;
    expect(storage.operations, isEmpty);
    expect(storage.values, isEmpty);
  });

  test('same-slot await cannot admit a revoked second write', () async {
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
    final original = vault.store(slot, synthetic);
    Future<void>? refusal;
    try {
      await entered.future;
      var current = true;
      final queued = vault.storeGuarded(
        slot,
        'SYNTHETIC_REPLACEMENT',
        isCurrent: () => current,
      );
      refusal = expectLater(
        queued,
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      await vault.store(
        CredentialSlot(domain: 'llm', id: 'other'),
        'SYNTHETIC_OTHER',
      );
      current = false;
      expect(storage.operations.where((op) => op == 'write'), hasLength(2));
      release.complete();
      await original;
      await refusal;
      expect(
        (await vault.metadata(slot)).characterCount,
        synthetic.runes.length,
      );
      expect(storage.values.values, isNot(contains('SYNTHETIC_REPLACEMENT')));
    } finally {
      if (!release.isCompleted) release.complete();
      await original;
      await refusal;
    }
  });

  test(
    'throwing admission is fixed denial and does not poison the FIFO',
    () async {
      await expectLater(
        vault.storeGuarded(
          slot,
          synthetic,
          isCurrent: () => throw StateError(synthetic),
        ),
        throwsA(
          predicate(
            (Object e) =>
                e is CredentialVaultAdmissionDenied &&
                !e.toString().contains(synthetic),
          ),
        ),
      );
      expect(storage.operations, isEmpty);
      final saved = await vault.store(slot, synthetic);
      expect(saved.characterCount, synthetic.runes.length);
      expect(jsonEncode(saved.toJson()), isNot(contains(synthetic)));
      expect(storage.operations, ['write', 'read']);
    },
  );

  test(
    'started original write verifies after retirement without retry',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var current = true;
      var checks = 0;
      storage.beforeWrite = () async {
        entered.complete();
        await release.future;
      };
      final original = vault.storeGuarded(
        slot,
        synthetic,
        isCurrent: () {
          checks++;
          return current;
        },
      );
      try {
        await entered.future;
        current = false;
        release.complete();
        final factual = await original;
        expect(factual.configured, isTrue);
        expect(factual.characterCount, synthetic.runes.length);
        expect(jsonEncode(factual.toJson()), isNot(contains(synthetic)));
        expect(checks, 1);
        expect(storage.operations, ['write', 'read']);
        expect(storage.values.values.single, synthetic);
      } finally {
        if (!release.isCompleted) release.complete();
        await original;
      }
    },
  );

  test(
    'guarded storage failures never delete, retry or disclose causes',
    () async {
      storage.writeError = StateError(synthetic);
      await expectLater(
        vault.storeGuarded(slot, synthetic, isCurrent: () => true),
        throwsA(
          predicate(
            (Object e) =>
                e is CredentialVaultException &&
                !e.toString().contains(synthetic),
          ),
        ),
      );
      expect(storage.operations, ['write']);
      storage.writeError = null;
      storage.dropWrites = true;
      await expectLater(
        vault.storeGuarded(slot, synthetic, isCurrent: () => true),
        throwsA(
          isA<CredentialVaultException>().having(
            (e) => e.failure,
            'failure',
            CredentialVaultFailure.verificationFailed,
          ),
        ),
      );
      expect(storage.operations, ['write', 'write', 'read']);
      expect(storage.values, isEmpty);
    },
  );

  test(
    'guarded import verifies an already-invoked write after revocation',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      var current = true, checks = 0;
      storage.beforeWrite = () async {
        entered.complete();
        await release.future;
      };
      final importing = vault.importIfAbsentGuarded(
        slot,
        synthetic,
        isCurrent: () {
          checks++;
          return current;
        },
      );
      await entered.future;
      current = false;
      release.complete();
      final committed = await importing;
      expect(committed.configured, true);
      expect(checks, 2);
      expect(storage.operations, ['read', 'write', 'read']);
      expect(storage.values.values.single, synthetic);
    },
  );

  test(
    'throwing import admission is sanitized and preserves slot FIFO',
    () async {
      await expectLater(
        vault.importIfAbsentGuarded(
          slot,
          synthetic,
          isCurrent: () => throw StateError(synthetic),
        ),
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      expect(storage.operations, isEmpty);
      await vault.store(slot, synthetic);
      expect(storage.values.values.single, synthetic);
    },
  );
}
