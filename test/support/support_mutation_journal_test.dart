import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';

import 'helpers/support_mutation_journal_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  journalTest(
    'fixed canonical v1 bounded native envelope rejects malformed versions/duplicates',
    (f) async {
      final valid = SupportMutationEvidence.encode('synthetic-safe');
      expect(SupportMutationEvidence.decode(valid), 'synthetic-safe');
      for (final text in [
        '',
        '{}',
        'null',
        '[]',
        '{"v":999,"native":"safe"}',
        '{"v":1.0,"native":"safe"}',
        '{"v":1,"native":null}',
        '{"v":1,"native":"safe","extra":true}',
        '{"v":999,"v":1,"native":"safe"}',
        '{"v":1,"native":"bad","native":"safe"}',
        ' $valid',
        '{"v":1,"native":""}',
        'x' * (SupportMutationEvidence.maxEncodedChars + 1),
      ]) {
        expect(SupportMutationEvidence.decode(text), isNull);
      }
      expect(() => SupportMutationEvidence.encode(' '), throwsFormatException);
      expect(
        () => SupportMutationEvidence.encode('x' * 8193),
        throwsFormatException,
      );
      expect(
        () => SupportMutationEvidence.encode('界' * 2731),
        throwsFormatException,
      );
      expect(
        SupportMutationEvidence.decode(
          SupportMutationEvidence.encode('x' * 8192),
        ),
        hasLength(8192),
      );
    },
  );

  journalTest(
    'create-only pending encrypts BOTH snapshots in one journal transaction with unchanged AAD',
    (f) async {
      final original = await f.snapshot();
      f.observe();
      final reservation = (await f.reserve())!;
      expect(reservation.record, JournalFixture.candidate);
      expect(reservation.status, SupportMutationStatus.pending);
      final events = List.of(f.events);
      expect(events.where((e) => e.startsWith('insert:')), hasLength(1));
      for (final field in ['before_ciphertext', 'after_ciphertext']) {
        expect(
          events,
          contains(
            'encrypt:astoria.support.v1|support_mutation_journal|${JournalFixture.id}|${JournalFixture.sessionId}|$field',
          ),
        );
      }
      final raw = (await f.row())!;
      expect(raw.beforeCiphertext, isNot(contains(JournalFixture.canary)));
      expect(raw.afterCiphertext, isNot(contains(JournalFixture.canary)));
      expect(
        await f.repo.getMutationById(JournalFixture.id),
        reservation.record,
      );
      expect(await f.repo.getMutationsForSession(JournalFixture.sessionId), [
        reservation.record,
      ]);
      await f.remove();
      expect(
        await f.snapshot(),
        original,
        reason: 'Every unrelated table/parent/ciphertext retained exactly.',
      );
    },
  );

  journalTest(
    'same-session and foreign duplicate IDs never decrypt/upsert/overwrite collision',
    (f) async {
      final first = (await f.reserve())!;
      final before = await f.snapshot();
      for (final candidate in [
        first.record,
        first.record.copyWith(sessionId: JournalFixture.foreignId),
        first.record.copyWith(
          beforeJson: SupportMutationEvidence.encode('different-safe-before'),
        ),
      ]) {
        f.observe();
        expect(await f.reserve(candidate), isNull);
        expect(
          f.events.where(
            (e) =>
                e.startsWith('encrypt:') ||
                e.contains('|support_mutation_journal|'),
          ),
          isEmpty,
        );
        expect(await f.snapshot(), before);
      }
    },
  );

  journalTest(
    'concurrent reservation has one durable winner and one null collision',
    (f) async {
      final winners = await Future.wait([f.reserve(), f.reserve()]);
      expect(winners.whereType<SupportMutationReservation>(), hasLength(1));
      expect((await f.row())!.status, 'pending');
      expect(
        await f.repo.getMutationById(JournalFixture.id),
        winners.whereType<SupportMutationReservation>().single.record,
      );
    },
  );

  journalTest(
    'malformed/native-unversioned/locked/unsafe-metadata reservation refuses before writes',
    (f) async {
      final m = JournalFixture.candidate;
      final before = await f.snapshot();
      for (final bad in [
        m.copyWith(id: ''),
        m.copyWith(id: 'bad|id'),
        m.copyWith(id: 'x' * 129),
        m.copyWith(sessionId: ''),
        m.copyWith(domain: '../private-path'),
        m.copyWith(targetId: ' private target '),
        m.copyWith(targetId: '界'),
        m.copyWith(createdAt: -1),
        m.copyWith(createdAt: 9007199254740992),
        m.copyWith(status: 'applied'),
        m.copyWith(status: 'arbitrary'),
        m.copyWith(isLocked: true),
        m.copyWith(beforeJson: '{"theme":"model-plan"}'),
        m.copyWith(afterJson: '{"v":999,"native":"safe"}'),
      ]) {
        f.observe();
        expect(await f.reserve(bad), isNull);
        expect(
          f.events.where(
            (e) => e.startsWith('insert:') || e.startsWith('encrypt:'),
          ),
          isEmpty,
        );
      }
      f.current = false;
      f.observe();
      expect(await f.reserve(), isNull);
      expect(f.events, isEmpty);
      expect(await f.snapshot(), before);
    },
  );

  journalTest(
    'missing parent cannot be recreated by reservation or settlement',
    (f) async {
      final expected = (await f.reserve())!;
      await f.repo.deleteSession(JournalFixture.sessionId);
      final before = await f.snapshot();
      expect(await f.reserve(), isNull);
      expect(await f.settle(expected), isNull);
      expect(await f.read(), isNull);
      expect(await f.snapshot(), before);
    },
  );

  for (final target in ['parent', 'before', 'after']) {
    journalTest(
      'locked $target never becomes a default restoration or accepted fact',
      (f) async {
        final expected = (await f.reserve())!;
        if (target == 'parent') {
          await (f.db.update(
            f.db.supportSessions,
          )..where((t) => t.id.equals(JournalFixture.sessionId))).write(
            const SupportSessionsCompanion(
              titleCiphertext: Value('synthetic-corrupt'),
            ),
          );
        } else {
          await f.change(
            SupportMutationJournalCompanion(
              beforeCiphertext: target == 'before'
                  ? const Value('synthetic-corrupt')
                  : const Value.absent(),
              afterCiphertext: target == 'after'
                  ? const Value('synthetic-corrupt')
                  : const Value.absent(),
            ),
          );
        }
        final before = await f.snapshot();
        if (target == 'parent') {
          await expectLater(
            f.settle(expected),
            throwsA(isA<SupportCipherException>()),
          );
        } else {
          expect(await f.settle(expected), isNull);
        }
        // A stale encrypted expectation refuses BEFORE mapping altered ciphertext.
        await expectLater(f.read(), throwsA(isA<SupportCipherException>()));
        if (target == 'parent') {
          await expectLater(
            f.reserve(expected.record.copyWith(id: 'synthetic-new')),
            throwsA(isA<SupportCipherException>()),
          );
        }
        expect(await f.snapshot(), before);
      },
    );
  }

  journalTest(
    'missing installation key/new wrong fake key cannot restore evidence or admit writes',
    (f) async {
      final expected = (await f.reserve())!;
      final before = await f.snapshot();
      f.storage.values.clear();
      await expectLater(f.read(), throwsA(isA<SupportCipherException>()));
      await expectLater(
        f.settle(expected),
        throwsA(isA<SupportCipherException>()),
      );
      await expectLater(
        f.reserve(expected.record.copyWith(id: 'synthetic-new')),
        throwsA(isA<SupportCipherException>()),
      );
      expect(
        f.storage.values,
        isEmpty,
        reason:
            'Unreadable original parent cannot mint a replacement install key.',
      );
      expect(await f.snapshot(), before);
      await f.vault.store(
        SupportPayloadCipher.installKeySlot,
        base64UrlEncode(List.filled(32, 7)),
      );
      await expectLater(f.read(), throwsA(isA<SupportCipherException>()));
      await expectLater(
        f.settle(expected),
        throwsA(isA<SupportCipherException>()),
      );
      expect(await f.snapshot(), before);
    },
  );

  journalTest(
    'fake vault read failure remains safe and preserves every durable byte',
    (f) async {
      final expected = (await f.reserve())!;
      final before = await f.snapshot();
      f.storage.readError = StateError(JournalFixture.canary);
      Object? observed;
      try {
        await f.settle(expected);
      } catch (error) {
        observed = error;
      }
      expect(observed, isA<SupportCipherException>());
      expect('$observed', isNot(contains(JournalFixture.canary)));
      expect(await f.snapshot(), before);
    },
  );

  journalTest(
    'encrypted before/after field swapping fails unchanged field-bound AAD authentication',
    (f) async {
      final pending = (await f.reserve())!;
      final raw = (await f.row())!;
      await f.change(
        SupportMutationJournalCompanion(
          beforeCiphertext: Value(raw.afterCiphertext),
          afterCiphertext: Value(raw.beforeCiphertext),
        ),
      );
      final before = await f.snapshot();
      expect(await f.settle(pending), isNull);
      await expectLater(f.read(), throwsA(isA<SupportCipherException>()));
      expect(await f.snapshot(), before);
    },
  );

  for (final assignment in [
    "created_at = 'bad-time'",
    'created_at = 1.5',
    'created_at = -1',
    'created_at = 9007199254740992',
    "domain = 'bad/path'",
    "target_id = ''",
    "status = 'unknown-status'",
  ]) {
    journalTest(
      'malformed durable journal metadata $assignment fails closed before decryption',
      (f) async {
        final expected = (await f.reserve())!;
        await f.db.customStatement(
          'UPDATE support_mutation_journal SET $assignment WHERE id = ?',
          [JournalFixture.id],
        );
        final before = await f.snapshot();
        f.observe();
        expect(await f.read(), isNull);
        expect(await f.settle(expected), isNull);
        expect(
          f.events.where(
            (e) =>
                e.startsWith('decrypt-before:') &&
                e.contains('|support_mutation_journal|'),
          ),
          isEmpty,
        );
        expect(await f.snapshot(), before);
      },
    );
  }

  for (final field in ['created_at', 'updated_at']) {
    journalTest(
      'malformed parent $field rejects before Drift maps fractional metadata',
      (f) async {
        await f.db.customStatement(
          'UPDATE support_sessions SET $field = 1.5 WHERE id = ?',
          [JournalFixture.sessionId],
        );
        final before = await f.snapshot();
        expect(await f.reserve(), isNull);
        expect(await f.snapshot(), before);
      },
    );
  }

  for (final fact in [
    SupportMutationFact.applied,
    SupportMutationFact.failed,
    SupportMutationFact.reconciliationRequired,
  ]) {
    journalTest(
      'pending settles $fact once, status-only retaining exact immutable envelopes',
      (f) async {
        final pending = (await f.reserve())!;
        final before = (await f.row())!;
        f.observe();
        final settled = (await f.settle(pending, fact))!;
        final events = List.of(f.events);
        final after = (await f.row())!;
        expect(after, before.copyWith(status: settled.status.value));
        expect(
          settled.record,
          pending.record.copyWith(status: settled.status.value),
        );
        expect(events.where((e) => e.startsWith('encrypt:')), isEmpty);
        expect(events.where((e) => e.startsWith('update:')), hasLength(1));
        expect(await f.settle(pending, fact), isNull);
        for (final other in SupportMutationFact.values) {
          expect(await f.settle(settled, other), isNull);
        }
        expect(await f.row(), after);
      },
    );
  }

  for (final fact in [
    SupportMutationFact.undone,
    SupportMutationFact.undoConflict,
    SupportMutationFact.reconciliationRequired,
  ]) {
    journalTest(
      'fresh Undo admission and $fact are explicit once-only transitions',
      (f) async {
        final pending = (await f.reserve())!;
        expect(await f.undo(pending), isNull);
        expect(await f.settle(pending, SupportMutationFact.undone), isNull);
        expect(
          await f.settle(pending, SupportMutationFact.undoConflict),
          isNull,
        );
        final applied = (await f.settle(pending))!;
        final bytes = (await f.row())!;
        f.current = false;
        expect(await f.undo(applied), isNull);
        f.current = true;
        final undo = (await f.undo(applied))!;
        expect(undo.status, SupportMutationStatus.undoPending);
        expect(await f.undo(applied), isNull);
        expect(await f.settle(undo, SupportMutationFact.applied), isNull);
        expect(await f.settle(undo, SupportMutationFact.failed), isNull);
        final settled = (await f.settle(undo, fact))!;
        expect(await f.row(), bytes.copyWith(status: settled.status.value));
        expect(await f.settle(undo, fact), isNull);
        expect(await f.undo(settled), isNull);
      },
    );
  }

  for (final change in [
    'deleted',
    'session',
    'domain',
    'target',
    'time',
    'status',
    'before',
    'after',
    'same-plaintext-reencrypt',
  ]) {
    journalTest(
      'exact expected $change mismatch cannot overwrite/recreate/reaccept stale custody',
      (f) async {
        final pending = (await f.reserve())!;
        switch (change) {
          case 'deleted':
            await f.remove();
          case 'session':
            await f.change(
              const SupportMutationJournalCompanion(
                sessionId: Value(JournalFixture.foreignId),
              ),
            );
          case 'domain':
            await f.change(
              const SupportMutationJournalCompanion(
                domain: Value('other-domain'),
              ),
            );
          case 'target':
            await f.change(
              const SupportMutationJournalCompanion(
                targetId: Value('other-target'),
              ),
            );
          case 'time':
            await f.change(
              const SupportMutationJournalCompanion(createdAt: Value(99)),
            );
          case 'status':
            await f.repo.updateMutationStatus(
              id: JournalFixture.id,
              status: 'failed',
            );
          case 'before':
            await f.repo.putMutation(
              pending.record.copyWith(
                beforeJson: SupportMutationEvidence.encode('new-before'),
              ),
            );
          case 'after':
            await f.repo.putMutation(
              pending.record.copyWith(
                afterJson: SupportMutationEvidence.encode('new-after'),
              ),
            );
          case 'same-plaintext-reencrypt':
            await f.repo.putMutation(pending.record);
        }
        final before = await f.snapshot();
        expect(await f.settle(pending), isNull);
        expect(await f.snapshot(), before);
      },
    );
  }

  journalTest(
    'wrong expected read identity/target never fetches foreign journal plaintext',
    (f) async {
      await f.reserve();
      f.observe();
      expect(await f.read(id: 'unknown'), isNull);
      expect(await f.read(session: JournalFixture.foreignId), isNull);
      expect(await f.read(domain: 'other-domain'), isNull);
      expect(await f.read(target: 'other-target'), isNull);
      expect(
        f.events.where((e) => e.contains('|support_mutation_journal|')),
        isEmpty,
      );
    },
  );

  journalTest(
    'new owners reconstruct readable pending/undo-pending without replay or native approvals',
    (f) async {
      final pending = (await f.reserve())!;
      final before = await f.snapshot();
      final freshCipher = SupportPayloadCipher(
        vault: CredentialVault(
          storage: f.storage,
          buildChannel: 'synthetic_journal',
        ),
        cipher: JournalControlledCipher(),
      );
      final fresh = SupportRepo(f.db, freshCipher);
      f.observe();
      final recovered = (await fresh.readCurrentMutation(
        id: JournalFixture.id,
        sessionId: JournalFixture.sessionId,
        domain: pending.record.domain,
        targetId: pending.record.targetId,
        isCurrent: () => true,
      ))!;
      expect(recovered.record, pending.record);
      expect(
        f.events.where(
          (e) => e.startsWith('insert:') || e.startsWith('update:'),
        ),
        isEmpty,
      );
      expect(await f.snapshot(), before);
      final applied = (await f.settle(pending))!;
      final undo = (await f.undo(applied))!;
      final reconstructed = (await fresh.readCurrentMutation(
        id: JournalFixture.id,
        sessionId: JournalFixture.sessionId,
        domain: undo.record.domain,
        targetId: undo.record.targetId,
        isCurrent: () => true,
      ))!;
      expect(reconstructed.status, SupportMutationStatus.undoPending);
      expect(reconstructed.record, undo.record);
    },
  );

  journalTest(
    'parent replacement refuses old custody; ordinary parent metadata is retained',
    (f) async {
      final pending = (await f.reserve())!;
      await f.repo.updateSessionMetadata(
        sessionId: JournalFixture.sessionId,
        pinned: false,
        updatedAt: 8,
      );
      final applied = (await f.settle(pending))!;
      final parent = (await f.repo.getSessionById(JournalFixture.sessionId))!;
      expect(parent.updatedAt, 8);
      expect(parent.pinned, isFalse);
      await f.repo.putSession(
        parent,
      ); // Same DTO, replacement encrypted identity.
      final before = await f.snapshot();
      expect(await f.undo(applied), isNull);
      expect(await f.snapshot(), before);
    },
  );

  journalTest(
    'exact copied rows in another owned memory DB cannot adopt an old custody handle',
    (f) async {
      final pending = (await f.reserve())!;
      final other = JournalFixture();
      try {
        await other.seed();
        final parent = await (f.db.select(
          f.db.supportSessions,
        )..where((t) => t.id.equals(JournalFixture.sessionId))).getSingle();
        await other.db
            .into(other.db.supportSessions)
            .insertOnConflictUpdate(parent.toCompanion(true));
        await other.db
            .into(other.db.supportMutationJournal)
            .insert((await f.row())!.toCompanion(true));
        final before = await other.snapshot();
        other.observe();
        expect(await other.settle(pending), isNull);
        expect(
          other.events,
          isEmpty,
          reason:
              'A different DB object is not original DB custody, even with copied ciphertext.',
        );
        expect(await other.snapshot(), before);
      } finally {
        other.clearHooks();
        await other.close();
      }
    },
  );

  journalTest(
    'legacy put/record defaults and unconditional arbitrary status contract remain unchanged',
    (f) async {
      const legacy = SupportMutationRecord(
        id: 'legacy',
        sessionId: JournalFixture.sessionId,
        domain: 'legacy',
        targetId: 'legacy-target',
        beforeJson: '{}',
        afterJson: '{}',
        createdAt: 5,
      );
      expect((await f.repo.recordMutation(legacy)).status, 'applied');
      expect(
        await f.repo.putMutation(legacy.copyWith(beforeJson: '{"legacy":1}')),
        legacy.copyWith(beforeJson: '{"legacy":1}'),
      );
      expect(
        (await f.repo.updateMutationStatus(
          id: 'legacy',
          status: 'legacy-custom',
        ))!.status,
        'legacy-custom',
      );
      expect(
        await f.read(id: 'legacy', domain: 'legacy', target: 'legacy-target'),
        isNull,
      );
    },
  );
}
