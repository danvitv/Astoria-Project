import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/database_restore_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:sqlite3/sqlite3.dart';

import 'database_restore_core_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  restoreCoreTest(
    'Restore core failed originals release never reports deleted original as retained',
    'DELETE',
    (f) async {
      final owner = f.owner();
      final repo = DatabaseRestoreRepo(owner: owner);
      final result = await repo.restore(repo.confirm(await repo.prepare()));
      expect(result.code, DatabaseRestoreCode.accepted);
      expect(owner.hasRetainedOriginals, true);
      final accepted = result.accepted!;
      final app = accepted.database;
      final archive = f.archives().single;
      final original = File('${archive.path}\\original.db');
      final blocker = File('${archive.path}\\fixture-release-blocker.txt');
      expect(original.existsSync(), true);
      blocker.writeAsStringSync(
        'SYNTHETIC_RELEASE_CLEANUP_BLOCKER',
        flush: true,
      );

      Object? firstError;
      StackTrace? firstStack;
      try {
        await accepted.releaseOriginalsAfterAcceptedHandoff();
      } catch (error, stack) {
        // Observe the original real removal failure immediately, without
        // exposing its stack or replacing it with a callback/fake status.
        firstError = error;
        firstStack = stack;
      }
      final originalDeleted = !original.existsSync();
      final realRemovalBlocked =
          archive.existsSync() &&
          blocker.existsSync() &&
          archive.listSync().length == 1;
      expect(firstError != null && firstStack != null, true);
      expect(realRemovalBlocked, true);
      expect(originalDeleted, true);
      expect(
        firstError is DatabaseRestoreException &&
            firstError.code == DatabaseRestoreCode.recoveryRequired,
        true,
      );
      expect(owner.hasRetainedOriginals, false);

      // Cleanup remains retryable, not falsely marked complete. Keep the same
      // real blocker in place; no fixture file is deleted while the owner lives.
      Object? retryError;
      StackTrace? retryStack;
      try {
        await accepted.releaseOriginalsAfterAcceptedHandoff();
      } catch (error, stack) {
        retryError = error;
        retryStack = stack;
      }
      final retryRemovalBlocked =
          archive.existsSync() &&
          !original.existsSync() &&
          blocker.existsSync() &&
          archive.listSync().length == 1;
      expect(retryStack != null && retryRemovalBlocked, true);
      expect(
        retryError is DatabaseRestoreException &&
            retryError.code == DatabaseRestoreCode.recoveryRequired,
        true,
      );
      expect(owner.hasRetainedOriginals, false);
      expect(identical(accepted.database, app), true);
      expect(app.nativeDataSourceIdentity, isNotNull);
      expect(
        await ChatRepo(app).countByCharacterId(RestoreCoreFixture.characterId),
        1,
      );
      final support = SupportRepo(app, f.cipher);
      final renamed = await support.renameSession(
        sessionId: RestoreCoreFixture.supportId,
        title: 'SYNTHETIC_SAVED_AFTER_RELEASE_FAILURE',
      );
      expect(renamed != null && !renamed.isLocked, true);
      final saved = await support.getSessionById(RestoreCoreFixture.supportId);
      expect(
        saved != null &&
            !saved.isLocked &&
            saved.title == 'SYNTHETIC_SAVED_AFTER_RELEASE_FAILURE',
        true,
      );
      expect(identical(accepted.database, app), true);
      expect(
        () => f.owner(),
        throwsA(
          isA<DatabaseRestoreException>().having(
            (e) => e.code,
            'original kernel owner remains held',
            DatabaseRestoreCode.busy,
          ),
        ),
      );

      // Exact fixture-owned blocker/archive cleanup follows ACTUAL awaited
      // wrapper/raw/pin/kernel close. The existing fixture closes idempotently.
      await accepted.close();
      expect(owner.hasRetainedOriginals, false);
      blocker.deleteSync();
      archive.deleteSync();
    },
  );
  for (final mode in ['DELETE', 'WAL']) {
    restoreCoreTest(
      'Restore core $mode full compiled candidate originals SAME AppDb and save',
      mode,
      (f) async {
        final owner = f.owner();
        final repo = DatabaseRestoreRepo(owner: owner);
        final proposal = await repo.prepare();
        expect(owner.targetReadWriteOpened, false);
        final result = await repo.restore(repo.confirm(proposal));
        expect(result.code, DatabaseRestoreCode.accepted);
        expect(result.bootstrapMayHaveTouched, true);
        expect(owner.hasRetainedOriginals, true);
        expect(f.archives().length, 1);
        final accepted = result.accepted!;
        final app = accepted.database;
        expect(app.allTables.length, 61);
        expect(app.nativeDataSourceIdentity, isNotNull);
        expect(
          await ChatRepo(
            app,
          ).countByCharacterId(RestoreCoreFixture.characterId),
          1,
        );
        final support = SupportRepo(app, f.cipher);
        final message = await support.getMessageById('core-message');
        expect(
          message != null &&
              !message.isLocked &&
              message.body.endsWith('candidate'),
          true,
        );
        final renamed = await support.renameSession(
          sessionId: RestoreCoreFixture.supportId,
          title: 'SYNTHETIC_SAVED_AFTER_CORE',
        );
        expect(renamed != null && !renamed.isLocked, true);
        expect(identical(accepted.database, app), true);
        // Explicit retention policy is exercised only after actual owning save.
        if (mode == 'DELETE') {
          await accepted.releaseOriginalsAfterAcceptedHandoff();
          expect(owner.hasRetainedOriginals, false);
        }
        await accepted.close();
        if (mode == 'WAL') f.expectArchivedOriginal();
        final raw = f.open(f.target, mode: OpenMode.readOnly);
        final ciphertext =
            raw
                    .select('SELECT title_ciphertext FROM support_sessions')
                    .single
                    .values
                    .single
                as String;
        expect(ciphertext.contains('SYNTHETIC_SAVED_AFTER_CORE'), false);
        expect(
          raw.select('SELECT count(*) FROM core_extra').single.values.single,
          10,
        );
        f.closeRaw(raw);
      },
    );
  }

  restoreCoreTest(
    'Restore core absent source and preconfirmation cancel never RW opens target',
    'DELETE',
    (f) async {
      final absent = DatabaseRestoreRepo();
      await expectLater(
        absent.prepare(),
        throwsA(
          isA<DatabaseRestoreException>().having(
            (e) => e.code,
            'fixed code',
            DatabaseRestoreCode.unavailable,
          ),
        ),
      );
      final owner = f.owner();
      final repo = DatabaseRestoreRepo(owner: owner);
      final rawBefore = f.target.readAsBytesSync();
      final proposal = await repo.prepare();
      expect(owner.targetReadWriteOpened, false);
      expect(
        () => f.owner(),
        throwsA(
          isA<DatabaseRestoreException>().having(
            (e) => e.code,
            'real kernel owner contention',
            DatabaseRestoreCode.busy,
          ),
        ),
      );
      // A real ordinary SQLite writer still works before native admission.
      final writer = f.open(f.target);
      writer.execute('BEGIN IMMEDIATE');
      writer.execute('ROLLBACK');
      f.closeRaw(writer);
      final confirmation = repo.confirm(proposal);
      await repo.cancel();
      final refused = await repo.restore(confirmation);
      expect(refused.code, DatabaseRestoreCode.stale);
      expect(owner.targetReadWriteOpened, false);
      expect(
        RestoreCoreFixture.sameBytes(f.target.readAsBytesSync(), rawBefore),
        true,
      );
      expect(f.archives().isEmpty, true);
    },
  );

  restoreCoreTest(
    'Restore core WAL real busy bootstrap refusal has unknown byte scope',
    'WAL',
    (f) async {
      final writer = f.open(f.target);
      writer.execute('BEGIN IMMEDIATE');
      writer.execute(
        "UPDATE core_extra SET n='UNCOMMITTED_SYNTHETIC' WHERE id=0",
      );
      final owner = f.owner();
      final repo = DatabaseRestoreRepo(owner: owner);
      final proposal = await repo.prepare();
      final result = await repo.restore(repo.confirm(proposal));
      expect(result.code, DatabaseRestoreCode.busy);
      expect(result.bootstrapMayHaveTouched, true);
      expect(owner.targetReadWriteOpened, true);
      expect(owner.hasRetainedOriginals, false);
      await repo.close();
      writer.execute('ROLLBACK');
      f.closeRaw(writer);
      f.expectOriginal();
    },
  );

  restoreCoreTest(
    'Restore core compiled constraint and trigger layout cannot be omitted',
    'DELETE',
    (f) async {
      final raw = f.open(f.candidate);
      raw.execute('DROP TRIGGER llm_call_event_rows_no_update');
      f.closeRaw(raw);
      final owner = f.owner();
      await expectLater(
        DatabaseRestoreRepo(owner: owner).prepare(),
        throwsA(
          isA<DatabaseRestoreException>().having(
            (e) => e.code,
            'fixed code',
            DatabaseRestoreCode.invalidCandidate,
          ),
        ),
      );
      expect(owner.targetReadWriteOpened, false);
      f.expectOriginal();
    },
  );

  restoreCoreTest(
    'Restore core changed candidate writer and immutable pin deny unsupported source',
    'DELETE',
    (f) async {
      // A pre-existing write HANDLE makes genuine immutable pin admission fail.
      final changing = f.candidate.openSync(mode: FileMode.append);
      try {
        final owner = f.owner();
        await expectLater(
          DatabaseRestoreRepo(owner: owner).prepare(),
          throwsA(isA<DatabaseRestoreException>()),
        );
        expect(owner.targetReadWriteOpened, false);
        expect(owner.hasRetainedOriginals, false);
      } finally {
        changing.closeSync();
      }
      f.expectOriginal();
    },
  );

  restoreCoreTest(
    'Restore core actual acceptance failure FULL original reverse preserves old layout',
    'DELETE',
    (f) async {
      final old = f.open(f.target);
      old.execute('PRAGMA user_version = 136');
      final original = f.witness(old);
      f.closeRaw(old);
      var acceptanceReached = false;
      var reverseReached = false;
      final owner = f.owner(
        fault: (boundary) {
          if (boundary == DatabaseRestoreTestBoundary.acceptance) {
            acceptanceReached = true;
            throw StateError(
              'Synthetic failure AFTER actual owning acceptance',
            );
          }
          if (boundary == DatabaseRestoreTestBoundary.reverseCopy)
            reverseReached = true;
        },
      );
      final repo = DatabaseRestoreRepo(owner: owner);
      final result = await repo.restore(repo.confirm(await repo.prepare()));
      expect(acceptanceReached && reverseReached, true);
      expect(result.code, DatabaseRestoreCode.originalRestored);
      expect(owner.hasRetainedOriginals, true);
      expect(owner.normalOpeningBlocked, false);
      await repo.close();
      f.expectArchivedOriginal(expected: original);
      final raw = f.open(f.target, mode: OpenMode.readOnly);
      expect(
        f.witness(raw) == original,
        true,
        reason: 'Whole native reverse of original v136 layout',
      );
      f.closeRaw(raw);
    },
  );

  restoreCoreTest(
    'Restore core WAL reached reverse fault retains originals and blocks normal opening',
    'WAL',
    (f) async {
      var reverseReached = false;
      var fail = true;
      final owner = f.owner(
        fault: (boundary) {
          if (boundary == DatabaseRestoreTestBoundary.acceptance)
            throw StateError('Synthetic accepted-open failure');
          if (boundary == DatabaseRestoreTestBoundary.reverseCopy) {
            reverseReached = true;
            if (fail)
              throw StateError('Synthetic real reverse-boundary failure');
          }
        },
      );
      final repo = DatabaseRestoreRepo(owner: owner);
      final result = await repo.restore(repo.confirm(await repo.prepare()));
      expect(reverseReached, true);
      expect(result.code, DatabaseRestoreCode.recoveryRequired);
      expect(result.accepted, isNull);
      expect(owner.hasRetainedOriginals && owner.normalOpeningBlocked, true);
      expect(f.interruptionExists, true);
      expect(f.archives().length, 1);
      fail = false;
      await repo.close();
      expect(owner.normalOpeningBlocked, true);
      expect(f.archives().length, 1);
    },
  );

  restoreCoreTest(
    'Restore core reached raw close fault retains ownership originals and marker',
    'DELETE',
    (f) async {
      var closeReached = false;
      var fail = true;
      final owner = f.owner(
        fault: (boundary) {
          if (boundary == DatabaseRestoreTestBoundary.rawClose) {
            closeReached = true;
            if (fail)
              throw StateError('Synthetic actual raw-close boundary failure');
          }
        },
      );
      final repo = DatabaseRestoreRepo(owner: owner);
      final result = await repo.restore(repo.confirm(await repo.prepare()));
      expect(result.code, DatabaseRestoreCode.accepted);
      await expectLater(
        result.accepted!.close(),
        throwsA(isA<DatabaseRestoreException>()),
      );
      expect(closeReached, true);
      expect(owner.hasRetainedOriginals && owner.normalOpeningBlocked, true);
      expect(f.interruptionExists, true);
      expect(
        () => result.accepted!.database,
        throwsA(isA<DatabaseRestoreException>()),
      );
      fail = false;
      await owner.close();
      expect(owner.normalOpeningBlocked, true);
      expect(f.archives().length, 1);
    },
  );

  restoreCoreTest(
    'Restore core confirmation one-use wrong owner and persisted marker no approval',
    'DELETE',
    (f) async {
      final other = RestoreCoreFixture('DELETE');
      await other.create();
      try {
        final owner = f.owner();
        final repo = DatabaseRestoreRepo(owner: owner);
        final confirmation = repo.confirm(await repo.prepare());
        final wrong = other.owner();
        final refused = await DatabaseRestoreRepo(
          owner: wrong,
        ).restore(confirmation);
        expect(refused.code, DatabaseRestoreCode.stale);
        expect(wrong.targetReadWriteOpened, false);
        final result = await repo.restore(confirmation);
        expect(result.code, DatabaseRestoreCode.accepted);
        expect(
          (await repo.restore(confirmation)).code,
          DatabaseRestoreCode.stale,
        );
        await result.accepted!.close();
        // A marker is only a locator/blocking fact. No persisted decision replay.
        File(
          '${f.directory.path}\\.astoria-restore-interrupted',
        ).writeAsStringSync(
          'restore-interrupted-v1\n.restore-synthetic-locator\n',
          flush: true,
        );
        final interrupted = f.owner();
        expect(interrupted.normalOpeningBlocked, true);
        await expectLater(
          DatabaseRestoreRepo(owner: interrupted).prepare(),
          throwsA(
            isA<DatabaseRestoreException>().having(
              (e) => e.code,
              'fixed code',
              DatabaseRestoreCode.interruptedRequiresFreshConfirmation,
            ),
          ),
        );
        expect(interrupted.targetReadWriteOpened, false);
      } finally {
        await other.close();
      }
    },
  );

  restoreCoreTest(
    'Restore core admitted cancellation after actual acceptance settles FULL reverse',
    'WAL',
    (f) async {
      Future<void>? cancellation;
      var acceptanceReached = false;
      late NativeDatabaseRestoreOwner owner;
      owner = f.owner(
        fault: (boundary) {
          if (boundary == DatabaseRestoreTestBoundary.acceptance) {
            acceptanceReached = true;
            cancellation = owner.cancel();
          }
        },
      );
      final repo = DatabaseRestoreRepo(owner: owner);
      final result = await repo.restore(repo.confirm(await repo.prepare()));
      await cancellation;
      expect(acceptanceReached, true);
      expect(result.code, DatabaseRestoreCode.originalRestored);
      expect(owner.hasRetainedOriginals, true);
      await repo.close();
      f.expectOriginal();
    },
  );

  restoreCoreTest(
    'Restore core retained WAL bootstrap restores logical original not raw header',
    'WAL',
    (f) async {
      final wal = File('${f.target.path}-wal');
      expect(wal.existsSync() && wal.lengthSync() > 32, true);
      final bytes = f.target.readAsBytesSync();
      bytes.fillRange(0, 16, 0x41);
      f.target.writeAsBytesSync(bytes, flush: true);
      var accepted = false;
      final owner = f.owner(
        fault: (boundary) {
          if (boundary == DatabaseRestoreTestBoundary.acceptance) {
            accepted = true;
            throw StateError(
              'Synthetic reverse after authorized WAL bootstrap',
            );
          }
        },
      );
      final repo = DatabaseRestoreRepo(owner: owner);
      final proposal = await repo.prepare();
      expect(owner.targetReadWriteOpened, false);
      expect(f.target.readAsBytesSync().take(16).every((b) => b == 0x41), true);
      final result = await repo.restore(repo.confirm(proposal));
      expect(accepted, true);
      expect(result.code, DatabaseRestoreCode.originalRestored);
      expect(result.bootstrapMayHaveTouched, true);
      await repo.close();
      f.expectOriginal();
      expect(
        f.target.readAsBytesSync().take(16).every((b) => b == 0x41),
        false,
      );
    },
  );
}
