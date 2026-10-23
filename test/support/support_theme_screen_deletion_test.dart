import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_sessions_panel.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_theme_controls.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_theme_delete_sheet.dart';

import 'support_theme_screen_helpers.dart';
import 'support_theme_deletion_postcommit.dart';

/// Observation only: the ORIGINAL provider's actual terminal error/busy update
/// completes this signal, never the deletion operation or its result.
Future<String> _workspaceFailed(ThemeScreenFixture f) {
  final reached = Completer<String>();
  final subscription = f.container.listen(supportWorkspaceProvider, (_, next) {
    if (!next.isBusy && next.error != null && !reached.isCompleted) {
      reached.complete(next.error!);
    }
  });
  return reached.future.whenComplete(subscription.close);
}

Future<void> _openDeletion(WidgetTester tester, ThemeScreenFixture f) async {
  await f.gesture(
    tester,
    () => tester.tap(find.byKey(const ValueKey('mobile_open_sessions_btn'))),
  );
  await tester.pumpAndSettle();
  final row = find.byKey(
    const ValueKey('delete_session_${ThemeScreenFixture.session}'),
  );
  final panel = find.byType(SupportSessionsPanel);
  expect(panel, findsOneWidget);
  expect(row.hitTestable(), findsOneWidget);
  await f.gesture(tester, () => tester.tap(row));
  await routeEndpoint(tester, find.byType(SupportThemeDeleteSheet));
}

Future<void> _decide(
  WidgetTester tester,
  ThemeScreenFixture f, {
  required bool confirmed,
}) async {
  final route = ModalRoute.of<bool>(
    tester.element(find.byType(SupportThemeDeleteSheet)),
  )!;
  final popped = await f.signal(
    tester,
    () => route.popped,
    label: 'original native session deletion decision',
    observation: ThemeScreenCheckpoint.decisionSignal,
  );
  f.observe(
    ThemeScreenCheckpoint.decisionGesture,
    ThemeScreenObservationPhase.before,
  );
  await tapSheet(
    tester,
    f,
    confirmed ? 'support_theme_delete_confirm' : 'support_theme_delete_cancel',
    list: 'support_theme_delete_scroll',
  );
  f.observe(
    ThemeScreenCheckpoint.decisionGesture,
    ThemeScreenObservationPhase.after,
  );
  f.observe(
    ThemeScreenCheckpoint.decisionFinish,
    ThemeScreenObservationPhase.before,
  );
  final decision = await f.finish(tester, popped);
  f.observe(
    ThemeScreenCheckpoint.decisionFinish,
    ThemeScreenObservationPhase.after,
  );
  f.observe(
    ThemeScreenCheckpoint.decisionResult,
    ThemeScreenObservationPhase.value,
    value: decision,
  );
  expect(decision, confirmed);
}

