import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/database_restore_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/services/database_snapshot_service.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../startup/startup_memory_keys.dart';
import 'database_restore_core_fixture.dart';
import 'restore_startup_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  restoreCoreTest(
    'Startup adopted safe pre-admit cancel retains guard and allows normal once',
    'DELETE',
    (f) async {
      final s = RestoreStartupFixture(f);
      try {
        final owner = s.owner();
        final repo = DatabaseRestoreRepo(owner: owner);
        final proposal = await repo.prepare();
        await repo.cancel();
        expect(owner.targetReadWriteOpened, false);
        expect(
          () => repo.confirm(proposal),
          throwsA(isA<DatabaseRestoreException>()),
        );
        // Cancel alone is not admission: the real owner/resources must close.
        expect(
          () => s.startup.claimNormalOpening(),
          throwsA(isA<DatabaseRestoreException>()),
        );
        s.expectBusy();
        await repo.close();
        s.expectBusy();
        s.startup.claimNormalOpening();
        expect(
          () => s.owner(),
          throwsA(
            isA<DatabaseRestoreException>().having(
              (e) => e.code,
              'one-way normal admission',
              DatabaseRestoreCode.stale,
            ),
          ),
        );
        s.expectBusy();
      } finally {
        await s.close();
      }
    },
  );

  for (final mode in ['DELETE', 'WAL']) {
    restoreCoreTest(
      'Startup accepted $mode SAME raw query and existing snapshot serialize Drift',
      mode,
      (f) async {
        final s = RestoreStartupFixture(
          f,
          withoutSharedMemorySeed: mode == 'WAL',
        );
        try {
          final owner = s.owner();
          final repo = DatabaseRestoreRepo(owner: owner);
          final result = await repo.restore(repo.confirm(await repo.prepare()));
          expect(result.code, DatabaseRestoreCode.accepted);
          final accepted = result.accepted!;
          final app = accepted.database;
          final identity = app.nativeDataSourceIdentity!;
          expect(identical(accepted.database, app), true);
          expect(
            await ChatRepo(
              app,
            ).countByCharacterId(RestoreCoreFixture.characterId),
            1,
          );
          final before = await SupportRepo(
            app,
            f.cipher,
          ).getSessionById(RestoreCoreFixture.supportId);
          expect(before != null && !before.isLocked, true);
          if (mode == 'WAL') {
            expect(File('${s.target.path}-wal').existsSync(), true);
            // Core's retained EXCLUSIVE source needs no shared-memory reader.
            expect(File('${s.target.path}-shm').existsSync(), false);
          }
          final destination = File('${s.target.parent.path}\\verified.db');
          final native = identity.ownerForApprovedLocalFile(
            destinationPath: destination.path,
            isOriginalOwnerCurrent: () => identical(accepted.database, app),
          );
          expect(native, isNotNull);
          final service = DatabaseSnapshotService(native: native!);
          s.snapshots.add(service);
          final reached = Completer<void>();
          final release = Completer<void>();
          final control = DatabaseSnapshotControl(
            isCurrent: () => true,
            onBoundary: (boundary) async {
              if (boundary == DatabaseSnapshotBoundary.backupPage &&
                  !reached.isCompleted) {
                if (mode == 'WAL') {
                  expect(File('${s.target.path}-shm').existsSync(), false);
                }
                reached.complete();
                await release.future;
              }
            },
          );
          final snapshot = service.create(control: control);
          // Observe original immediately; assertions never abandon a native run.
          final observed = snapshot.then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {},
          );
          Future<void>? competing;
          var entered = false;
          try {
            await Future.any<void>([
              reached.future,
              snapshot.then<void>((result) {
                if (!reached.isCompleted) {
                  throw TestFailure(
                    'Snapshot stopped before backup boundary (${result.status.name})',
                  );
                }
              }),
            ]);
            competing = app.transaction(() async {
              entered = true;
              await SupportRepo(app, f.cipher).renameSession(
                sessionId: RestoreCoreFixture.supportId,
                title: 'SYNTHETIC_AFTER_SNAPSHOT_FENCE',
              );
            });
            unawaited(
              competing.then<void>(
                (_) {},
                onError: (Object _, StackTrace _) {},
              ),
            );
            await Future<void>.delayed(Duration.zero);
            expect(entered, false);
            // Busy create must not overwrite the original drain future.
            expect(
              (await service.create(control: control)).status,
              DatabaseSnapshotStatus.unavailable,
            );
            s.expectBusy();
          } finally {
            if (!release.isCompleted) release.complete();
            await observed;
            await competing;
          }
          final saved = await snapshot;
          expect(
            saved.status,
            DatabaseSnapshotStatus.verified,
            reason: 'Native identity boundary: ${native.identityFailure}',
          );
          expect(saved.handle, isNotNull);
          expect(
            (await service.verifyHandle(
              saved.handle!,
              control: DatabaseSnapshotControl(isCurrent: () => true),
            )).status,
            DatabaseSnapshotStatus.verified,
          );
          if (mode == 'WAL') {
            expect(File('${s.target.path}-shm').existsSync(), false);
          }
          // Strict SAME immutable publication pin is held during rehash, and
          // released before a stock SQLite reader's independent witness.
          await service.close();
          expect(destination.existsSync(), true);
          final physical = f.open(destination, mode: OpenMode.readOnly);
          try {
            expect(f.witness(physical), f.candidateWitness);
          } finally {
            f.closeRaw(physical);
          }
          final competitor = f.open(s.target, mode: OpenMode.readOnly);
          try {
            expect(
              () => competitor.select('SELECT count(*) FROM sqlite_schema'),
              throwsA(isA<SqliteException>()),
            );
          } finally {
            f.closeRaw(competitor);
          }
          expect(entered, true);
          final after = await SupportRepo(
            app,
            f.cipher,
          ).getSessionById(RestoreCoreFixture.supportId);
          expect(after!.title, 'SYNTHETIC_AFTER_SNAPSHOT_FENCE');
          expect(identical(accepted.database, app), true);
          expect(identity.belongsTo(app), true);
          expect(
            () => s.startup.claimNormalOpening(),
            throwsA(isA<DatabaseRestoreException>()),
          );
          await service.close();
          await accepted.close();
          expect(identity.isCurrent, false);
          s.expectBusy(); // integrated restore close did NOT release process guard
          expect(
            () => s.startup.claimNormalOpening(),
            throwsA(isA<DatabaseRestoreException>()),
          );
        } finally {
          await s.close();
        }
      },
    );
  }

  restoreCoreTest(
    'Startup snapshot and accepted close join original fence without releasing guard',
    'DELETE',
    (f) async {
      final s = RestoreStartupFixture(f);
      try {
        final repo = DatabaseRestoreRepo(owner: s.owner());
        final result = await repo.restore(repo.confirm(await repo.prepare()));
        expect(result.code, DatabaseRestoreCode.accepted);
        final accepted = result.accepted!;
        final app = accepted.database;
        final identity = app.nativeDataSourceIdentity!;
        final service = DatabaseSnapshotService(
          native: identity.ownerForApprovedLocalFile(
            destinationPath: '${s.target.parent.path}\\closing-snapshot.db',
            isOriginalOwnerCurrent: () => true,
          )!,
        );
        s.snapshots.add(service);
        final reached = Completer<void>();
        final release = Completer<void>();
        final snapshot = service.create(
          control: DatabaseSnapshotControl(
            isCurrent: () => true,
            onBoundary: (boundary) async {
              if (boundary == DatabaseSnapshotBoundary.backupPage &&
                  !reached.isCompleted) {
                reached.complete();
                await release.future;
              }
            },
          ),
        );
        final observed = snapshot.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {},
        );
        Future<void>? closingService, closingAccepted;
        var serviceClosed = false, acceptedClosed = false;
        try {
          await Future.any<void>([
            reached.future,
            snapshot.then<void>((result) {
              if (!reached.isCompleted) {
                throw TestFailure(
                  'Snapshot stopped before close boundary (${result.status.name})',
                );
              }
            }),
          ]);
          closingService = service.close().then((_) {
            serviceClosed = true;
          });
          closingAccepted = accepted.close().then((_) {
            acceptedClosed = true;
          });
          unawaited(
            closingService.then<void>(
              (_) {},
              onError: (Object _, StackTrace _) {},
            ),
          );
          unawaited(
            closingAccepted.then<void>(
              (_) {},
              onError: (Object _, StackTrace _) {},
            ),
          );
          await Future<void>.delayed(Duration.zero);
          expect(serviceClosed, false);
          expect(acceptedClosed, false);
          expect(
            identity.isCurrent,
            false,
          ); // retire before joining, not raw close
          s.expectBusy();
        } finally {
          if (!release.isCompleted) release.complete();
          await observed;
          await closingService;
          await closingAccepted;
        }
        expect((await snapshot).status, DatabaseSnapshotStatus.stale);
        expect(serviceClosed, true);
        expect(acceptedClosed, true);
        s.expectBusy();
      } finally {
        await s.close();
      }
    },
  );

  restoreCoreTest(
    'Startup reached raw-close failure retains process guard and blocks fallback',
    'DELETE',
    (f) async {
      final s = RestoreStartupFixture(f);
      var failClose = true;
      var reachedClose = false;
      try {
        final owner = s.owner(
          fault: (boundary) {
            if (boundary == DatabaseRestoreTestBoundary.rawClose && failClose) {
              reachedClose = true;
              throw StateError('Synthetic raw close failure');
            }
          },
        );
        final repo = DatabaseRestoreRepo(owner: owner);
        final result = await repo.restore(repo.confirm(await repo.prepare()));
        expect(result.code, DatabaseRestoreCode.accepted);
        await expectLater(
          result.accepted!.close(),
          throwsA(
            isA<DatabaseRestoreException>().having(
              (e) => e.code,
              'close failure',
              DatabaseRestoreCode.recoveryRequired,
            ),
          ),
        );
        expect(reachedClose, true);
        expect(owner.normalOpeningBlocked, true);
        s.expectBusy();
        expect(
          () => s.startup.claimNormalOpening(),
          throwsA(isA<DatabaseRestoreException>()),
        );
        expect(
          () => s.startup.closeForTesting(),
          throwsA(isA<DatabaseRestoreException>()),
        );
        failClose = false;
        await owner
            .close(); // explicit disposal retry does not revive admission
        expect(owner.normalOpeningBlocked, true);
        s.expectBusy();
        expect(
          () => s.startup.claimNormalOpening(),
          throwsA(isA<DatabaseRestoreException>()),
        );
      } finally {
        failClose = false;
        await s.close();
      }
    },
  );

  for (final entry in <(String, String?)>[
    ('missing', null),
    ('empty', ''),
    ('invalid', 'bad-key'),
  ]) {
    restoreCoreTest(
      'Startup ${entry.$1} key denies zero encrypted rows before target RW',
      'DELETE',
      (f) async {
        // Actual compiled candidate, explicitly emptied encrypted tables. This
        // shows preflight is necessary even when no decrypt row could exercise it.
        final candidate = f.open(f.candidate);
        try {
          for (final table in [
            'support_messages',
            'support_context_blocks',
            'support_mutation_journal',
            'support_reports',
            'support_sessions',
          ]) {
            candidate.execute('DELETE FROM $table');
          }
        } finally {
          f.closeRaw(candidate);
        }
        final s = RestoreStartupFixture(f);
        try {
          final storage = StartupMemoryKeys(entry.$2);
          final base = SupportPayloadCipher(
            vault: CredentialVault(
              storage: storage,
              buildChannel: 'startup_synthetic',
            ),
          );
          final readOnly = SupportPayloadCipher.readOnly(
            delegate: base,
            gate: (read) => read(),
          );
          final owner = s.owner(cipher: readOnly);
          await expectLater(
            DatabaseRestoreRepo(owner: owner).prepare(),
            throwsA(isA<DatabaseRestoreException>()),
          );
          expect(owner.targetReadWriteOpened, false);
          expect(storage.reads, 1);
          expect(storage.writes, 0);
          expect(storage.deletes, 0);
          await owner.close();
          s.expectBusy();
          s.startup.claimNormalOpening();
        } finally {
          await s.close();
        }
      },
    );
  }

  restoreCoreTest(
    'Startup real encrypted candidate rejects wrong existing key read-only',
    'DELETE',
    (f) async {
      final s = RestoreStartupFixture(f);
      try {
        final storage = StartupMemoryKeys(
          base64UrlEncode(List<int>.filled(32, 23)),
        );
        final cipher = SupportPayloadCipher.readOnly(
          delegate: SupportPayloadCipher(
            vault: CredentialVault(
              storage: storage,
              buildChannel: 'startup_synthetic',
            ),
          ),
          gate: (read) => read(),
        );
        final owner = s.owner(cipher: cipher);
        await expectLater(
          DatabaseRestoreRepo(owner: owner).prepare(),
          throwsA(isA<DatabaseRestoreException>()),
        );
        expect(owner.targetReadWriteOpened, false);
        expect(storage.reads > 1, true); // preflight plus actual owning decrypt
        expect(storage.writes, 0);
        expect(storage.deletes, 0);
        s.expectBusy();
      } finally {
        await s.close();
      }
    },
  );
}
