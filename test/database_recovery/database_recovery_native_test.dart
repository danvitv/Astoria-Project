import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/database_restore_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/services/database_snapshot_service.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/startup/database_startup.dart';
import 'package:glaze_flutter/features/database_recovery/database_recovery_controller.dart';
import 'package:glaze_flutter/features/database_recovery/database_recovery_screen.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';

import 'database_recovery_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final journal in ['DELETE', 'WAL']) {
    testWidgets(
      'D2 production screen $journal picker -> destructive tap -> SAME DB query and backup',
      (tester) async {
        final f = DatabaseRecoveryFixture(journal: journal);
        await tester.runAsync(f.create);
        final picker = ControlledRecoveryPicker();
        final previous = FilePickerPlatform.instance;
        FilePickerPlatform.instance = picker;
        final controller = f.controller();
        DatabaseSnapshotService? snapshot;
        try {
          await tester.pumpWidget(
            DatabaseRecoveryApp(
              controller: controller,
              targetPath: f.target.path,
            ),
          );
          await _tap(tester, 'recovery-pick');
          expect(picker.calls, 1);
          expect(picker.actualType, FileType.custom);
          expect(picker.actualExtensions, ['db']);
          expect(picker.actualAllowMultiple, false);
          expect(picker.actualWithData, false);
          expect(f.credentialCompositions, 0);
          picker.pending.complete(f.selection());
          await tester.runAsync(controller.joinForTesting);
          await tester.pump();
          expect(f.operations.single.owner!.targetReadWriteOpened, false);
          expect(find.text(f.candidate.path), findsOneWidget);
          expect(find.text(f.target.path), findsOneWidget);
          final button = tester.widget<GlazeActionButton>(
            find.byKey(const ValueKey('recovery-confirm')),
          );
          await _tap(
            tester,
            'recovery-confirm',
          ); // Actual production onTap admission.
          button
              .onTap!(); // Duplicate captured callback cannot issue another restore.
          await tester.runAsync(controller.joinForTesting);
          expect(f.publications, 1);
          expect(f.bootstraps, 1);
          expect(f.normalOpens, 0);
          expect(identical(f.published, f.process), true);
          final accepted = f.operations.single.accepted!;
          expect(identical(f.process.database, accepted.database), true);
          expect(identical(f.process.capture.db, accepted.database), true);
          await tester.runAsync(() async {
            expect(
              await ChatRepo(
                f.process.database,
              ).countByCharacterId('recovery-character'),
              1,
            );
            expect(
              (await SupportRepo(
                f.process.database,
                f.credentials.cipher,
              ).getSessionById('recovery-support'))!.title,
              'candidate',
            );
            final source = f.process.database.nativeDataSourceIdentity!;
            snapshot = DatabaseSnapshotService(
              native: source.ownerForApprovedLocalFile(
                destinationPath: '${f.target.parent.path}\\screen-verified.db',
                isOriginalOwnerCurrent: () =>
                    identical(f.process.database, accepted.database),
              )!,
            );
            final result = await snapshot!.create(
              control: DatabaseSnapshotControl(isCurrent: () => true),
            );
            expect(result.status, DatabaseSnapshotStatus.verified);
            expect(
              (await snapshot!.verifyHandle(
                result.handle!,
                control: DatabaseSnapshotControl(isCurrent: () => true),
              )).status,
              DatabaseSnapshotStatus.verified,
            );
          });
          // The SAME value overrides used by main survive scope replacement.
          final first = ProviderContainer(
            overrides: f.process.providerOverrides,
          );
          expect(identical(first.read(appDbProvider), accepted.database), true);
          expect(
            identical(
              first.read(llmRequestCaptureRepoProvider),
              f.process.capture,
            ),
            true,
          );
          expect(
            identical(first.read(credentialVaultProvider), f.credentials.vault),
            true,
          );
          expect(
            identical(
              first.read(supportPayloadCipherProvider),
              f.credentials.cipher,
            ),
            true,
          );
          first.dispose();
          final replacement = ProviderContainer(
            overrides: f.process.providerOverrides,
          );
          expect(
            identical(replacement.read(appDbProvider), accepted.database),
            true,
          );
          expect(
            identical(
              replacement.read(llmRequestCaptureRepoProvider),
              f.process.capture,
            ),
            true,
          );
          replacement.dispose();
          // Replacing the recovery root disposes it too. Start/join retirement
          // in real async BEFORE that first fake-timer widget disposal.
          await tester.runAsync(() async {
            controller.retireView();
            await f.operations.single.cancelAndJoin();
          });
          for (final key in [
            'first-keyed-normal-scope',
            'restarted-keyed-normal-scope',
          ]) {
            await tester.pumpWidget(
              KeyedSubtree(
                key: ValueKey(key),
                child: ProcessDatabaseScope(
                  process: f.process,
                  child: Consumer(
                    builder: (_, ref, _) {
                      expect(
                        identical(ref.watch(appDbProvider), accepted.database),
                        true,
                      );
                      expect(
                        identical(
                          ref.watch(llmRequestCaptureRepoProvider),
                          f.process.capture,
                        ),
                        true,
                      );
                      ref.watch(llmRequestCaptureInstallationProvider);
                      return const SizedBox.shrink();
                    },
                  ),
                ),
              ),
            );
            f.expectBusy();
          }
          f.expectBusy();
          expect(f.keys.writes, 0);
          expect(f.keys.deletes, 0);
          await tester.pumpWidget(const SizedBox.shrink());
          f.expectBusy(); // Widget disposal is NOT process termination.
        } finally {
          if (!picker.pending.isCompleted) picker.pending.complete(null);
          await tester.runAsync(() async {
            controller.retireView();
          });
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(
            () => f.close(
              controller,
              extraJoin: () async {
                await snapshot?.close();
              },
            ),
          );
          FilePickerPlatform.instance = previous;
        }
      },
      skip: !Platform.isWindows,
    );
  }

  testWidgets(
    'D2 original platform picker cancel remains busy and ignores late path',
    (tester) async {
      final f = DatabaseRecoveryFixture();
      await tester.runAsync(f.create);
      final picker = ControlledRecoveryPicker();
      final previous = FilePickerPlatform.instance;
      FilePickerPlatform.instance = picker;
      final controller = f.controller();
      try {
        await tester.pumpWidget(
          DatabaseRecoveryApp(
            controller: controller,
            targetPath: f.target.path,
          ),
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(DatabaseRecoveryScreen)),
        );
        await _tap(tester, 'recovery-pick');
        await _tap(tester, 'recovery-cancel');
        expect(container.read(databaseRecoveryControllerProvider).busy, true);
        await _tap(tester, 'recovery-pick');
        await _tap(tester, 'recovery-continue');
        expect(picker.calls, 1);
        expect(f.normalOpens, 0);
        expect(f.bootstraps, 0);
        expect(f.credentialCompositions, 0);
        picker.pending.complete(f.selection());
        await tester.runAsync(controller.joinForTesting);
        await tester.pump();
        expect(
          container.read(databaseRecoveryControllerProvider).phase,
          DatabaseRecoveryPhase.ready,
        );
        expect(f.operations.single.owner, isNull);
        expect(f.keys.reads, 0);
        expect(f.keys.writes, 0);
        expect(f.keys.deletes, 0);
        f.expectBusy();
      } finally {
        if (!picker.pending.isCompleted) picker.pending.complete(null);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() => f.close(controller));
        FilePickerPlatform.instance = previous;
      }
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'D2 pre-admit cancel and stale old destructive handler have zero target RW',
    (tester) async {
      final f = DatabaseRecoveryFixture();
      await tester.runAsync(f.create);
      final controller = f.controller(picker: () async => f.selection());
      try {
        await tester.pumpWidget(
          DatabaseRecoveryApp(
            controller: controller,
            targetPath: f.target.path,
          ),
        );
        await _tap(tester, 'recovery-pick');
        await tester.runAsync(controller.joinForTesting);
        await tester.pump();
        final old = tester
            .widget<GlazeActionButton>(
              find.byKey(const ValueKey('recovery-confirm')),
            )
            .onTap!;
        await _tap(tester, 'recovery-cancel');
        await tester.runAsync(controller.joinForTesting);
        await tester.pump();
        await _tap(tester, 'recovery-pick');
        await tester.runAsync(controller.joinForTesting);
        await tester.pump();
        final recoveryState = ProviderScope.containerOf(
          tester.element(find.byType(DatabaseRecoveryScreen)),
        ).read(databaseRecoveryControllerProvider);
        expect(
          recoveryState.phase,
          DatabaseRecoveryPhase.proposal,
          reason:
              'Second fresh preparation: ${recoveryState.code?.name}; '
              'key: ${recoveryState.keyFailure?.name}',
        );
        old();
        old(); // A→B→A cannot revive the first proposal/issuer.
        await tester.runAsync(controller.joinForTesting);
        expect(f.operations.length, 2);
        expect(
          f.operations.every((o) => !o.owner!.targetReadWriteOpened),
          true,
        );
        expect(f.operations.every((o) => !o.confirmed), true);
        expect(f.normalOpens, 0);
        expect(f.publications, 0);
        f.expectBusy();
      } finally {
        // Start original native cancellation in real async, not a widget fake
        // timer zone that runAsync cannot drain while awaiting its close.
        await tester.runAsync(() async {
          controller.retireView();
        });
        await tester.pumpWidget(const SizedBox.shrink());
        f.expectBusy(); // Retiring/disposal still never releases process custody.
        await tester.runAsync(() => f.close(controller));
      }
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'D2 post-admit cancellation joins actual reverse and never falls back',
    (tester) async {
      final f = DatabaseRecoveryFixture();
      await tester.runAsync(f.create);
      late DatabaseRecoveryController controller;
      var reached = false;
      controller = f.controller(
        picker: () async => f.selection(),
        fault: (boundary) {
          if (boundary == DatabaseRestoreTestBoundary.acceptance) {
            reached = true;
            unawaited(controller.cancel());
          }
        },
      );
      try {
        await tester.pumpWidget(
          DatabaseRecoveryApp(
            controller: controller,
            targetPath: f.target.path,
          ),
        );
        await _tap(tester, 'recovery-pick');
        await tester.runAsync(controller.joinForTesting);
        await tester.pump();
        await _tap(tester, 'recovery-confirm');
        await tester.runAsync(controller.joinForTesting);
        await tester.pump();
        expect(reached, true);
        expect(f.operations.single.owner!.targetReadWriteOpened, true);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(DatabaseRecoveryScreen)),
        );
        expect(
          container.read(databaseRecoveryControllerProvider).phase,
          DatabaseRecoveryPhase.blocked,
        );
        expect(
          container.read(databaseRecoveryControllerProvider).code,
          DatabaseRestoreCode.originalRestored,
        );
        expect(f.publications, 0);
        expect(f.normalOpens, 0);
        f.expectBusy();
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() => f.close(controller));
      }
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'D2 blocked recovery shell hydrates no ordinary DB or credential providers',
    (tester) async {
      var dbCalls = 0, credentialCalls = 0, bootstrapCalls = 0;
      final controller = DatabaseRecoveryController(
        process: null,
        initialBlock: DatabaseRestoreCode.busy,
        bootstrap: () async {
          bootstrapCalls++;
        },
        publishNormal: (_) => throw StateError('No publication'),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDbProvider.overrideWith((_) {
              dbCalls++;
              throw StateError('No ordinary DB');
            }),
            credentialStorageProvider.overrideWith((_) {
              credentialCalls++;
              throw StateError('No vault');
            }),
          ],
          child: DatabaseRecoveryApp(controller: controller),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('recovery-confirm')), findsNothing);
      expect(find.byKey(const ValueKey('recovery-continue')), findsNothing);
      expect(dbCalls, 0);
      expect(credentialCalls, 0);
      expect(bootstrapCalls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.runAsync(() async {
    await tester.tap(finder);
  });
  await tester.pump();
}
