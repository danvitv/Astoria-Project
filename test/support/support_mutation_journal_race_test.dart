import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';

import 'helpers/support_mutation_journal_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Trace actual SQL, vault, AEAD, decrypt/mapped-return checkpoints first; then
  // retire at EACH observed awaited primitive boundary on a fresh owned memory
  // fixture. No fixed delay, polling or inferred list of just happy-path awaits.
  for (final operation in [
    'reserve',
    'settle',
    'undo',
    'read',
    'delete',
    'delete-settled',
  ]) {
    journalTest(
      '$operation retirement at every actual observed await rolls back exact bytes',
      (f) async {
        Future<Future<Object?> Function()> prepare(
          JournalFixture fixture,
        ) async {
          if (operation == 'reserve') return fixture.reserve;
          if (operation == 'read') {
            await fixture.reserve();
            return fixture.read;
          }
          if (operation == 'delete') return fixture.delete;
          final pending = (await fixture.reserve())!;
          if (operation == 'settle') return () => fixture.settle(pending);
          final applied = (await fixture.settle(pending))!;
          if (operation == 'delete-settled') return fixture.delete;
          return () => fixture.undo(applied);
        }

        final baseline = await prepare(f);
        f.observe();
        expect(await baseline(), isNotNull);
        final trace = List.of(f.events);
        expect(trace, isNotEmpty);
        for (var index = 0; index < trace.length; index++) {
          final fresh = JournalFixture();
          try {
            await fresh.seed();
            final run = await prepare(fresh);
            final before = await fresh.snapshot();
            fresh.observe();
            var reached = false;
            fresh.hook = (_) async {
              if (fresh.events.length - 1 == index) {
                reached = true;
                fresh.current = false;
              }
            };
            final result = await run();
            expect(
              reached,
              isTrue,
              reason: '$operation checkpoint $index ${trace[index]}',
            );
            expect(
              result,
              operation.startsWith('delete') ? isFalse : isNull,
              reason: '$operation checkpoint $index ${trace[index]}',
            );
            fresh.clearHooks();
            expect(
              await fresh.snapshot(),
              before,
              reason: 'No provisional result survives checkpoint $index.',
            );
          } finally {
            fresh.clearHooks();
            await fresh.close();
          }
        }
      },
    );
  }

  for (final phase in [
    'before-encrypt',
    'after-encrypt',
    'provisional-insert',
    'mapped-before-decrypt',
    'mapped-after-decrypt',
  ]) {
    journalTest(
      'reserve $phase fault rolls back both encrypted snapshots with safe errors',
      (f) async {
        final before = await f.snapshot();
        final marker = switch (phase) {
          'before-encrypt' =>
            'encrypt:astoria.support.v1|support_mutation_journal|${JournalFixture.id}|${JournalFixture.sessionId}|before_ciphertext',
          'after-encrypt' =>
            'encrypt:astoria.support.v1|support_mutation_journal|${JournalFixture.id}|${JournalFixture.sessionId}|after_ciphertext',
          'provisional-insert' => 'insert:',
          'mapped-before-decrypt' =>
            'decrypt-before:astoria.support.v1|support_mutation_journal|',
          _ => 'decrypt-after:astoria.support.v1|support_mutation_journal|',
        };
        f.hook = (event) async {
          if (event.startsWith(marker)) throw StateError(JournalFixture.canary);
        };
        Object? error;
        try {
          await f.reserve();
        } catch (caught) {
          error = caught;
        }
        expect(
          error,
          anyOf(
            isA<SupportCipherException>(),
            isA<SupportMutationJournalException>(),
          ),
        );
        expect('$error', isNot(contains(JournalFixture.canary)));
        f.clearHooks();
        expect(await f.snapshot(), before);
      },
    );
  }

  for (final phase in [
    'provisional-update',
    'mapped-before-decrypt',
    'mapped-after-decrypt',
  ]) {
    journalTest(
      'settlement $phase fault never claims applied after failed journal mapping/write',
      (f) async {
        final pending = (await f.reserve())!;
        final before = await f.snapshot();
        var reads = 0;
        f.hook = (event) async {
          if (phase == 'provisional-update' && event.startsWith('update:')) {
            throw StateError(JournalFixture.canary);
          }
          final marker = phase == 'mapped-before-decrypt'
              ? 'decrypt-before:'
              : 'decrypt-after:';
          if (phase != 'provisional-update' &&
              event.startsWith(marker) &&
              event.endsWith('|before_ciphertext') &&
              ++reads == 2) {
            throw StateError(JournalFixture.canary);
          }
        };
        await expectLater(
          f.settle(pending),
          throwsA(
            anyOf(
              isA<SupportCipherException>(),
              isA<SupportMutationJournalException>(),
            ),
          ),
        );
        f.clearHooks();
        expect(await f.snapshot(), before);
        expect((await f.row())!.status, 'pending');
      },
    );
  }

  for (final phase in ['encrypt', 'provisional-insert', 'mapped-return']) {
    journalTest(
      'parent replacement during reservation $phase rolls back, not a fabricated committed DTO',
      (f) async {
        final before = await f.snapshot();
        final marker = phase == 'encrypt'
            ? 'encrypt:'
            : phase == 'provisional-insert'
            ? 'insert:'
            : 'decrypt-after:astoria.support.v1|support_mutation_journal|';
        f.hook = (event) async {
          if (!event.startsWith(marker)) return;
          f.hook = null;
          await (f.db.update(f.db.supportSessions)
                ..where((t) => t.id.equals(JournalFixture.sessionId)))
              .write(const SupportSessionsCompanion(createdAt: Value(99)));
        };
        expect(await f.reserve(), isNull);
        f.clearHooks();
        expect(
          await f.snapshot(),
          before,
          reason:
              'Reentrant fixture mutation shares/rolls back in the owning transaction.',
        );
      },
    );
  }

  for (final phase in ['provisional-update', 'mapped-return']) {
    journalTest(
      'changed target/status after $phase cannot forge mapped accepted settlement',
      (f) async {
        final pending = (await f.reserve())!;
        final before = await f.snapshot();
        var reads = 0;
        f.hook = (event) async {
          final trigger = phase == 'provisional-update'
              ? event.startsWith('update:')
              : event.startsWith('decrypt-after:') &&
                    event.endsWith('|before_ciphertext') &&
                    ++reads == 2;
          if (!trigger) return;
          f.hook = null;
          await f.change(
            const SupportMutationJournalCompanion(
              targetId: Value('replacement-target'),
            ),
          );
        };
        expect(await f.settle(pending), isNull);
        f.clearHooks();
        expect(await f.snapshot(), before);
      },
    );
  }

  journalTest(
    'two concurrent terminal settlements have one exact durable winner',
    (f) async {
      final pending = (await f.reserve())!;
      final results = await Future.wait([
        f.settle(pending),
        f.settle(pending, SupportMutationFact.failed),
      ]);
      final winner = results.whereType<SupportMutationReservation>().single;
      expect(await f.repo.getMutationById(JournalFixture.id), winner.record);
    },
  );

  journalTest(
    'already-started fact settlement uses original DB custody after UI/admission retirement',
    (f) async {
      final pending = (await f.reserve())!;
      var permissionAndUi = false;
      var originalCustody = true;
      final applied = (await f.repo.settleMutation(
        expected: pending,
        fact: SupportMutationFact.applied,
        hasOriginalDbCustody: () => originalCustody,
      ))!;
      expect(applied.status, SupportMutationStatus.applied);
      expect(
        await f.repo.reserveMutationUndo(
          expected: applied,
          isCurrent: () => permissionAndUi,
        ),
        isNull,
      );
      originalCustody = false;
      expect(
        await f.repo.settleMutation(
          expected: pending,
          fact: SupportMutationFact.failed,
          hasOriginalDbCustody: () => originalCustody,
        ),
        isNull,
      );
      expect((await f.row())!.status, 'applied');
    },
  );

  for (final operation in ['reserve', 'settle', 'undo', 'delete']) {
    journalTest(
      '$operation retirement AFTER actual durable commit cannot falsely return refusal',
      (f) async {
        Future<Object?> Function() run;
        if (operation == 'reserve') {
          run = f.reserve;
        } else if (operation == 'delete') {
          run = f.delete;
        } else {
          final pending = (await f.reserve())!;
          if (operation == 'settle') {
            run = () => f.settle(pending);
          } else {
            final applied = (await f.settle(pending))!;
            run = () => f.undo(applied);
          }
        }
        f.db.afterCommit = () async {
          f.current = false;
        };
        final committed = await run();
        f.clearHooks();
        if (operation == 'delete') {
          expect(committed, isTrue);
          expect(await f.repo.getSessionById(JournalFixture.sessionId), isNull);
        } else {
          expect(committed, isA<SupportMutationReservation>());
          expect(
            await f.repo.getMutationById(JournalFixture.id),
            (committed! as SupportMutationReservation).record,
          );
          expect(
            await f.reserve(
              JournalFixture.candidate.copyWith(id: 'retired-new'),
            ),
            isNull,
            reason:
                'Committed custody is NOT live permission for another effect.',
          );
        }
      },
    );
  }
}
