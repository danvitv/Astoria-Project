import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_workspace_settings_codec.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_workspace_store.dart';
import '../credentials/fake_credential_storage.dart';

/// Real AEAD with deterministic test-only checkpoints; never production keys.
class _ControlledCipher implements Cipher {
  final Cipher delegate = Xchacha20.poly1305Aead();
  Future<void> Function(String aad)? afterEncrypt, beforeDecrypt;
  @override
  List<int> newNonce() => delegate.newNonce();
  @override
  Future<SecretBox> encrypt(
    List<int> clearText, {
    required SecretKey secretKey,
    List<int>? nonce,
    List<int> aad = const [],
    Uint8List? possibleBuffer,
  }) async {
    final encrypted = await delegate.encrypt(
      clearText,
      secretKey: secretKey,
      nonce: nonce,
      aad: aad,
      possibleBuffer: possibleBuffer,
    );
    await afterEncrypt?.call(utf8.decode(aad));
    return encrypted;
  }

  @override
  Future<List<int>> decrypt(
    SecretBox secretBox, {
    required SecretKey secretKey,
    List<int> aad = const [],
    Uint8List? possibleBuffer,
  }) async {
    await beforeDecrypt?.call(utf8.decode(aad));
    return delegate.decrypt(
      secretBox,
      secretKey: secretKey,
      aad: aad,
      possibleBuffer: possibleBuffer,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Synthetic independent adapters sharing real SQLite/encrypted rows.
class _PausedRepo extends SupportRepo {
  _PausedRepo(super.db, super.cipher);
  Completer<void>? entered, release;
  void pause() {
    entered = Completer<void>();
    release = Completer<void>();
  }

  @override
  Future<SupportContextBlock?> mutateContextBlock({
    required String blockId,
    required String sessionId,
    required SupportContextBlock? Function(SupportContextBlock? latest) mutate,
    bool Function()? isCurrent,
  }) async {
    // Delay admission, not a callback inside SQLite: B commits first, then A's
    // repository transaction must read B's latest row, not A's old snapshot.
    if (entered != null && !entered!.isCompleted) {
      entered!.complete();
      await release!.future;
    }
    return super.mutateContextBlock(
      blockId: blockId,
      sessionId: sessionId,
      mutate: mutate,
      isCurrent: isCurrent,
    );
  }
}

void main() {
  late AppDatabase db;
  late _PausedRepo repoA;
  late SupportRepo repoB;
  late SupportWorkspaceStore a, b;
  late _ControlledCipher primitive;
  late String id;
  const codec = SupportWorkspaceSettingsCodec();
  final redactor = SecretRedactor();
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    primitive = _ControlledCipher();
    final cipher = SupportPayloadCipher(
      vault: CredentialVault(
        storage: FakeCredentialStorage(),
        buildChannel: 'dev',
      ),
      cipher: primitive,
    );
    repoA = _PausedRepo(db, cipher);
    repoB = SupportRepo(db, cipher);
    a = SupportWorkspaceStore(repoA, () => redactor);
    b = SupportWorkspaceStore(repoB, () => redactor);
    id = await a.create('Synthetic atomic settings');
    await a.appendUser(id, 'Synthetic retained history');
  });
  tearDown(() => db.close());

  Future<SupportContextBlockRow> row() => (db.select(
    db.supportContextBlocks,
  )..where((t) => t.id.equals(codec.idFor(id)))).getSingle();
  Future<SupportContextBlockRow?> optionalRow() => (db.select(
    db.supportContextBlocks,
  )..where((t) => t.id.equals(codec.idFor(id)))).getSingleOrNull();
  Future<List<SupportMessageRow>> history() => (db.select(
    db.supportMessages,
  )..where((t) => t.sessionId.equals(id))).get();
  Future<void> corrupt() => repoB.putContextBlock(
    codec
        .encode(id, const SupportAssistantSettings(), 1, redactor)
        .copyWith(protectedFactsJson: 'synthetic-readable-corrupt'),
  );

  test(
    'independent current adapters retain field A + B after delayed A',
    () async {
      await b.changeSettings(id, (s) => s.copyWith(modelId: 'synthetic-model'));
      expect((await a.settingsFor(id)).maxTokens, 2048);
      repoA.pause();
      final editA = a.changeSettings(
        id,
        (s) => s.copyWith(temperature: 0.9),
        isCurrent: () => true,
      );
      await repoA.entered!.future;
      await b.changeSettings(
        id,
        (s) => s.copyWith(maxTokens: 4096),
        isCurrent: () => true,
      );
      repoA.release!.complete();
      await editA;
      final durable = await b.settingsFor(id);
      expect(durable.temperature, 0.9);
      expect(durable.maxTokens, 4096);
      expect(durable.modelId, 'synthetic-model');
      expect(
        (await repoB.getMessagesForSession(id)).single.body,
        'Synthetic retained history',
      );
    },
  );

  test(
    'simultaneous independent mutations serialize on the latest encrypted row',
    () async {
      await b.changeSettings(id, (s) => s.copyWith(modelId: 'synthetic-model'));
      final entered = Completer<void>(), release = Completer<void>();
      var paused = false;
      primitive.afterEncrypt = (aad) async {
        if (!paused && aad.endsWith('|summary_ciphertext')) {
          paused = true;
          entered.complete();
          await release.future;
        }
      };
      final editA = a.changeSettings(id, (s) => s.copyWith(temperature: 0.9));
      await entered.future;
      final editB = b.changeSettings(id, (s) => s.copyWith(maxTokens: 4096));
      release.complete();
      await Future.wait([editA, editB]);
      final durable = await b.settingsFor(id);
      expect(durable.temperature, 0.9);
      expect(durable.maxTokens, 4096);
      expect(durable.modelId, 'synthetic-model');
    },
  );

  for (final replacement in [
    'missing',
    'locked',
    'locked-parent',
    'deleted-parent',
    'reparented',
  ]) {
    test(
      'pending recovery refuses latest $replacement without changing retained bytes',
      () async {
        await corrupt();
        final oldHistory = await history();
        repoA.pause();
        final recovery = a.recoverSettings(id, confirmed: true);
        final refusal = expectLater(
          recovery,
          throwsA(anyOf(isA<StateError>(), isA<SupportSettingsUnavailable>())),
        );
        await repoA.entered!.future;
        switch (replacement) {
          case 'missing':
            await (db.delete(
              db.supportContextBlocks,
            )..where((t) => t.id.equals(codec.idFor(id)))).go();
          case 'locked':
            await (db.update(
              db.supportContextBlocks,
            )..where((t) => t.id.equals(codec.idFor(id)))).write(
              const SupportContextBlocksCompanion(
                protectedFactsCiphertext: Value('synthetic-locked'),
              ),
            );
          case 'locked-parent':
            await (db.update(
              db.supportSessions,
            )..where((t) => t.id.equals(id))).write(
              const SupportSessionsCompanion(
                titleCiphertext: Value('synthetic-locked-parent'),
              ),
            );
          case 'deleted-parent':
            await repoB.deleteSession(id);
          case 'reparented':
            final other = await b.create('Synthetic other parent');
            await (db.update(db.supportContextBlocks)
                  ..where((t) => t.id.equals(codec.idFor(id))))
                .write(SupportContextBlocksCompanion(sessionId: Value(other)));
        }
        final latest = await optionalRow(), latestHistory = await history();
        repoA.release!.complete();
        await refusal;
        expect(await optionalRow(), latest);
        expect(await history(), latestHistory);
        if (replacement != 'deleted-parent') expect(latestHistory, oldHistory);
      },
    );
  }

  test(
    'latest locked row also refuses delayed normal mutation before callback',
    () async {
      await b.changeSettings(id, (s) => s);
      repoA.pause();
      var called = false;
      final edit = a.changeSettings(id, (s) {
        called = true;
        return s.copyWith(maxTokens: 4096);
      });
      final refusal = expectLater(
        edit,
        throwsA(isA<SupportSettingsUnavailable>()),
      );
      await repoA.entered!.future;
      await (db.update(
        db.supportContextBlocks,
      )..where((t) => t.id.equals(codec.idFor(id)))).write(
        const SupportContextBlocksCompanion(
          protectedFactsCiphertext: Value('synthetic-locked'),
        ),
      );
      final before = await row(), oldHistory = await history();
      repoA.release!.complete();
      await refusal;
      expect(called, isFalse);
      expect(await row(), before);
      expect(await history(), oldHistory);
    },
  );

  test(
    'normal edit on latest missing preferences uses defaults only under surviving unlocked parent',
    () async {
      await b.changeSettings(
        id,
        (s) => s.copyWith(modelId: 'synthetic-old-model', maxTokens: 8192),
      );
      repoA.pause();
      final edit = a.changeSettings(id, (s) => s.copyWith(temperature: 0.9));
      await repoA.entered!.future;
      await (db.delete(
        db.supportContextBlocks,
      )..where((t) => t.id.equals(codec.idFor(id)))).go();
      final oldHistory = await history();
      repoA.release!.complete();
      await edit;
      final durable = await b.settingsFor(id);
      expect(durable.temperature, 0.9);
      expect(durable.maxTokens, 2048);
      expect(durable.modelId, isNull);
      expect(await history(), oldHistory);
    },
  );

  test(
    'ownership lost during transactional latest read prevents callback and all writes',
    () async {
      await b.changeSettings(id, (s) => s);
      final before = await row(), oldHistory = await history();
      final entered = Completer<void>(), release = Completer<void>();
      var current = true, called = false, paused = false;
      primitive.beforeDecrypt = (aad) async {
        if (!paused && aad.contains('|support_context_blocks|')) {
          paused = true;
          entered.complete();
          await release.future;
        }
      };
      final edit = a.changeSettings(id, (s) {
        called = true;
        return s.copyWith(temperature: 1);
      }, isCurrent: () => current);
      await entered.future;
      current = false;
      release.complete();
      await edit;
      expect(called, isFalse);
      expect(await row(), before);
      expect(await history(), oldHistory);
    },
  );

  test(
    'narrow mutation returns the committed mapped row, never the candidate snapshot',
    () async {
      final candidate = codec.encode(
        id,
        const SupportAssistantSettings(maxTokens: 4096),
        1,
        redactor,
      );
      final durable = await repoB.mutateContextBlock(
        blockId: codec.idFor(id),
        sessionId: id,
        mutate: (_) => candidate,
      );
      expect(identical(durable, candidate), isFalse);
      expect(durable, await repoB.getContextBlockById(codec.idFor(id)));
      expect(codec.decode(durable).maxTokens, 4096);
      expect(
        (await row()).protectedFactsCiphertext,
        isNot(contains(candidate.protectedFactsJson)),
      );
    },
  );

  test('core callback cannot change context identity or parent', () async {
    await b.changeSettings(id, (s) => s);
    final other = await b.create('Synthetic other parent');
    final before = await row(), oldHistory = await history();
    for (final changeId in [false, true]) {
      await expectLater(
        repoB.mutateContextBlock(
          blockId: codec.idFor(id),
          sessionId: id,
          mutate: (latest) => changeId
              ? latest!.copyWith(id: 'synthetic-other-id')
              : latest!.copyWith(sessionId: other),
        ),
        throwsStateError,
      );
      expect(await row(), before);
      expect(await history(), oldHistory);
    }
  });

  for (final failure in [
    'cipher',
    'write',
    'mapped-read',
    'owner-after-encrypt',
    'owner-after-write',
  ]) {
    test('$failure cannot partially commit preferences or history', () async {
      await corrupt();
      final before = await row(), oldHistory = await history();
      var current = true, reads = 0;
      if (failure == 'write') {
        await db.customStatement(
          "CREATE TEMP TRIGGER synthetic_fail_context BEFORE INSERT ON support_context_blocks BEGIN SELECT RAISE(ABORT, 'synthetic-write-failure'); END",
        );
      }
      primitive.afterEncrypt = (aad) async {
        if (!aad.endsWith('|protected_facts_ciphertext')) return;
        if (failure == 'cipher') throw StateError('synthetic-cipher-failure');
        if (failure == 'owner-after-encrypt') current = false;
      };
      primitive.beforeDecrypt = (aad) async {
        if (!aad.contains('|support_context_blocks|')) return;
        reads++;
        // Two decryptions classify the latest row; the third maps the written
        // row inside the still-open transaction, not a post-commit feature read.
        if (reads == 3 && failure == 'mapped-read') {
          throw const SupportCipherException(
            SupportCipherFailure.authenticationFailed,
          );
        }
        if (reads == 3 && failure == 'owner-after-write') current = false;
      };
      await expectLater(
        a.recoverSettings(id, confirmed: true, isCurrent: () => current),
        failure == 'write' ? throwsA(isA<SqliteException>()) : throwsStateError,
      );
      primitive.afterEncrypt = null;
      primitive.beforeDecrypt = null;
      expect(await row(), before);
      expect(await history(), oldHistory);
      expect(
        (await a.load()).settingsAvailability[id],
        SupportSettingsAvailability.corrupt,
      );
    });
  }

  test(
    'latest unavailable read refuses recovery before any encryption',
    () async {
      await corrupt();
      final before = await row(), oldHistory = await history();
      primitive.beforeDecrypt = (aad) async {
        if (aad.contains('|support_context_blocks|')) {
          throw StateError('synthetic-read-unavailable');
        }
      };
      var writes = 0;
      primitive.afterEncrypt = (_) async {
        writes++;
      };
      await expectLater(
        a.recoverSettings(id, confirmed: true),
        throwsStateError,
      );
      expect(writes, 0);
      expect(await row(), before);
      expect(await history(), oldHistory);
    },
  );

  test(
    'confirmed recovery refuses healthy replacement byte-for-byte',
    () async {
      await repoB.putContextBlock(
        codec
            .encode(id, const SupportAssistantSettings(), 1, redactor)
            .copyWith(protectedFactsJson: 'synthetic-readable-corrupt'),
      );
      expect(
        (await a.load()).settingsAvailability[id],
        SupportSettingsAvailability.corrupt,
      );
      repoA.pause();
      final recovery = a.recoverSettings(
        id,
        confirmed: true,
        isCurrent: () => true,
      );
      // Attach the expected rejection before releasing the pending operation.
      final refusal = expectLater(recovery, throwsStateError);
      await repoA.entered!.future;
      await repoB.putContextBlock(
        codec.encode(
          id,
          const SupportAssistantSettings(
            temperature: 1.2,
            maxTokens: 8192,
            modelId: 'synthetic-new-model',
          ),
          2,
          redactor,
        ),
      );
      final before = await row();
      repoA.release!.complete();
      await refusal;
      expect(await row(), before);
      expect((await b.settingsFor(id)).maxTokens, 8192);
      expect((await repoB.getMessagesForSession(id)).length, 1);
    },
  );
}
