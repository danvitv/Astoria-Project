import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_theme_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';

import 'support_theme_provider_fixture.dart';
import 'support_theme_deletion_postcommit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final status in [
    'pending',
    'undo_pending',
    'reconciliation_required',
    'unknown',
    'malformed',
    'locked',
  ]) {
    themeProviderTest(
      'atomic protected deletion $status is false with no cache loss',
      (f) async {
        await f.repo.putMutation(
          SupportMutationRecord(
            id: 'synthetic-protected',
            sessionId: ThemeProviderFixture.session,
            domain: 'theme.selection',
            targetId: 'installed-active-selection',
            beforeJson: status == 'malformed'
                ? 'not-native-evidence'
                : SupportMutationEvidence.encode('{}'),
            afterJson: SupportMutationEvidence.encode('{}'),
            status: ['malformed', 'locked'].contains(status)
                ? 'applied'
                : status,
            createdAt: 2,
          ),
        );
        final sessions = f.state.sessions;
        final messages = f.state.messagesBySession;
        if (status == 'locked') {
          f.storage.readError = StateError('Synthetic locked vault');
        }
        expect(
          await f.workspace.deleteSession(ThemeProviderFixture.session),
          isFalse,
        );
        f.storage.readError = null;
        expect(f.state.sessions, same(sessions));
        expect(f.state.messagesBySession, same(messages));
        expect(
          await f.repo.getSessionById(ThemeProviderFixture.session),
          isNotNull,
        );
        expect(await f.repo.getMutationById('synthetic-protected'), isNotNull);
      },
    );
  }
  for (final field in ['before_ciphertext', 'after_ciphertext']) {
    themeProviderTest(
      'unreadable journal $field refuses before any delete with unchanged evidence',
      (f) async {
        expect((await f.apply()).journal, SupportThemeJournalSave.settled);
        final sessions = f.state.sessions;
        final messages = f.state.messagesBySession;
        final journal = await f.db.select(f.db.supportMutationJournal).get();
        final writes = List.of(f.harness.store.checkedWrites);
        var parentReads = 0, refusedReads = 0;
        f.sql.statements.clear();
        f.primitive.event = (event) async {
          if (event.startsWith('decrypt-after:') &&
              event.contains('|support_sessions|')) {
            parentReads++;
          }
          if (event.startsWith('decrypt-before:') &&
              event.contains('|support_mutation_journal|') &&
              event.endsWith('|$field')) {
            refusedReads++;
            throw const SupportCipherException(
              SupportCipherFailure.vaultUnavailable,
            );
          }
        };
        expect(
          await f.workspace.deleteSession(ThemeProviderFixture.session),
          isFalse,
        );
        expect(parentReads, 1);
        expect(refusedReads, 1);
        expect(f.sql.statements.where((s) => s.startsWith('DELETE')), isEmpty);
        f.primitive.event = null;
        expect(f.state.sessions, same(sessions));
        expect(f.state.messagesBySession, same(messages));
        expect(
          await f.repo.getSessionById(ThemeProviderFixture.session),
          isNotNull,
        );
        expect(await f.db.select(f.db.supportMutationJournal).get(), journal);
        expect(f.harness.store.checkedWrites, writes);
        expect(f.backing.activeId, 'b');
      },
    );
  }
  themeProviderTest(
    'typed cipher failure after committed deletion is unknown, never a preflight refusal',
    (f) async {
      expect((await f.apply()).journal, SupportThemeJournalSave.settled);
      final sessions = f.state.sessions;
      final messages = f.state.messagesBySession;
      final writes = List.of(f.harness.store.checkedWrites);
      var deliveries = 0;
      f.sql.statements.clear();
      f.db.afterCommit = () async {
        expect(
          await f.repo.getSessionById(ThemeProviderFixture.session),
          isNull,
        );
        deliveries++;
        throw const SupportCipherException(
          SupportCipherFailure.vaultUnavailable,
        );
      };
      await expectLater(
        f.workspace.deleteSession(ThemeProviderFixture.session),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'fixed unavailable outcome',
            'Support session deletion outcome unavailable.',
          ),
        ),
      );
      expect(deliveries, 1);
      expect(
        f.sql.statements.where(
          (s) => RegExp(r'^DELETE FROM "?support_sessions"?\b').hasMatch(s),
        ),
        hasLength(1),
      );
      f.db.afterCommit = null;
      expect(await f.repo.getSessionById(ThemeProviderFixture.session), isNull);
      expect(
        await f.repo.getMutationsForSession(ThemeProviderFixture.session),
        isEmpty,
      );
      expect(
        await f.repo.getSessionById(ThemeProviderFixture.other),
        isNotNull,
      );
      expect(f.state.sessions, same(sessions));
      expect(f.state.messagesBySession, same(messages));
      expect(f.harness.store.checkedWrites, writes);
      expect(f.backing.activeId, 'b');
    },
  );
  themeProviderTest(
    'empty and settled deletion are actual true, legacy store contract preserved',
    (f) async {
      expect(
        await f.workspace.deleteSession(ThemeProviderFixture.other),
        isTrue,
      );
      expect(await f.repo.getSessionById(ThemeProviderFixture.other), isNull);
      await f.apply();
      expect(
        await f.workspace.deleteSession(ThemeProviderFixture.session),
        isTrue,
      );
      expect(await f.repo.getSessionById(ThemeProviderFixture.session), isNull);
      expect(f.state.sessions, isEmpty);
      expect(f.state.messagesBySession, isEmpty);
    },
  );
  themeProviderTest(
    'STARTED pending blocks active delete, unrelated inactive delete stays independent',
    (f) async {
      final intent = f.emit()!;
      final review = await f.review(intent);
      final gate = f.gate();
      f.harness.store.writeGates.add(gate);
      final job = f.confirm(intent, review);
      await gate.started.future;
      expect(
        await f.workspace.deleteSession(ThemeProviderFixture.other),
        isTrue,
      );
      final sessions = f.state.sessions;
      expect(
        await f.workspace.deleteSession(ThemeProviderFixture.session),
        isFalse,
      );
      expect(f.state.sessions, same(sessions));
      gate.release.complete();
      final result = await job;
      expect(result.effect, SupportThemeEffect.applied);
      expect(result.journal, SupportThemeJournalSave.settled);
      expect(intent.result(result), isNull);
      expect(
        await f.workspace.deleteSession(ThemeProviderFixture.session),
        isTrue,
      );
    },
  );
  for (final undo in [false, true]) {
    themeProviderTest(
      '${undo ? 'Undo' : 'Apply'} reservation first blocks delete before T invocation',
      (f) async {
        if (undo) await f.apply();
        final intent = f.emit()!;
        final review = undo
            ? (await intent.prepareLastUndo())!
            : await f.review(intent);
        final gate = f.barrier();
        var held = false;
        f.db.afterCommit = () async {
          if (held) return;
          final rows = await f.repo.getMutationsForSession(
            ThemeProviderFixture.session,
          );
          if (rows.any(
            (row) => row.status == (undo ? 'undo_pending' : 'pending'),
          )) {
            held = true;
            await gate.wait();
          }
        };
        final job = f.confirm(intent, review);
        await gate.entered.future;
        final writes = List.of(f.harness.store.checkedWrites);
        final sessions = f.state.sessions;
        expect(
          await f.workspace.deleteSession(ThemeProviderFixture.session),
          isFalse,
        );
        expect(f.state.sessions, same(sessions));
        gate.release.complete();
        final result = await job;
        expect(result.effectStarted, isFalse);
        expect(result.effect, SupportThemeEffect.noEffect);
        expect(
          result.status,
          undo
              ? SupportMutationStatus.undoConflict
              : SupportMutationStatus.failed,
        );
        expect(f.harness.store.checkedWrites, writes);
        f.db.afterCommit = null;
        expect(
          await f.workspace.deleteSession(ThemeProviderFixture.session),
          isTrue,
        );
      },
    );
    themeProviderTest(
      'delete first synchronously retires old ${undo ? 'Undo' : 'Apply'} and removes settled history',
      (f) async {
        if (undo) await f.apply();
        final intent = f.emit()!;
        final review = undo
            ? (await intent.prepareLastUndo())!
            : await f.review(intent);
        final writes = List.of(f.harness.store.checkedWrites);
        final deletion = f.workspace.deleteSession(
          ThemeProviderFixture.session,
        );
        expect(intent.confirm(review), isNull);
        expect(await deletion, isTrue);
        expect(f.harness.store.checkedWrites, writes);
        expect(
          await f.repo.getMutationsForSession(ThemeProviderFixture.session),
          isEmpty,
        );
      },
    );
  }
  themeProviderTest(
    'STARTED Undo blocks deletion and original undone fact survives retirement',
    (f) async {
      await f.apply();
      final intent = f.emit()!;
      final undo = (await intent.prepareLastUndo())!;
      final gate = f.gate();
      f.harness.store.writeGates.add(gate);
      final job = f.confirm(intent, undo);
      await gate.started.future;
      expect(
        (await f.repo.getMutationsForSession(
          ThemeProviderFixture.session,
        )).single.status,
        'undo_pending',
      );
      expect(
        await f.workspace.deleteSession(ThemeProviderFixture.session),
        isFalse,
      );
      gate.release.complete();
      final result = await job;
      expect(result.effect, SupportThemeEffect.undone);
      expect(result.status, SupportMutationStatus.undone);
      expect(f.backing.activeId, 'a');
      expect(
        await f.workspace.deleteSession(ThemeProviderFixture.session),
        isTrue,
      );
    },
  );

  themeProviderTest(
    'committed guarded true survives one postcommit reload failure with original owner',
    (f) async {
      final originalWorkspace = f.workspace;
      // Obtain the fixed generic refresh error from the SAME real FIFO with a
      // different source payload, without depending on production message copy.
      var referenceFailures = 0;
      f.sql.event = (event) async {
        if (isBulkSessionReload(event) && referenceFailures == 0) {
          referenceFailures++;
          throw StateError(deletionFailureCanary);
        }
      };
      expect(await originalWorkspace.refresh(), isFalse);
      expect(referenceFailures, 1);
      final fixedReloadError = f.state.error;
      expect(fixedReloadError, payloadFreeFailure);
      f.sql.event = null;
      expect(await originalWorkspace.refresh(), isTrue);
      expect(f.state.error, isNull);

      final applied = await f.apply();
      expect(applied.effect, SupportThemeEffect.applied);
      expect(applied.journal, SupportThemeJournalSave.settled);
      final journal =
          (await f.db.select(f.db.supportMutationJournal).get()).single;
      expect(journal.status, 'applied');
      final sessions = f.state.sessions;
      final messages = f.state.messagesBySession;
      final runtime = f.runtime;
      final lifetime = runtime.lifetime;
      final writes = List.of(f.harness.store.checkedWrites);
      final ordinary = List.of(f.harness.store.ordinaryWrites);
      final savedLists = List.of(f.harness.store.savedLists);
      final checkpoint = ThemeDeletionPostCommitFailure(
        targetAbsent: () async =>
            await f.repo.getSessionById(ThemeProviderFixture.session) == null,
      );
      f.db.afterCommit = checkpoint.afterCommit;
      f.sql.event = checkpoint.sqlEvent;
      final deletion = originalWorkspace.deleteSession(
        ThemeProviderFixture.session,
      );
      expect(await deletion, isTrue);
      expect(checkpoint.committed, isTrue);
      expect(checkpoint.commits, 1);
      expect(checkpoint.reloadQueries, 1);
      expect(checkpoint.failures, 1);
      expect(f.workspace, same(originalWorkspace));
      expect(f.runtime, same(runtime));
      expect(f.runtime.lifetime, lifetime);
      expect(f.state.activeSessionId, ThemeProviderFixture.session);
      expect(f.state.sessions, same(sessions));
      expect(f.state.messagesBySession, same(messages));
      expect(f.state.isBusy, isFalse);
      expect(f.state.error, fixedReloadError);
      f.db.afterCommit = null;
      f.sql.event = null;
      expect(await f.repo.getSessionById(ThemeProviderFixture.session), isNull);
      expect(
        await f.repo.getSessionById(ThemeProviderFixture.other),
        isNotNull,
      );
      expect(
        await f.repo.getMutationsForSession(ThemeProviderFixture.session),
        isEmpty,
      );
      expect(
        await f.repo.getMessagesForSession(ThemeProviderFixture.session),
        isEmpty,
      );
      expect(f.backing.activeId, 'b');
      expect(f.harness.store.checkedWrites, writes);
      expect(f.harness.store.ordinaryWrites, ordinary);
      expect(f.harness.store.savedLists, savedLists);
    },
  );

  for (final retirement in ['commit', 'reload']) {
    themeProviderTest(
      'known guarded true survives original owner retirement at $retirement without late paint',
      (f) async {
        final applied = await f.apply();
        expect(applied.journal, SupportThemeJournalSave.settled);
        final originalWorkspace = f.workspace;
        final writes = List.of(f.harness.store.checkedWrites);
        final ordinary = List.of(f.harness.store.ordinaryWrites);
        final savedLists = List.of(f.harness.store.savedLists);
        final gate = f.barrier();
        final checkpoint = ThemeDeletionPostCommitFailure(
          targetAbsent: () async =>
              await f.repo.getSessionById(ThemeProviderFixture.session) == null,
          commitGate: retirement == 'commit' ? gate : null,
          reloadGate: retirement == 'reload' ? gate : null,
        );
        final states = <Object>[];
        f.container.listen(
          supportWorkspaceProvider,
          (_, next) => states.add(next),
        );
        f.db.afterCommit = checkpoint.afterCommit;
        f.sql.event = checkpoint.sqlEvent;
        final deletion = originalWorkspace.deleteSession(
          ThemeProviderFixture.session,
        );
        await gate.entered.future;
        expect(checkpoint.committed, isTrue);
        f.container.dispose();
        f.disposed = true;
        final retiredPaints = states.length;
        final retiredPresentations = f.presentations.length;
        gate.release.complete();
        expect(await deletion, isTrue);
        expect(checkpoint.commits, 1);
        expect(checkpoint.reloadQueries, retirement == 'reload' ? 1 : 0);
        expect(checkpoint.failures, retirement == 'reload' ? 1 : 0);
        expect(states.length, retiredPaints);
        expect(f.presentations.length, retiredPresentations);
        f.db.afterCommit = null;
        f.sql.event = null;
        expect(
          await f.repo.getSessionById(ThemeProviderFixture.session),
          isNull,
        );
        expect(
          await f.repo.getSessionById(ThemeProviderFixture.other),
          isNotNull,
        );
        expect(
          await f.repo.getMutationsForSession(ThemeProviderFixture.session),
          isEmpty,
        );
        expect(f.backing.activeId, 'b');
        expect(f.harness.store.checkedWrites, writes);
        expect(f.harness.store.ordinaryWrites, ordinary);
        expect(f.harness.store.savedLists, savedLists);
      },
    );
  }

  themeProviderTest(
    'exceptional SQL rollback and postcommit delivery throw the same payloadfree unknown outcome, never false',
    (f) async {
      expect((await f.apply()).journal, SupportThemeJournalSave.settled);
      final originalWorkspace = f.workspace;
      final sessions = f.state.sessions;
      final messages = f.state.messagesBySession;
      final journal =
          (await f.db.select(f.db.supportMutationJournal).get()).single;
      final writes = List.of(f.harness.store.checkedWrites);
      final ordinary = List.of(f.harness.store.ordinaryWrites);
      final savedLists = List.of(f.harness.store.savedLists);
      var sqlFailures = 0;
      f.sql.statements.clear();
      f.sql.event = (event) async {
        if (event.startsWith(
              'select:SELECT id FROM support_mutation_journal WHERE session_id = ?',
            ) &&
            sqlFailures == 0) {
          sqlFailures++;
          throw StateError('SYNTHETIC_SQL_PRIVATE_FAILURE_CANARY');
        }
      };
      StateError? sqlError;
      final sqlDeletion = originalWorkspace.deleteSession(
        ThemeProviderFixture.session,
      );
      try {
        await sqlDeletion;
      } on StateError catch (error) {
        sqlError = error;
      }
      expect(
        sqlError,
        isNotNull,
        reason: 'A boolean is not an unknown outcome.',
      );
      expect(sqlError!.message, payloadFreeFailure);
      expect(f.state.error, payloadFreeFailure);
      final fixedWorkspaceError = f.state.error;
      expect(sqlFailures, 1);
      expect(f.sql.statements.where((s) => s.startsWith('DELETE')), isEmpty);
      f.sql.event = null;
      expect(
        await f.repo.getSessionById(ThemeProviderFixture.session),
        isNotNull,
      );
      expect(await f.db.select(f.db.supportMutationJournal).get(), [journal]);
      expect(f.state.sessions, same(sessions));
      expect(f.state.messagesBySession, same(messages));

      final checkpoint = ThemeDeletionPostCommitFailure(
        targetAbsent: () async =>
            await f.repo.getSessionById(ThemeProviderFixture.session) == null,
        failCommitDelivery: true,
      );
      f.sql.statements.clear();
      f.db.afterCommit = checkpoint.afterCommit;
      f.sql.event = checkpoint.sqlEvent;
      StateError? deliveryError;
      final deliveryDeletion = originalWorkspace.deleteSession(
        ThemeProviderFixture.session,
      );
      try {
        await deliveryDeletion;
      } on StateError catch (error) {
        deliveryError = error;
      }
      expect(
        deliveryError,
        isNotNull,
        reason: 'An undelivered result is not false.',
      );
      expect(deliveryError!.message, sqlError.message);
      expect(deliveryError.message, payloadFreeFailure);
      expect(f.state.error, fixedWorkspaceError);
      expect(checkpoint.commits, 1);
      expect(checkpoint.committed, isTrue);
      expect(checkpoint.failures, 1);
      expect(checkpoint.reloadQueries, 0);
      expect(
        f.sql.statements.where(
          (s) => RegExp(r'^DELETE FROM "?support_sessions"?\b').hasMatch(s),
        ),
        hasLength(1),
      );
      f.db.afterCommit = null;
      f.sql.event = null;
      expect(await f.repo.getSessionById(ThemeProviderFixture.session), isNull);
      expect(
        await f.repo.getSessionById(ThemeProviderFixture.other),
        isNotNull,
      );
      expect(
        await f.repo.getMutationsForSession(ThemeProviderFixture.session),
        isEmpty,
      );
      expect(f.workspace, same(originalWorkspace));
      expect(f.state.sessions, same(sessions));
      expect(f.state.messagesBySession, same(messages));
      expect(f.backing.activeId, 'b');
      expect(f.harness.store.checkedWrites, writes);
      expect(f.harness.store.ordinaryWrites, ordinary);
      expect(f.harness.store.savedLists, savedLists);
    },
  );

  themeProviderTest(
    'original queued delete skipped before start stays false with unchanged cache and settled rows',
    (f) async {
      expect((await f.apply()).journal, SupportThemeJournalSave.settled);
      final originalWorkspace = f.workspace;
      final sessions = f.state.sessions;
      final messages = f.state.messagesBySession;
      final journal =
          (await f.db.select(f.db.supportMutationJournal).get()).single;
      final writes = List.of(f.harness.store.checkedWrites);
      final gate = f.barrier();
      var retainedState = f.state;
      f.container.listen(
        supportWorkspaceProvider,
        (_, next) => retainedState = next,
      );
      var reads = 0;
      f.sql.event = (event) async {
        if (isBulkSessionReload(event) && reads++ == 0) await gate.wait();
      };
      final heldRefresh = originalWorkspace.refresh();
      await gate.entered.future;
      f.sql.statements.clear();
      final deletion = originalWorkspace.deleteSession(
        ThemeProviderFixture.session,
      );
      expect(f.state.sessions, same(sessions));
      expect(f.state.messagesBySession, same(messages));
      f.container.dispose();
      f.disposed = true;
      final retiredState = retainedState;
      gate.release.complete();
      expect(await heldRefresh, isFalse);
      expect(await deletion, isFalse);
      f.sql.event = null;
      expect(f.sql.statements.where((s) => s.startsWith('DELETE')), isEmpty);
      expect(
        await f.repo.getSessionById(ThemeProviderFixture.session),
        isNotNull,
      );
      expect(await f.db.select(f.db.supportMutationJournal).get(), [journal]);
      expect(retainedState, same(retiredState));
      expect(retainedState.sessions, same(sessions));
      expect(retainedState.messagesBySession, same(messages));
      expect(retainedState.activeSessionId, ThemeProviderFixture.session);
      expect(f.harness.store.checkedWrites, writes);
      expect(f.backing.activeId, 'b');
    },
  );
}
