import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:path/path.dart' as p;

import '../credentials/fake_credential_storage.dart';

void main() {
  test(
    'file-backed close/reopen preserves encrypted support data and missing-key recovery',
    () async {
      // Synthetic sandbox only: no app data, platform secure storage, or process restart.
      final sandbox = await Directory.systemTemp.createTemp(
        'astoria-support-disk-reopen-',
      );
      final file = File(p.join(sandbox.path, 'support-test.sqlite'));
      _DiskOwners? current;
      addTearDown(() async {
        try {
          await current?.db.close();
        } finally {
          // Delete only the unique directory this test created, including SQLite sidecars.
          await sandbox.delete(recursive: true);
        }
      });

      Future<_DiskOwners> reopen(FakeCredentialStorage storage) async {
        await current?.db.close();
        current = null;
        final owners = _DiskOwners(file, storage);
        current = owners;
        return owners;
      }

      const canary = 'SUPPORT_DISK_CANARY_7ea19d9f';
      const session = SupportSession(
        id: 'disk-session',
        title: '$canary title',
        createdAt: 100,
        updatedAt: 100,
        pinned: true,
        mode: 'hybrid',
        activeApiConfigId: 'synthetic-api',
        activeModelId: 'synthetic-model',
      );
      final message = SupportMessage(
        id: 'disk-message',
        sessionId: session.id,
        role: 'assistant',
        body: '$canary body',
        cardsJson: '[{"summary":"$canary card"}]',
        runId: 'synthetic-run',
        createdAt: 110,
      );
      final context = SupportContextBlock(
        id: 'disk-context',
        sessionId: session.id,
        startMessageId: message.id,
        endMessageId: message.id,
        summary: '$canary summary',
        protectedFactsJson: '["$canary protected fact"]',
        createdAt: 120,
      );
      final syntheticKey = base64UrlEncode(
        List<int>.generate(32, (index) => index + 1),
      );

      final first = await reopen(FakeCredentialStorage());
      await first.vault.store(SupportPayloadCipher.installKeySlot, syntheticKey);
      await first.repo.createSession(session);
      await first.repo.appendMessage(message);
      await first.repo.putContextBlock(context);
      final expectedSession = session.copyWith(updatedAt: message.createdAt);
      final originalRows = await _rawSupportRows(first.db);
      expect(jsonEncode(originalRows), isNot(contains(canary)));

      // Copy only fake backing-store values. No owner, cache, or service survives reopen.
      final retainedStorage = FakeCredentialStorage()
        ..values.addAll(first.storage.values);
      final second = await reopen(retainedStorage);
      expect(await file.exists(), isTrue);
      expect(await file.length(), greaterThan(0));
      await _expectReadable(second.repo, expectedSession, message, context);
      expect(await _rawSupportRows(second.db), equals(originalRows));
      expect(second.storage.operations, isNot(contains('write')));

      await second.vault.delete(SupportPayloadCipher.installKeySlot);
      final missingStorage = FakeCredentialStorage()
        ..values.addAll(second.storage.values);
      final locked = await reopen(missingStorage);
      expect(locked.storage.values, isEmpty);
      final lockedSession = (await locked.repo.getAllSessions()).single;
      final lockedMessage = (await locked.repo.getMessagesForSession(
        session.id,
      )).single;
      final lockedContext = (await locked.repo.getContextBlocksForSession(
        session.id,
        activeOnly: true,
      )).single;
      expect(
        lockedSession,
        expectedSession.copyWith(title: '', isLocked: true),
      );
      expect(
        lockedMessage,
        message.copyWith(body: '', cardsJson: '', isLocked: true),
      );
      expect(
        lockedContext,
        context.copyWith(summary: '', protectedFactsJson: '', isLocked: true),
      );
      final failsClosed = throwsA(isA<SupportCipherException>());
      await expectLater(
        locked.cipher.decrypt(
          envelopeText:
              originalRows['sessions']!.single['titleCiphertext']! as String,
          table: 'support_sessions',
          rowId: session.id,
          sessionId: session.id,
          field: 'title_ciphertext',
        ),
        throwsA(
          isA<SupportCipherException>().having(
            (error) => error.failure,
            'failure',
            SupportCipherFailure.keyMissing,
          ),
        ),
      );
      await expectLater(
        locked.repo.renameSession(sessionId: session.id, title: 'overwrite'),
        failsClosed,
      );
      await expectLater(
        locked.repo.putSession(session.copyWith(title: 'overwrite')),
        failsClosed,
      );
      await expectLater(
        locked.repo.putMessage(message.copyWith(body: 'overwrite')),
        failsClosed,
      );
      await expectLater(
        locked.repo.mutateMessage(
          messageId: message.id,
          mutate: (latest) => latest.copyWith(body: 'overwrite'),
        ),
        failsClosed,
      );
      await expectLater(
        locked.repo.putContextBlock(context.copyWith(summary: 'overwrite')),
        failsClosed,
      );
      expect(locked.storage.values, isEmpty);
      expect(locked.storage.operations, everyElement('read'));
      expect(await _rawSupportRows(locked.db), equals(originalRows));

      // Restore the explicit synthetic key into another new vault, then re-read disk rows.
      final restored = await reopen(FakeCredentialStorage());
      await restored.vault.store(
        SupportPayloadCipher.installKeySlot,
        syntheticKey,
      );
      await _expectReadable(restored.repo, expectedSession, message, context);
      final recoveredRows = await _rawSupportRows(restored.db);
      expect(recoveredRows, equals(originalRows));
      expect(jsonEncode(recoveredRows), isNot(contains(canary)));
    },
  );
}

/// All production owners are reconstructed for each file-backed open.
final class _DiskOwners {
  _DiskOwners(File file, this.storage) {
    db = AppDatabase.forTesting(NativeDatabase(file));
    vault = CredentialVault(storage: storage, buildChannel: 'disk-test');
    cipher = SupportPayloadCipher(vault: vault);
    repo = SupportRepo(db, cipher);
  }

  final FakeCredentialStorage storage;
  late final AppDatabase db;
  late final CredentialVault vault;
  late final SupportPayloadCipher cipher;
  late final SupportRepo repo;
}

Future<void> _expectReadable(
  SupportRepo repo,
  SupportSession session,
  SupportMessage message,
  SupportContextBlock context,
) async {
  // Full model equality also covers settings, IDs, timestamps and unlocked flags.
  expect(await repo.getAllSessions(), [session]);
  expect(await repo.getSessionById(session.id), session);
  expect(await repo.getMessagesForSession(session.id), [message]);
  expect(await repo.getMessageById(message.id), message);
  expect(
    await repo.getContextBlocksForSession(session.id, activeOnly: true),
    [context],
  );
  expect(await repo.getContextBlockById(context.id), context);
}

Future<Map<String, List<Map<String, Object?>>>> _rawSupportRows(
  AppDatabase db,
) async => {
  // Test-only typed reads: compare every column, not decrypted repository models.
  'sessions': [
    for (final row in await db.select(db.supportSessions).get()) row.toJson(),
  ],
  'messages': [
    for (final row in await db.select(db.supportMessages).get()) row.toJson(),
  ],
  'context': [
    for (final row in await db.select(db.supportContextBlocks).get()) row.toJson(),
  ],
};