void main() {
  for (final status in [
    'pending',
    'undo_pending',
    'reconciliation_required',
    'unknown',
  ]) {
    testWidgets(
      'actual protected deletion $status returns false, keeps cache/history and no retry',
      (tester) async {
        tester.view.physicalSize = const Size(390, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final f = ThemeScreenFixture(observeDeletion: status == 'pending');
        await f.run(tester, () async {
          await f.action(tester, () => f.seedHistory(status: status));
          final baseline = await f.action(tester, f.baseline);
          final ids = f.state.sessions.map((s) => s.id).toList();
          await _openDeletion(tester, f);
          expect(find.text('support_theme_delete_notice'), findsOneWidget);
          final originalWorkspace = f.workspace;
          if (f.observeDeletion) {
            f.observe(
              ThemeScreenCheckpoint.workspaceIdentityBeforeDecision,
              ThemeScreenObservationPhase.value,
              value: identical(f.workspace, originalWorkspace),
            );
          }
          await _decide(tester, f, confirmed: true);
          if (f.observeDeletion) {
            f.observe(
              ThemeScreenCheckpoint.workspaceIdentityBeforeJoin,
              ThemeScreenObservationPhase.value,
              value: identical(f.workspace, originalWorkspace),
            );
            f.observe(
              ThemeScreenCheckpoint.deleteBlockedRendered,
              ThemeScreenObservationPhase.before,
              value: find
                  .text('support_theme_delete_blocked')
                  .evaluate()
                  .isNotEmpty,
            );
          }
          final joined = await f.signal(
            tester,
            originalWorkspace.refresh,
            label: 'original protected delete + display FIFO join',
            observation: ThemeScreenCheckpoint.workspaceRefreshSignal,
          );
          f.observe(
            ThemeScreenCheckpoint.workspaceRefreshFinish,
            ThemeScreenObservationPhase.before,
          );
          final refreshed = await f.finish(tester, joined);
          f.observe(
            ThemeScreenCheckpoint.workspaceRefreshFinish,
            ThemeScreenObservationPhase.after,
          );
          f.observe(
            ThemeScreenCheckpoint.workspaceRefreshResult,
            ThemeScreenObservationPhase.value,
            value: refreshed,
          );
          if (f.observeDeletion) {
            f.observe(
              ThemeScreenCheckpoint.workspaceIdentityAfterJoin,
              ThemeScreenObservationPhase.value,
              value: identical(f.workspace, originalWorkspace),
            );
          }
          f.observe(
            ThemeScreenCheckpoint.postDeleteSettle,
            ThemeScreenObservationPhase.before,
          );
          await tester.pumpAndSettle();
          f.observe(
            ThemeScreenCheckpoint.postDeleteSettle,
            ThemeScreenObservationPhase.after,
          );
          expect(f.state.sessions.map((s) => s.id), ids);
          f.observe(
            ThemeScreenCheckpoint.postDeleteBaseline,
            ThemeScreenObservationPhase.before,
          );
          expect(await f.action(tester, f.baseline), baseline);
          f.observe(
            ThemeScreenCheckpoint.postDeleteBaseline,
            ThemeScreenObservationPhase.after,
          );
          if (f.observeDeletion) {
            f.observe(
              ThemeScreenCheckpoint.deleteBlockedRendered,
              ThemeScreenObservationPhase.after,
              value: find
                  .text('support_theme_delete_blocked')
                  .evaluate()
                  .isNotEmpty,
            );
          }
          expect(find.text('support_theme_delete_blocked'), findsOneWidget);
        });
      },
    );
  }

  for (final cancel in [true, false]) {
    testWidgets(
      'actual settled deletion warning ${cancel ? 'cancel retains callbacks/history' : 'explicit delete loses history/Undo only'}',
      (tester) async {
        tester.view.physicalSize = const Size(390, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final f = ThemeScreenFixture();
        await f.run(tester, () async {
          await f.action(tester, () => f.seedHistory());
          final before = await f.action(tester, f.baseline);
          await _openDeletion(tester, f);
          final retained = tester
              .widget<SupportThemeButton>(
                find.byKey(const ValueKey('support_theme_delete_confirm')),
              )
              .onTap!;
          await _decide(tester, f, confirmed: !cancel);
          await f.action(
            tester,
            retained,
          ); // already decided, never another delete
          final joined = await f.signal(
            tester,
            f.workspace.refresh,
            label: 'original settled delete decision FIFO',
          );
          await f.finish(tester, joined);
          await tester.pumpAndSettle();
          expect(
            f.state.sessions.any((s) => s.id == ThemeScreenFixture.session),
            cancel,
          );
          final rows = await f.action(
            tester,
            () => f.db.select(f.db.supportMutationJournal).get(),
          );
          expect(rows.length, cancel ? 1 : 0);
          if (cancel) expect(await f.action(tester, f.baseline), before);
          expect(f.backing.activeId, 'a');
          expect(f.theme.store.checkedWrites, isEmpty);
        });
      },
    );
  }

  testWidgets(
    'actual session ABA while deletion review open makes retained final decision zero deletion',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final f = ThemeScreenFixture();
      await f.run(tester, () async {
        await _openDeletion(tester, f);
        final retained = tester
            .widget<SupportThemeButton>(
              find.byKey(const ValueKey('support_theme_delete_confirm')),
            )
            .onTap!;
        await f.action(tester, () {
          f.workspace.selectSession(ThemeScreenFixture.other);
          f.workspace.selectSession(ThemeScreenFixture.session);
        });
        final before = await f.action(tester, f.baseline);
        final route = ModalRoute.of<bool>(
          tester.element(find.byType(SupportThemeDeleteSheet)),
        )!;
        final popped = await f.signal(
          tester,
          () => route.popped,
          label: 'original stale deletion decision',
        );
        await f.action(tester, retained);
        expect(await f.finish(tester, popped), isFalse);
        await f.finish(
          tester,
          await f.signal(
            tester,
            f.workspace.refresh,
            label: 'stale decision original FIFO',
          ),
        );
        expect(
          f.state.sessions.any((s) => s.id == ThemeScreenFixture.session),
          isTrue,
        );
        expect(await f.action(tester, f.baseline), before);
      });
    },
  );

  for (final failure in ['reload', 'delivery', 'sql']) {
    testWidgets(
      'actual keyed deletion $failure failure distinguishes done from unknown, never not-removed',
      (tester) async {
        tester.view.physicalSize = const Size(390, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final f = ThemeScreenFixture();
        await f.run(tester, () async {
          final originalWorkspace = f.workspace;
          String? fixedReloadError;
          if (failure == 'reload') {
            var referenceFailures = 0;
            await f.action(tester, () {
              f.sql.event = (event) async {
                if (isBulkSessionReload(event) && referenceFailures == 0) {
                  referenceFailures++;
                  throw StateError(deletionFailureCanary);
                }
              };
            });
            expect(await f.action(tester, originalWorkspace.refresh), isFalse);
            expect(referenceFailures, 1);
            fixedReloadError = f.state.error;
            expect(fixedReloadError, payloadFreeFailure);
            await f.action(tester, () => f.sql.event = null);
            expect(await f.action(tester, originalWorkspace.refresh), isTrue);
            expect(f.state.error, isNull);
          }
          await f.action(tester, () => f.seedHistory());
          final before = await f.action(tester, f.baseline);
          final journal = (await f.action(
            tester,
            () => f.db.select(f.db.supportMutationJournal).get(),
          )).single;
          expect(journal.status, 'applied');
          final sessions = f.state.sessions;
          final messages = f.state.messagesBySession;
          final runtime = f.runtime;
          final lifetime = runtime.lifetime;
          final writes = List.of(f.theme.store.checkedWrites);
          final ordinary = List.of(f.theme.store.ordinaryWrites);
          final savedLists = List.of(f.theme.store.savedLists);
          final presets = List.of(f.backing.presets);
          final vault = Map.of(f.storage.values);
          await _openDeletion(tester, f);
          expect(find.text('support_theme_delete_notice'), findsOneWidget);
          final retained = tester
              .widget<SupportThemeButton>(
                find.byKey(const ValueKey('support_theme_delete_confirm')),
              )
              .onTap!;
          final checkpoint = await f.action(
            tester,
            () => ThemeDeletionPostCommitFailure(
              targetAbsent: () async =>
                  await f.repo.getSessionById(ThemeScreenFixture.session) ==
                  null,
              failCommitDelivery: failure == 'delivery',
            ),
          );
          var sqlFailures = 0;
          await f.action(tester, () {
            f.sql.statements.clear();
            f.db.afterCommit = checkpoint.afterCommit;
            f.sql.event = failure == 'sql'
                ? (event) async {
                    if (event.startsWith(
                          'select:SELECT id FROM support_mutation_journal WHERE session_id = ?',
                        ) &&
                        sqlFailures == 0) {
                      sqlFailures++;
                      throw StateError('SYNTHETIC_SQL_PRIVATE_FAILURE_CANARY');
                    }
                  }
                : checkpoint.sqlEvent;
          });
          final failed = await f.signal(
            tester,
            () => _workspaceFailed(f),
            label: 'original workspace actual $failure terminal state',
          );
          await _decide(tester, f, confirmed: true);
          final workspaceError = await f.finish(tester, failed);
          expect(workspaceError, payloadFreeFailure);
          if (failure == 'reload') expect(workspaceError, fixedReloadError);
          await f.action(
            tester,
            retained,
          ); // consumed native decision, no retry
          await tester.pumpAndSettle();
          expect(find.text('support_theme_delete_blocked'), findsNothing);
          expect(
            find.text('support_theme_delete_done'),
            failure == 'reload' ? findsOneWidget : findsNothing,
          );
          expect(
            find.text('support_theme_delete_unavailable'),
            failure == 'reload' ? findsNothing : findsOneWidget,
          );
          for (final canary in [
            deletionFailureCanary,
            reloadFailureCanary,
            'SYNTHETIC_SQL_PRIVATE_FAILURE_CANARY',
          ]) {
            expect(find.textContaining(canary), findsNothing);
          }
          expect(f.workspace, same(originalWorkspace));
          expect(f.runtime, same(runtime));
          expect(f.runtime.lifetime, lifetime);
          expect(f.state.activeSessionId, ThemeScreenFixture.session);
          expect(f.state.sessions, same(sessions));
          expect(f.state.messagesBySession, same(messages));
          expect(f.state.error, workspaceError);
          expect(f.state.isBusy, isFalse);
          expect(checkpoint.commits, failure == 'sql' ? 0 : 1);
          expect(checkpoint.committed, failure != 'sql');
          expect(checkpoint.reloadQueries, failure == 'reload' ? 1 : 0);
          expect(checkpoint.failures, failure == 'sql' ? 0 : 1);
          expect(sqlFailures, failure == 'sql' ? 1 : 0);
          expect(
            f.sql.statements.where(
              (s) => RegExp(r'^DELETE FROM "?support_sessions"?\b').hasMatch(s),
            ),
            failure == 'sql' ? isEmpty : hasLength(1),
          );
          await f.action(tester, () {
            f.db.afterCommit = null;
            f.sql.event = null;
          });
          expect(
            await f.action(
              tester,
              () => f.repo.getSessionById(ThemeScreenFixture.session),
            ),
            failure == 'sql' ? isNotNull : isNull,
          );
          expect(
            await f.action(
              tester,
              () => f.repo.getSessionById(ThemeScreenFixture.other),
            ),
            isNotNull,
          );
          final durableJournal = await f.action(
            tester,
            () => f.db.select(f.db.supportMutationJournal).get(),
          );
          expect(durableJournal, failure == 'sql' ? [journal] : isEmpty);
          if (failure == 'sql') {
            expect(await f.action(tester, f.baseline), before);
          }
          expect(f.backing.activeId, 'a');
          expect(f.backing.presets, presets);
          expect(f.storage.values, vault);
          expect(f.theme.store.checkedWrites, writes);
          expect(f.theme.store.ordinaryWrites, ordinary);
          expect(f.theme.store.savedLists, savedLists);
        });
      },
    );
  }

  testWidgets(
    'original panel owner retired during committed delete reload cannot paint a late notice',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final f = ThemeScreenFixture();
      await f.run(tester, () async {
        await f.action(tester, () => f.seedHistory());
        final originalWorkspace = f.workspace;
        final runtime = f.runtime;
        final lifetime = runtime.lifetime;
        await _openDeletion(tester, f);
        final gate = await f.action(tester, f.barrier);
        final checkpoint = await f.action(
          tester,
          () => ThemeDeletionPostCommitFailure(
            targetAbsent: () async =>
                await f.repo.getSessionById(ThemeScreenFixture.session) == null,
            reloadGate: gate,
          ),
        );
        await f.action(tester, () {
          f.db.afterCommit = checkpoint.afterCommit;
          f.sql.event = checkpoint.sqlEvent;
        });
        final entered = await f.signal(
          tester,
          () => gate.entered.future,
          label: 'original postcommit bulk reload entry',
        );
        await _decide(tester, f, confirmed: true);
        await f.finish(tester, entered);
        expect(checkpoint.committed, isTrue);
        await f.action(
          tester,
          () => originalWorkspace.selectSession(ThemeScreenFixture.other),
        );
        expect(f.runtime, same(runtime));
        expect(runtime.lifetime, isNot(lifetime));
        final joined = await f.signal(
          tester,
          originalWorkspace.refresh,
          label: 'original delete FIFO then explicit current display read',
        );
        await f.action(tester, () => gate.release.complete());
        expect(await f.finish(tester, joined), isTrue);
        await tester.pumpAndSettle();
        expect(find.text('support_theme_delete_done'), findsNothing);
        expect(find.text('support_theme_delete_blocked'), findsNothing);
        expect(find.text('support_theme_delete_unavailable'), findsNothing);
        expect(checkpoint.commits, 1);
        expect(checkpoint.failures, 1);
        expect(
          checkpoint.reloadQueries,
          3,
          reason:
              'One failed delete reload, selectSession refresh, and ONE explicit FIFO join read.',
        );
        await f.action(tester, () {
          f.db.afterCommit = null;
          f.sql.event = null;
        });
        expect(
          await f.action(
            tester,
            () => f.repo.getSessionById(ThemeScreenFixture.session),
          ),
          isNull,
        );
        expect(
          await f.action(
            tester,
            () => f.repo.getMutationsForSession(ThemeScreenFixture.session),
          ),
          isEmpty,
        );
        expect(f.state.activeSessionId, ThemeScreenFixture.other);
        expect(f.state.error, isNull);
        expect(f.backing.activeId, 'a');
        expect(f.theme.store.checkedWrites, isEmpty);
        expect(f.theme.store.ordinaryWrites, isEmpty);
        expect(f.theme.store.savedLists, isEmpty);
      });
    },
  );
}
