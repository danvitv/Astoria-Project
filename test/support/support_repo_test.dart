import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';

import '../credentials/fake_credential_storage.dart';

void main() {
  late AppDatabase db;
  late FakeCredentialStorage storage;
  late CredentialVault vault;
  late SupportPayloadCipher cipher;
  late SupportRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    storage = FakeCredentialStorage();
    vault = CredentialVault(storage: storage, buildChannel: 'dev');
    cipher = SupportPayloadCipher(vault: vault);
    repo = SupportRepo(db, cipher);
  });

  tearDown(() async {
    await db.close();
  });

  test(
    'stores only encrypted envelopes in raw SQLite columns across all ciphertext tables',
    () async {
      const titlePlain = 'My Secret Troubleshooting Session Title';
      const bodyPlain = 'Why is my endpoint returning 401 with token abc-secret?';
      const cardsPlain = '[{"kind":"diagnostic_preview","summary":"card-body"}]';
      const summaryPlain = 'Compacted summary of turns 1..4';
      const factsPlain = '["user prefers local ollama","active preset default"]';
      const beforePlain = '{"temperature":1.5,"endpoint":"https://before.example"}';
      const afterPlain = '{"temperature":0.8,"endpoint":"https://after.example"}';

      await repo.createSession(
        const SupportSession(
          id: 'sess-1',
          title: titlePlain,
          createdAt: 100,
          updatedAt: 100,
          pinned: true,
          mode: 'hybrid',
          activeApiConfigId: 'api-1',
          activeModelId: 'gpt-4o',
        ),
      );

      await repo.appendMessage(
        const SupportMessage(
          id: 'msg-1',
          sessionId: 'sess-1',
          role: 'user',
          body: bodyPlain,
          cardsJson: cardsPlain,
          runId: 'run-1',
          status: 'complete',
          createdAt: 150,
        ),
      );

      await repo.putContextBlock(
        const SupportContextBlock(
          id: 'ctx-1',
          sessionId: 'sess-1',
          startMessageId: 'msg-1',
          endMessageId: 'msg-1',
          summary: summaryPlain,
          protectedFactsJson: factsPlain,
          isActive: true,
          createdAt: 160,
        ),
      );

      await repo.recordMutation(
        const SupportMutationRecord(
          id: 'mut-1',
          sessionId: 'sess-1',
          domain: 'api_config',
          targetId: 'api-1',
          beforeJson: beforePlain,
          afterJson: afterPlain,
          status: 'applied',
          createdAt: 170,
        ),
      );

      await repo.recordReport(
        const SupportReportRecord(
          id: 'rep-1',
          sessionId: 'sess-1',
          fileHash: 'sha256:deadbeef',
          status: 'exported',
          createdAt: 180,
        ),
      );

      // Verify raw SQLite rows never contain any plaintext substrings.
      final rawSession = await db
          .customSelect("SELECT * FROM support_sessions WHERE id = 'sess-1'")
          .getSingle();
      final rawTitle = rawSession.read<String>('title_ciphertext');
      expect(rawTitle, isNot(contains(titlePlain)));
      expect((jsonDecode(rawTitle) as Map)['alg'], 'XChaCha20-Poly1305');

      final rawMessage = await db
          .customSelect("SELECT * FROM support_messages WHERE id = 'msg-1'")
          .getSingle();
      final rawBody = rawMessage.read<String>('body_ciphertext');
      final rawCards = rawMessage.read<String>('cards_ciphertext');
      expect(rawBody, isNot(contains(bodyPlain)));
      expect(rawCards, isNot(contains(cardsPlain)));
      expect((jsonDecode(rawBody) as Map)['alg'], 'XChaCha20-Poly1305');
      expect((jsonDecode(rawCards) as Map)['alg'], 'XChaCha20-Poly1305');

      final rawBlock = await db
          .customSelect(
            "SELECT * FROM support_context_blocks WHERE id = 'ctx-1'",
          )
          .getSingle();
      final rawSummary = rawBlock.read<String>('summary_ciphertext');
      final rawFacts = rawBlock.read<String>('protected_facts_ciphertext');
      expect(rawSummary, isNot(contains(summaryPlain)));
      expect(rawFacts, isNot(contains(factsPlain)));

      final rawMutation = await db
          .customSelect(
            "SELECT * FROM support_mutation_journal WHERE id = 'mut-1'",
          )
          .getSingle();
      final rawBefore = rawMutation.read<String>('before_ciphertext');
      final rawAfter = rawMutation.read<String>('after_ciphertext');
      expect(rawBefore, isNot(contains(beforePlain)));
      expect(rawAfter, isNot(contains(afterPlain)));

      // Verify round-trip reads decrypt cleanly and appendMessage bumped session updatedAt.
      final loadedSession = await repo.getSessionById('sess-1');
      expect(loadedSession, isNotNull);
      expect(loadedSession!.title, titlePlain);
      expect(loadedSession.updatedAt, 150);
      expect(loadedSession.isLocked, isFalse);

      final loadedMessages = await repo.getMessagesForSession('sess-1');
      expect(loadedMessages, hasLength(1));
      expect(loadedMessages.single.body, bodyPlain);
      expect(loadedMessages.single.cardsJson, cardsPlain);
      expect(loadedMessages.single.isLocked, isFalse);

      final loadedBlocks = await repo.getContextBlocksForSession('sess-1');
      expect(loadedBlocks, hasLength(1));
      expect(loadedBlocks.single.summary, summaryPlain);
      expect(loadedBlocks.single.protectedFactsJson, factsPlain);

      final loadedMutations = await repo.getMutationsForSession('sess-1');
      expect(loadedMutations, hasLength(1));
      expect(loadedMutations.single.beforeJson, beforePlain);
      expect(loadedMutations.single.afterJson, afterPlain);

      final loadedReports = await repo.getReportsForSession('sess-1');
      expect(loadedReports, hasLength(1));
      expect(loadedReports.single.fileHash, 'sha256:deadbeef');
    },
  );

  test(
    'atomic CRUD, message mutation, and cascading session deletion work end-to-end',
    () async {
      await repo.createSession(
        const SupportSession(
          id: 'sess-crud',
          title: 'Initial Title',
          createdAt: 10,
          updatedAt: 10,
        ),
      );

      final renamed = await repo.renameSession(
        sessionId: 'sess-crud',
        title: 'Renamed Title',
        updatedAt: 20,
      );
      expect(renamed?.title, 'Renamed Title');
      expect(renamed?.updatedAt, 20);

      await repo.appendMessage(
        const SupportMessage(
          id: 'm-1',
          sessionId: 'sess-crud',
          role: 'assistant',
          body: 'Streaming draft...',
          status: 'streaming',
          createdAt: 30,
        ),
      );

      final mutated = await repo.mutateMessage(
        messageId: 'm-1',
        mutate: (latest) => latest.copyWith(
          body: '${latest.body} complete!',
          cardsJson: '[{"id":"card-1"}]',
          status: 'complete',
        ),
      );
      expect(mutated?.body, 'Streaming draft... complete!');
      expect(mutated?.cardsJson, '[{"id":"card-1"}]');
      expect(mutated?.status, 'complete');

      await repo.putContextBlock(
        const SupportContextBlock(
          id: 'b-1',
          sessionId: 'sess-crud',
          startMessageId: 'm-1',
          endMessageId: 'm-1',
          summary: 'Summary',
          createdAt: 40,
        ),
      );
      await repo.deactivateContextBlock('b-1');
      expect(
        await repo.getContextBlocksForSession('sess-crud', activeOnly: true),
        isEmpty,
      );

      await repo.recordMutation(
        const SupportMutationRecord(
          id: 'j-1',
          sessionId: 'sess-crud',
          domain: 'preset',
          targetId: 'p-1',
          beforeJson: '{"a":1}',
          afterJson: '{"a":2}',
          createdAt: 50,
        ),
      );
      final reverted = await repo.updateMutationStatus(
        id: 'j-1',
        status: 'reverted',
      );
      expect(reverted?.status, 'reverted');

      await repo.recordReport(
        const SupportReportRecord(
          id: 'r-1',
          sessionId: 'sess-crud',
          fileHash: 'hash-1',
          createdAt: 60,
        ),
      );

      // Delete session cascades across all 5 tables atomically.
      await repo.deleteSession('sess-crud');
      expect(await repo.getSessionById('sess-crud'), isNull);
      expect(await repo.getMessagesForSession('sess-crud'), isEmpty);
      expect(await repo.getContextBlocksForSession('sess-crud'), isEmpty);
      expect(await repo.getMutationsForSession('sess-crud'), isEmpty);
      expect(await repo.getReportsForSession('sess-crud'), isEmpty);
    },
  );

  test(
    'surfaces graceful isLocked indicator when install key is lost and wires Riverpod providers',
    () async {
      final container = ProviderContainer(
        overrides: [
          appDbProvider.overrideWithValue(db),
          credentialStorageProvider.overrideWithValue(storage),
        ],
      );
      addTearDown(container.dispose);

      final providedRepo = container.read(supportRepoProvider);
      await providedRepo.createSession(
        const SupportSession(
          id: 'sess-locked',
          title: 'Recoverable Metadata',
          createdAt: 100,
          updatedAt: 200,
          pinned: true,
        ),
      );
      await providedRepo.appendMessage(
        const SupportMessage(
          id: 'msg-locked',
          sessionId: 'sess-locked',
          role: 'user',
          body: 'Encrypted body before key loss',
          createdAt: 210,
        ),
      );

      // Simulate key replacement / key loss in vault.
      final newKey = base64UrlEncode(SecretKeyData.random(length: 32).bytes);
      await vault.store(SupportPayloadCipher.installKeySlot, newKey);

      final lockedSession = await providedRepo.getSessionById('sess-locked');
      expect(lockedSession, isNotNull);
      expect(lockedSession!.isLocked, isTrue);
      expect(lockedSession.title, '');
      expect(lockedSession.pinned, isTrue);

      final lockedMessage = await providedRepo.getMessageById('msg-locked');
      expect(lockedMessage, isNotNull);
      expect(lockedMessage!.isLocked, isTrue);
      expect(lockedMessage.body, '');

      // Mutating a locked message must fail closed rather than clobbering ciphertext.
      await expectLater(
        providedRepo.mutateMessage(
          messageId: 'msg-locked',
          mutate: (latest) => latest.copyWith(body: 'overwrite'),
        ),
        throwsA(isA<SupportCipherException>()),
      );
    },
  );
}
