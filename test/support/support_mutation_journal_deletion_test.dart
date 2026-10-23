import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';

import 'helpers/support_mutation_journal_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final state in ['pending', 'undo_pending', 'reconciliation_required']) {
    journalTest(
      'protected deletion denies unresolved $state while exact undo/recovery bytes survive',
      (f) async {
        var journal = (await f.reserve())!;
        if (state == 'undo_pending') {
          journal = (await f.undo((await f.settle(journal))!))!;
        }
        if (state == 'reconciliation_required') {
          journal = (await f.settle(
            journal,
            SupportMutationFact.reconciliationRequired,
          ))!;
        }
        final before = await f.snapshot();
        expect(await f.delete(), isFalse);
        expect(await f.snapshot(), before);
        expect((await f.read())!.record, journal.record);
        await f.repo.deleteSession(JournalFixture.sessionId);
        expect(
          await f.row(),
          isNull,
          reason: 'Legacy deletion default cascade intentionally unchanged.',
        );
        expect(await f.repo.getSessionById(JournalFixture.sessionId), isNull);
      },
    );
  }

  for (final state in ['applied', 'failed', 'undone', 'undo_conflict']) {
    journalTest(
      'protected deletion permits readable settled $state, only the existing support cascade',
      (f) async {
        var journal = (await f.reserve())!;
        journal = (await f.settle(
          journal,
          state == 'failed'
              ? SupportMutationFact.failed
              : SupportMutationFact.applied,
        ))!;
        if (state == 'undone' || state == 'undo_conflict') {
          journal = (await f.undo(journal))!;
          journal = (await f.settle(
            journal,
            state == 'undone'
                ? SupportMutationFact.undone
                : SupportMutationFact.undoConflict,
          ))!;
        }
        final foreign = await f.repo.getSessionById(JournalFixture.foreignId);
        expect(journal.record.status, state);
        expect(await f.delete(), isTrue);
        expect(await f.repo.getSessionById(JournalFixture.sessionId), isNull);
        expect(await f.repo.getSessionById(JournalFixture.foreignId), foreign);
        expect(
          await f.repo.getMessagesForSession(JournalFixture.sessionId),
          isEmpty,
        );
        expect(
          await f.repo.getContextBlocksForSession(JournalFixture.sessionId),
          isEmpty,
        );
        expect(
          await f.repo.getReportsForSession(JournalFixture.sessionId),
          isEmpty,
        );
        expect(await f.row(), isNull);
        expect(
          await f.settle(journal),
          isNull,
          reason: 'Deleting settled history does not authorize resurrection.',
        );
      },
    );
  }

  journalTest(
    'protected empty history deletion works; missing or retired admission returns false',
    (f) async {
      f.current = false;
      final before = await f.snapshot();
      expect(await f.delete(), isFalse);
      expect(await f.snapshot(), before);
      f.current = true;
      expect(await f.delete(), isTrue);
      expect(await f.delete(), isFalse);
      expect(await f.reserve(), isNull);
    },
  );

  for (final state in [
    'unknown',
    'malformed-time',
    'unversioned',
    'locked-before',
    'locked-after',
  ]) {
    journalTest(
      'protected deletion fails closed for $state, even when plaintext status looks applied',
      (f) async {
        final applied = (await f.settle((await f.reserve())!))!;
        switch (state) {
          case 'unknown':
            await f.change(
              const SupportMutationJournalCompanion(
                status: Value('future-status'),
              ),
            );
          case 'malformed-time':
            await f.db.customStatement(
              "UPDATE support_mutation_journal SET created_at = 'not-time' WHERE id = ?",
              [JournalFixture.id],
            );
          case 'unversioned':
            await f.repo.putMutation(
              applied.record.copyWith(
                beforeJson: '{"default-shaped":"success"}',
              ),
            );
          case 'locked-before':
            await f.change(
              const SupportMutationJournalCompanion(
                beforeCiphertext: Value('synthetic-corrupt'),
              ),
            );
          case 'locked-after':
            await f.change(
              const SupportMutationJournalCompanion(
                afterCiphertext: Value('synthetic-corrupt'),
              ),
            );
        }
        final before = await f.snapshot();
        f.observe();
        // Typed cipher failures are known refusals only in read preflight,
        // before any cascade write; commit-delivery errors remain exceptional.
        expect(await f.delete(), isFalse);
        expect(f.events.where((event) => event.startsWith('delete:')), isEmpty);
        expect(await f.snapshot(), before);
      },
    );
  }

  journalTest(
    'reservation wins queued protected deletion race: pending evidence cannot be erased',
    (f) async {
      final barrier = JournalBarrier();
      f.hook = (event) async {
        if (event.startsWith('encrypt:') &&
            event.endsWith('|before_ciphertext')) {
          f.hook = null;
          await barrier.wait();
        }
      };
      final reservation = f.reserve();
      await barrier.entered.future;
      // Invoke outside the transaction Zone: Drift queues this behind the owned
      // reservation, not a nested same-transaction inspection/UI preflight.
      final deletion = f.delete();
      barrier.release.complete();
      final reserved = (await reservation)!;
      expect(await deletion, isFalse);
      expect((await f.read())!.record, reserved.record);
      expect(await f.repo.getSessionById(JournalFixture.sessionId), isNotNull);
    },
  );

  journalTest(
    'protected deletion wins queued reservation race: absent parent refuses no resurrection',
    (f) async {
      final barrier = JournalBarrier();
      f.hook = (event) async {
        if (event.startsWith('delete:') && event.contains('support_messages')) {
          f.hook = null;
          await barrier.wait();
        }
      };
      final deletion = f.delete();
      await barrier.entered.future;
      final reservation = f.reserve();
      barrier.release.complete();
      expect(await deletion, isTrue);
      expect(await reservation, isNull);
      expect(await f.row(), isNull);
      expect(await f.repo.getSessionById(JournalFixture.sessionId), isNull);
    },
  );

  for (final state in ['reservation', 'delete']) {
    journalTest(
      'simultaneous $state and protected deletion have coherent serialized outcomes',
      (f) async {
        if (state == 'reservation') {
          final results = await Future.wait<Object?>([f.reserve(), f.delete()]);
          expect(results[0], isA<SupportMutationReservation>());
          expect(results[1], isFalse);
        } else {
          final results = await Future.wait<Object?>([f.delete(), f.reserve()]);
          expect(results[0], isTrue);
          expect(results[1], isNull);
        }
      },
    );
  }

  journalTest(
    'provisional cascade SQL failure rolls back every unrelated/support table exactly',
    (f) async {
      await f.settle((await f.reserve())!);
      final before = await f.snapshot();
      f.hook = (event) async {
        if (event.startsWith('delete:') &&
            event.contains('support_context_blocks')) {
          throw StateError(JournalFixture.canary);
        }
      };
      await expectLater(
        f.delete(),
        throwsA(isA<SupportMutationJournalException>()),
      );
      f.clearHooks();
      expect(await f.snapshot(), before);
    },
  );

  journalTest(
    'any unresolved journal excludes deletion even alongside readable settled evidence',
    (f) async {
      await f.settle((await f.reserve())!);
      await f.reserve(JournalFixture.candidate.copyWith(id: 'second-pending'));
      final before = await f.snapshot();
      expect(await f.delete(), isFalse);
      expect(await f.snapshot(), before);
    },
  );

  journalTest('unreadable original parent fails closed in protected deletion', (
    f,
  ) async {
    await (f.db.update(
      f.db.supportSessions,
    )..where((t) => t.id.equals(JournalFixture.sessionId))).write(
      const SupportSessionsCompanion(
        titleCiphertext: Value('synthetic-corrupt'),
      ),
    );
    final before = await f.snapshot();
    f.observe();
    expect(await f.delete(), isFalse);
    expect(f.events.where((event) => event.startsWith('delete:')), isEmpty);
    expect(await f.snapshot(), before);
  });

  journalTest(
    'Undo reservation wins queued protected deletion race and retains original snapshots',
    (f) async {
      final applied = (await f.settle((await f.reserve())!))!;
      final barrier = JournalBarrier();
      f.hook = (event) async {
        if (event.startsWith('update:') &&
            event.contains('support_mutation_journal')) {
          f.hook = null;
          await barrier.wait();
        }
      };
      final undo = f.undo(applied);
      await barrier.entered.future;
      final deletion = f.delete();
      barrier.release.complete();
      final reserved = (await undo)!;
      expect(await deletion, isFalse);
      expect((await f.read())!.record, reserved.record);
    },
  );

  journalTest(
    'protected settled deletion wins queued Undo admission race with zero resurrection',
    (f) async {
      final applied = (await f.settle((await f.reserve())!))!;
      final barrier = JournalBarrier();
      f.hook = (event) async {
        if (event.startsWith('delete:') && event.contains('support_messages')) {
          f.hook = null;
          await barrier.wait();
        }
      };
      final deletion = f.delete();
      await barrier.entered.future;
      final undo = f.undo(applied);
      barrier.release.complete();
      expect(await deletion, isTrue);
      expect(await undo, isNull);
      expect(await f.row(), isNull);
    },
  );
}
