import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/chat_source_mutation_provider.dart';
import 'package:glaze_flutter/core/state/active_selection_provider.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/generating_sessions_provider.dart';
import 'package:glaze_flutter/features/chat/state/agent_ops_jobs_provider.dart';
import 'package:glaze_flutter/features/chat/state/chat_native_owner_registry.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_native_repair_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_ui_bridge.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_composer_bar.dart';

import 'support_app_dormant_repair_fixture.dart';

void main() {
  dormantRepairTest(
    'DORMANT loading real ChatNotifier registration BEFORE Apply retires claim with zero effect',
    (tester, f) async {
      final core = f.screen.core, c = core.container;
      scriptDormantRepair(f);
      await f.start(tester);
      final originalSheet = _originalConfirmation(tester);
      expectStillDormant(f);
      core.isolation.extraAllowed.add(
        chatProvider(DomainLoopFixture.character),
      );
      final gates = await configurationAction(
        tester,
        () => (f.release(), f.release()),
      );
      var blockedRead = false;
      core.native.sql.afterSelect = (statement, _) async {
        if (!blockedRead && statement.contains('chat_sessions')) {
          blockedRead = true;
          gates.$1.complete();
          await gates.$2.future;
        }
      };
      final loading = await configurationAction(
        tester,
        () => (c.read(chatProvider(DomainLoopFixture.character).future),),
      );
      await f.screen.join(tester, gates.$1.future);
      final loadingOwner = c
          .read(chatNativeOwnerRegistryProvider)
          .loaded
          .single;
      expect(loadingOwner.isIdle(), false);
      expect(loadingOwner.sessionId(), null);
      expect(
        c
            .read(chatNativeOwnerRegistryProvider)
            .existing(DomainLoopFixture.session),
        null,
      );
      expect(
        c
            .read(supportAppNativeRepairPortProvider)
            .existingQueue(DomainLoopFixture.session),
        null,
        reason:
            'A loading owner must never be mistaken for an idle dormant queue.',
      );
      await configurationAction(tester, gates.$2.complete);
      await f.screen.join(tester, loading.$1);
      core.native.sql.afterSelect = null;
      await _staleApplyThenCancel(tester, f, originalSheet);
      await _expectNoEffect(tester, f);
    },
  );

  dormantRepairTest(
    'DORMANT admitted ORIGINAL queue fences real competing ChatNotifier initialization until durable settlement',
    (tester, f) async {
      final core = f.screen.core, c = core.container;
      final gates = await configurationAction(
        tester,
        () => (f.release(), f.release()),
      );
      final entered = gates.$1, release = gates.$2;
      expect(c.exists(generatingSessionsProvider), false);
      final originalSession = await configurationAction(
        tester,
        () => c.read(chatRepoProvider).getById(DomainLoopFixture.session),
      );
      scriptDormantRepair(f);
      await f.start(tester);
      final port = c.read(supportAppNativeRepairPortProvider);
      final originalClaim = port.maintenance!.existing(
        DomainLoopFixture.session,
      )!;
      final originalQueue = originalClaim.queue;
      core.native.sql.afterWrite = (statement) async {
        if (!entered.isCompleted &&
            statement.toLowerCase().contains('tracker_rows')) {
          entered.complete();
          await release
              .future; // ACTUAL provisional native effect, not a fake queue.
        }
      };
      await f.apply(tester);
      await f.screen.join(tester, entered.future);
      expect(originalClaim.admitted, true);
      expect(originalClaim.current, true);
      expect(c.exists(generatingSessionsProvider), false);
      final sources = c.read(chatSourceMutationRegistryProvider);
      final admittedCheckpoint = sources.sessionCheckpoint(
        DomainLoopFixture.session,
      );
      expect(sources.isSessionPending(DomainLoopFixture.session), true);
      var liveReadStarted = false, loaded = false, readBeforeSettlement = false;
      var catalogReadStarted = false;
      core.native.sql.afterSelect = (statement, args) async {
        // Hydration's getById, not the maintenance owner's projected CAS reads.
        if (_isExactRowRead(
          statement,
          args,
          table: 'chat_sessions',
          column: 'session_id',
          id: DomainLoopFixture.session,
        )) {
          liveReadStarted = true;
          readBeforeSettlement = readBeforeSettlement || originalClaim.admitted;
        }
        if (_isExactRowRead(
          statement,
          args,
          table: 'chat_sessions',
          column: 'character_id',
          id: DomainLoopFixture.character,
        )) {
          catalogReadStarted = true;
          readBeforeSettlement = readBeforeSettlement || originalClaim.admitted;
        }
      };
      core.isolation.extraAllowed.add(
        chatProvider(DomainLoopFixture.character),
      );
      final loading = await configurationAction(
        tester,
        () => (
          c.read(chatProvider(DomainLoopFixture.character).future).then((
            state,
          ) {
            loaded = true;
            return state;
          }),
        ),
      );
      expect(c.read(chatNativeOwnerRegistryProvider).loaded, hasLength(1));
      final loadingOwner = c
          .read(chatNativeOwnerRegistryProvider)
          .loaded
          .single;
      final calls = await configurationAction(tester, () {
        final notifier = c.read(
          chatProvider(DomainLoopFixture.character).notifier,
        );
        return (
          notifier,
          _ObservedSessionCall(notifier.getSessions()),
          _ObservedSessionCall(notifier.switchSession(0)),
          _ObservedSessionCall(notifier.branchSession(-1)),
        );
      });
      expect(loadingOwner.isIdle(), false);
      expect(loadingOwner.sessionId(), null);
      expect(liveReadStarted, false);
      expect(loaded, false);
      expect(catalogReadStarted, false);
      _expectSessionCallPending(calls.$2);
      _expectSessionCallPending(calls.$3);
      _expectSessionCallPending(calls.$4);
      await tester.pump();
      await configurationAction(tester, () => c.pump());
      expect(c.exists(generatingSessionsProvider), false);
      expect(originalClaim.current, true);
      expect(originalClaim.admitted, true);
      expect(
        identical(port.existingQueue(DomainLoopFixture.session), originalQueue),
        true,
      );
      expect(
        identical(
          sources.sessionCheckpoint(DomainLoopFixture.session),
          admittedCheckpoint,
        ),
        true,
      );
      expect(liveReadStarted, false);
      expect(loaded, false);
      expect(catalogReadStarted, false);
      _expectSessionCallPending(calls.$2);
      _expectSessionCallPending(calls.$3);
      _expectSessionCallPending(calls.$4);
      await configurationAction(tester, release.complete);
      final reply = await f.finish(tester);
      final live = await f.screen.join(tester, loading.$1);
      final catalog = await f.screen.join(tester, calls.$2.original);
      await f.screen.join(tester, calls.$3.original);
      expect(await f.screen.join(tester, calls.$4.original) == null, true);
      core.native.sql.afterSelect = null;
      core.native.sql.afterWrite = null;
      expect(live.session!.id, DomainLoopFixture.session);
      expect(loaded, true);
      expect(liveReadStarted, true);
      expect(catalogReadStarted, true);
      expect(catalog.length, 1);
      expect(catalog.single.id == DomainLoopFixture.session, true);
      expect(
        identical(
          c.read(chatProvider(DomainLoopFixture.character).notifier),
          calls.$1,
        ),
        true,
      );
      expect(readBeforeSettlement, false);
      expect(originalClaim.admitted, false);
      expect(originalClaim.current, false);
      expect(sources.isSessionPending(DomainLoopFixture.session), false);
      expect(port.maintenance!.existing(DomainLoopFixture.session), null);
      expect(
        identical(
          c
              .read(chatNativeOwnerRegistryProvider)
              .existing(DomainLoopFixture.session),
          loadingOwner,
        ),
        true,
      );
      expect(loadingOwner.isIdle(), true);
      expect(c.exists(generatingSessionsProvider), true);
      expect(c.read(generatingSessionsProvider).isEmpty, true);
      expect(reply.body, contains('изменение сохранено'));
      expect(core.wire, hasLength(3));
      final journal = await configurationAction(
        tester,
        () =>
            core.native.db.select(core.native.db.supportMutationJournal).get(),
      );
      expect(journal.length, 1);
      expect(journal.single.status, 'applied');
      expect(journal.single.sessionId == core.native.session, true);
      expect(journal.single.beforeCiphertext.isNotEmpty, true);
      expect(journal.single.afterCiphertext.isNotEmpty, true);
      final rows = await configurationAction(
        tester,
        () => core.native.db.select(core.native.db.trackerRows).get(),
      );
      expect(
        rows.where((r) => r.value == 'Supplied dormant correction'),
        hasLength(1),
      );
      expect(rows.where((r) => r.value == DomainLoopFixture.private).length, 1);
      expect(rows.singleWhere((r) => r.scope == 'system').value, '1');
      expect(
        jsonEncode(live.session!.messages.map((m) => m.toJson()).toList()) ==
            jsonEncode(
              originalSession!.messages.map((m) => m.toJson()).toList(),
            ),
        true,
      );
      f.noEgress(reply.body);
    },
  );

  for (final api in ['createNewSession', 'newSession']) {
    dormantRepairTest(
      'DORMANT $api waits SAME live initializer behind admitted maintenance before actual session creation',
      (tester, f) => _heldSessionApi(tester, f, api),
    );
  }
  for (final mode in ['retired', 'readFailure']) {
    dormantRepairTest(
      'DORMANT getSessions ORIGINAL initializer $mode settles without replacement catalog access',
      (tester, f) => _heldSessionApi(tester, f, mode),
    );
  }

  dormantRepairTest(
    'DORMANT queued native effect retains durable fact after original route retirement without replacement paint or POST',
    (tester, f) async {
      final core = f.screen.core;
      final gates = await configurationAction(
        tester,
        () => (f.release(), f.release()),
      );
      scriptDormantRepair(f);
      await f.start(tester);
      core.native.sql.afterWrite = (statement) async {
        if (!gates.$1.isCompleted &&
            statement.toLowerCase().contains('tracker_rows')) {
          gates.$1.complete();
          await gates.$2.future;
        }
      };
      await f.apply(tester);
      await f.screen.join(tester, gates.$1.future);
      await configurationAction(
        tester,
        () => f.screen.router.go('/characters'),
      );
      await tester.pump();
      await configurationAction(tester, gates.$2.complete);
      final reply = await f.finish(tester);
      expect(reply.status, 'stopped');
      expect(reply.body, contains('изменение сохранено'));
      expect(find.textContaining('изменение сохранено'), findsNothing);
      expect(core.wire, hasLength(3));
      expectStillDormant(f);
      f.noEgress(reply.body);
    },
  );

  dormantRepairTest(
    'DORMANT native reconciliation lease added after final preview denies effect',
    (tester, f) async {
      final core = f.screen.core, c = core.container;
      core.isolation.extraAllowed.add(ledgerReconciliationLeaseRepoProvider);
      scriptDormantRepair(f);
      await f.start(tester);
      await configurationAction(tester, () async {
        expect(
          await c
              .read(ledgerReconciliationLeaseRepoProvider)
              .acquire(
                sessionId: DomainLoopFixture.session,
                ownerId: 'native-competing-ledger',
                purpose: 'manual',
                ttlSeconds: 60,
              ),
          true,
        );
      });
      await f.apply(tester);
      await _expectNoEffect(tester, f);
      expectStillDormant(f);
    },
  );

  dormantRepairTest(
    'DORMANT actual Collector job claim after final preview denies selected delete',
    (tester, f) async {
      final c = f.screen.core.container;
      await configurationAction(tester, () => seedDomainCollector(f));
      scriptDormantRepair(f, collector: true);
      await f.start(tester);
      await configurationAction(tester, () async {
        expect(
          (await c
                  .read(cardEvolutionCollectorRunRepoProvider)
                  .claimFailed(
                    id: 'domain-failed-collector',
                    ownerId: 'competing-native-owner',
                    now: 20,
                    leaseSeconds: 60,
                  ))
              .canRun,
          true,
        );
      });
      await f.apply(tester);
      await _expectNoEffect(tester, f);
      expect(
        (await configurationAction(
          tester,
          () => c
              .read(cardEvolutionCollectorRunRepoProvider)
              .getById('domain-failed-collector'),
        ))!.status,
        'claimed',
      );
      expectStillDormant(f);
    },
  );

  dormantRepairTest(
    'DORMANT real canonical head append after final preview denies old original CAS',
    (tester, f) async {
      scriptDormantRepair(f);
      await f.start(tester);
      await configurationAction(tester, () => seedDomainCollector(f));
      final head = await configurationAction(
        tester,
        () => f.screen.core.container
            .read(ledgerReconciliationRunRepoProvider)
            .readSession(DomainLoopFixture.session),
      );
      expect(
        head,
        hasLength(3),
      ); // Real append/effect contracts; no trigger bypass.
      await f.apply(tester);
      await _expectNoEffect(tester, f);
      expectStillDormant(f);
    },
  );

  dormantRepairTest(
    'DORMANT native manual revision advance after preview denies old plan without reverting revision',
    (tester, f) async {
      final c = f.screen.core.container;
      scriptDormantRepair(f);
      await f.start(tester);
      await configurationAction(
        tester,
        () => f.screen.core.native.db.transaction(
          () => c
              .read(trackerRepoProvider)
              .bumpLedgerManualMutationRevision(DomainLoopFixture.session),
        ),
      );
      await f.apply(tester);
      await _expectNoEffect(tester, f);
      expect(
        await configurationAction(
          tester,
          () => c
              .read(trackerRepoProvider)
              .getLedgerManualMutationRevision(DomainLoopFixture.session),
        ),
        1,
      );
      expectStillDormant(f);
    },
  );

  dormantRepairTest(
    'DORMANT malformed actual owner metadata after preview never defaults to idle',
    (tester, f) async {
      final db = f.screen.core.native.db;
      await configurationAction(tester, () => seedDomainCollector(f));
      scriptDormantRepair(f, collector: true);
      await f.start(tester);
      await configurationAction(
        tester,
        () =>
            (db.update(
              db.cardEvolutionCollectorRuns,
            )..where((row) => row.id.equals('domain-failed-collector'))).write(
              const CardEvolutionCollectorRunsCompanion(
                ownerId: Value('invalid owner'),
              ),
            ),
      );
      await f.apply(tester);
      await _expectNoEffect(tester, f);
      final retained = await configurationAction(
        tester,
        () => db.select(db.cardEvolutionCollectorRuns).get(),
      );
      expect(retained.length, 1);
      expect(retained.single.ownerId == 'invalid owner', true);
      expect(retained.single.status, 'failed');
      expectStillDormant(f);
    },
  );

  dormantRepairTest(
    'DORMANT unknown active native job inventory alone denies admission',
    (tester, f) async {
      final core = f.screen.core, c = core.container;
      scriptDormantRepair(f);
      await f.start(tester);
      final originalSheet = _originalConfirmation(tester);
      core.isolation.extraAllowed.add(agentOpsJobsProvider);
      await configurationAction(tester, () {
        expect(
          c.read(agentOpsJobsProvider.notifier).start('unknown-native-job'),
          true,
        );
      });
      expect(c.read(agentOpsJobsProvider).contains('unknown-native-job'), true);
      await _staleApplyThenCancel(tester, f, originalSheet);
      await _expectNoEffect(tester, f);
      expect(c.read(agentOpsJobsProvider).contains('unknown-native-job'), true);
      expectStillDormant(f);
    },
  );

  dormantRepairTest(
    'DORMANT real source begin before effect alone denies admission',
    (tester, f) async {
      final c = f.screen.core.container;
      scriptDormantRepair(f);
      await f.start(tester);
      final originalSheet = _originalConfirmation(tester);
      final sources = c.read(chatSourceMutationRegistryProvider);
      final originalCheckpoint = sources.sessionCheckpoint(
        DomainLoopFixture.session,
      );
      final settle = await configurationAction(
        tester,
        () => sources.beginMutation(sessionId: DomainLoopFixture.session),
      );
      try {
        expect(sources.isSessionPending(DomainLoopFixture.session), true);
        expect(
          identical(
            sources.sessionCheckpoint(DomainLoopFixture.session),
            originalCheckpoint,
          ),
          false,
        );
        await _staleApplyThenCancel(tester, f, originalSheet);
        await _expectNoEffect(tester, f);
      } finally {
        await configurationAction(tester, settle);
      }
      expect(sources.isSessionPending(DomainLoopFixture.session), false);
      expect(
        identical(
          sources.sessionCheckpoint(DomainLoopFixture.session),
          originalCheckpoint,
        ),
        false,
      );
      expectStillDormant(f);
    },
  );

  dormantRepairTest(
    'DORMANT exact native Cancel releases preparation owner without effect or body read',
    (tester, f) async {
      scriptDormantRepair(f);
      await f.start(tester);
      await f.cancel(tester);
      await _expectNoEffect(tester, f);
      expect(
        f.screen.core.container
            .read(supportAppNativeRepairPortProvider)
            .existingQueue(DomainLoopFixture.session),
        null,
      );
      expectStillDormant(f);
    },
  );

  dormantRepairTest(
    'DORMANT composer Stop at actual original ROOT never consumes maintenance effect',
    (tester, f) async {
      final core = f.screen.core;
      scriptDormantRepair(f);
      await f.start(tester);
      final originalSheet = _originalConfirmation(tester);
      final originalComposer = find.byType(
        SupportComposerBar,
        skipOffstage: false,
      );
      expect(originalComposer, findsOneWidget);
      final composer = tester.widget<SupportComposerBar>(originalComposer);
      expect(composer.sessionId == core.native.session, true);
      expect(composer.busy, true);
      expect(composer.nativeOwner, isA<SupportModelUiEmitter>());
      expect((composer.nativeOwner! as SupportModelUiEmitter).isCurrent, true);
      final stopButton = find.descendant(
        of: originalComposer,
        matching: find.byKey(
          const ValueKey('support_composer_stop_btn'),
          skipOffstage: false,
        ),
        skipOffstage: false,
      );
      expect(stopButton, findsOneWidget);
      expect(tester.element(stopButton).mounted, true);
      final originalRoute = ModalRoute.of<void>(
        tester.element(originalComposer),
      )!;
      expect(originalRoute.isActive, true);
      expect(originalRoute.navigator, same(originalSheet.navigator));
      final stop = tester.widget<IconButton>(stopButton).onPressed;
      expect(stop, isNotNull);
      // The original screen binds composer.onStop directly to activeSend.stop.
      // Keep that exact callback; never use a sheet Cancel or replacement send.
      expect(identical(stop, composer.onStop), true);
      final originalRun = core.bridge.view.runId;
      expect(originalRun != null, true);
      final messages = await configurationAction(
        tester,
        () => (core.native.db.select(
          core.native.db.supportMessages,
        )..where((row) => row.sessionId.equals(core.native.session))).get(),
      );
      final users = messages
          .where((row) => row.runId == originalRun && row.role == 'user')
          .toList();
      final replies = messages
          .where((row) => row.runId == originalRun && row.role == 'assistant')
          .toList();
      expect(users.length, 1);
      expect(replies.length, 1);
      final userId = users.single.id, replyId = replies.single.id;
      var terminalRootEntered = false,
          originalUserRead = false,
          stopped = false;
      core.native.sql.afterSelect = (statement, args) async {
        if (statement.trim() == 'PRAGMA busy_timeout') {
          terminalRootEntered = true;
        }
        if (!terminalRootEntered || stopped) return;
        if (_isExactRowRead(
          statement,
          args,
          table: 'support_messages',
          column: 'id',
          id: userId,
        )) {
          originalUserRead = true;
        }
        if (originalUserRead &&
            _isExactRowRead(
              statement,
              args,
              table: 'support_messages',
              column: 'id',
              id: replyId,
            )) {
          stopped = true;
          stop!(); // Actual original ROOT, before capsule/maintenance consumption.
        }
      };
      await f.apply(tester);
      await _expectNoEffect(tester, f);
      core.native.sql.afterSelect = null;
      expect(terminalRootEntered, true);
      expect(originalUserRead, true);
      expect(stopped, true);
      expect(f.reply!.status, 'stopped');
      expect(core.wire, hasLength(3));
      expectStillDormant(f);
    },
  );
}

/// Observe the exact original API future immediately; joining later never loses
/// an error to the zone or replaces its value/stack with a fabricated result.
final class _ObservedSessionCall<T> {
  _ObservedSessionCall(this.original) {
    unawaited(
      original.then<void>(
        (_) {
          settled = true;
        },
        onError: (Object error, StackTrace trace) {
          failure = error;
          stack = trace;
          settled = true;
        },
      ),
    );
  }
  final Future<T> original;
  bool settled = false;
  Object? failure;
  StackTrace? stack;
}

void _expectSessionCallPending<T>(_ObservedSessionCall<T> call) {
  expect(call.failure == null, true);
  expect(call.settled, false);
}

Future<void> _heldSessionApi(
  WidgetTester tester,
  DomainLoopFixture f,
  String mode,
) async {
  final core = f.screen.core, c = core.container, db = core.native.db;
  final gates = await configurationAction(
    tester,
    () => (f.release(), f.release()),
  );
  scriptDormantRepair(f);
  await f.start(tester);
  final port = c.read(supportAppNativeRepairPortProvider);
  final claim = port.maintenance!.existing(DomainLoopFixture.session)!;
  final queue = claim.queue;
  var earlyCreation = false;
  // insertReturningOrNull executes through runSelect, not afterWrite. Count
  // its actual returned new-session rows, never attempted writes or a set flag.
  int created() => core.native.sql.observations
      .where((entry) => _isSessionInsertReturning(entry.statement))
      .fold<int>(
        0,
        (count, entry) =>
            count +
            entry.rows
                .where(
                  (row) =>
                      row['session_id'] == '${DomainLoopFixture.character}_1' &&
                      row['character_id'] == DomainLoopFixture.character &&
                      row['session_index'] == 1,
                )
                .length,
      );
  core.native.sql.afterWrite = (statement) async {
    if (!gates.$1.isCompleted &&
        statement.toLowerCase().contains('tracker_rows')) {
      gates.$1.complete();
      await gates.$2.future;
    }
    if (statement.trimLeft().toLowerCase().startsWith('insert') &&
        statement.contains('chat_sessions')) {
      earlyCreation = earlyCreation || claim.admitted;
    }
  };
  await f.apply(tester);
  await f.screen.join(tester, gates.$1.future);
  final mutations = c.read(chatSourceMutationRegistryProvider);
  final checkpoint = mutations.sessionCheckpoint(DomainLoopFixture.session);
  final writesBeforeCall = core.native.sql.writes.length;
  var catalogReads = 0, hydrationReads = 0, earlyRead = false;
  final syntheticFailure = StateError(
    'SYNTHETIC_PRIVATE_INITIALIZER_READ_FAILURE',
  );
  core.native.sql.afterSelect = (statement, args) async {
    if (_isSessionInsertReturning(statement)) {
      earlyCreation = earlyCreation || claim.admitted;
    }
    final hydration = _isExactRowRead(
      statement,
      args,
      table: 'chat_sessions',
      column: 'session_id',
      id: DomainLoopFixture.session,
    );
    final catalog = _isExactRowRead(
      statement,
      args,
      table: 'chat_sessions',
      column: 'character_id',
      id: DomainLoopFixture.character,
    );
    if (catalog) catalogReads++;
    if (hydration) hydrationReads++;
    if (catalog || hydration) earlyRead = earlyRead || claim.admitted;
    if (hydration && mode == 'readFailure' && hydrationReads == 1) {
      throw syntheticFailure;
    }
  };
  core.isolation.extraAllowed.add(chatProvider(DomainLoopFixture.character));
  if (mode == 'createNewSession' || mode == 'newSession') {
    // Pure selection holders only; no selection loader or preference hydration.
    core.isolation.extraAllowed.addAll({
      activePersonaIdProvider,
      personaConnectionsProvider,
    });
  }
  final starting = await configurationAction(tester, () {
    final notifier = c.read(chatProvider(DomainLoopFixture.character).notifier);
    final loading = _ObservedSessionCall(
      c.read(chatProvider(DomainLoopFixture.character).future),
    );
    return (notifier, loading);
  });
  final loadingOwner = c.read(chatNativeOwnerRegistryProvider).loaded.single;
  final _ObservedSessionCall<void>? creation;
  final _ObservedSessionCall<List<ChatSession>>? catalog;
  if (mode == 'createNewSession' || mode == 'newSession') {
    creation = await configurationAction(
      tester,
      () => _ObservedSessionCall(
        mode == 'createNewSession'
            ? starting.$1.createNewSession()
            : starting.$1.newSession(),
      ),
    );
    catalog = null;
  } else {
    creation = null;
    catalog = await configurationAction(
      tester,
      () => _ObservedSessionCall(starting.$1.getSessions()),
    );
  }
  final cancelledChanges = <_ObservedSessionCall<void>>[];
  if (mode == 'retired') {
    await configurationAction(tester, () {
      cancelledChanges.addAll([
        _ObservedSessionCall(starting.$1.createNewSession()),
        _ObservedSessionCall(starting.$1.newSession()),
        _ObservedSessionCall(starting.$1.switchSession(0)),
      ]);
    });
  }
  await tester.pump();
  await configurationAction(tester, () => c.pump());
  expect(creation?.failure == null, true);
  expect(catalog?.failure == null, true);
  expect(creation?.settled ?? catalog!.settled, false);
  for (final call in cancelledChanges) {
    _expectSessionCallPending(call);
  }
  expect(starting.$2.settled, false);
  expect(catalogReads, 0);
  expect(hydrationReads, 0);
  expect(created(), 0);
  expect(core.native.sql.writes.length, writesBeforeCall);
  expect(c.exists(generatingSessionsProvider), false);
  expect(claim.current, true);
  expect(claim.admitted, true);
  expect(identical(port.existingQueue(DomainLoopFixture.session), queue), true);
  expect(
    identical(
      mutations.sessionCheckpoint(DomainLoopFixture.session),
      checkpoint,
    ),
    true,
  );
  expect(mutations.isSessionPending(DomainLoopFixture.session), true);
  expect(loadingOwner.isIdle(), false);
  expect(loadingOwner.sessionId(), null);

  _ObservedSessionCall<ChatState>? replacement;
  if (mode == 'retired') {
    await configurationAction(
      tester,
      () => c.invalidate(chatProvider(DomainLoopFixture.character)),
    );
    // Retirement must resolve the ORIGINAL API caller before the native effect
    // is released. It may not wait for, or silently query, a replacement build.
    Object? refusal;
    try {
      await f.screen.join(tester, catalog!.original);
    } catch (error) {
      refusal = error;
    }
    expect(refusal is StateError, true);
    expect(catalog!.settled, true);
    expect(catalog.stack != null, true);
    for (final call in cancelledChanges) {
      await f.screen.join(tester, call.original);
      expect(call.failure == null, true);
      expect(call.settled, true);
    }
    expect(catalogReads, 0);
    expect(hydrationReads, 0);
    expect(created(), 0);
    expect(core.native.sql.writes.length, writesBeforeCall);
    replacement = await configurationAction(
      tester,
      () => _ObservedSessionCall(
        c.read(chatProvider(DomainLoopFixture.character).future),
      ),
    );
    expect(replacement!.settled, false);
    expect(c.exists(generatingSessionsProvider), false);
    expect(claim.current, true);
    expect(claim.admitted, true);
  }

  await configurationAction(tester, gates.$2.complete);
  final reply = await f.finish(tester);
  if (mode == 'readFailure') {
    for (final call in [starting.$2, catalog!]) {
      Object? failure;
      try {
        await f.screen.join(tester, call.original);
      } catch (error) {
        failure = error;
      }
      expect(identical(failure, syntheticFailure), true);
      expect(identical(call.failure, syntheticFailure), true);
      expect(call.stack != null, true);
    }
    expect(hydrationReads, greaterThanOrEqualTo(1));
    expect(catalogReads, 0);
  } else if (replacement != null) {
    final state = await f.screen.join(tester, replacement.original);
    expect(state.session!.id == DomainLoopFixture.session, true);
    expect(catalogReads, 0);
    final currentOwner = c
        .read(chatNativeOwnerRegistryProvider)
        .existing(DomainLoopFixture.session);
    expect(currentOwner != null, true);
    expect(identical(currentOwner, loadingOwner), false);
  } else {
    final initial = await f.screen.join(tester, starting.$2.original);
    expect(initial.session!.id == DomainLoopFixture.session, true);
    await f.screen.join(tester, creation!.original);
    expect(creation.failure == null, true);
    final persisted = await configurationAction(
      tester,
      () =>
          c.read(chatRepoProvider).getById('${DomainLoopFixture.character}_1'),
    );
    expect(persisted != null, true);
    final durable = persisted!;
    expect(durable.id == '${DomainLoopFixture.character}_1', true);
    expect(durable.characterId == DomainLoopFixture.character, true);
    expect(durable.sessionIndex, 1);
    final sessions = await configurationAction(tester, starting.$1.getSessions);
    expect(sessions.length, 2);
    expect(
      sessions.where((row) => row.id == DomainLoopFixture.session).length,
      1,
    );
    expect(
      sessions
          .where(
            (row) =>
                row.id == '${DomainLoopFixture.character}_1' &&
                row.characterId == DomainLoopFixture.character &&
                row.sessionIndex == 1,
          )
          .length,
      1,
    );
    expect(
      c
          .read(chatProvider(DomainLoopFixture.character))
          .value!
          .session!
          .sessionIndex,
      1,
    );
    expect(
      c.read(chatProvider(DomainLoopFixture.character)).value!.session!.id ==
          '${DomainLoopFixture.character}_1',
      true,
    );
    expect(
      identical(
        c.read(chatProvider(DomainLoopFixture.character).notifier),
        starting.$1,
      ),
      true,
    );
    expect(
      identical(
        c
            .read(chatNativeOwnerRegistryProvider)
            .existing('${DomainLoopFixture.character}_1'),
        loadingOwner,
      ),
      true,
    );
    expect(created(), 1);
  }
  core.native.sql.afterSelect = null;
  core.native.sql.afterWrite = null;
  expect(earlyRead, false);
  expect(earlyCreation, false);
  expect(claim.current, false);
  expect(claim.admitted, false);
  expect(port.maintenance!.existing(DomainLoopFixture.session), null);
  expect(mutations.isSessionPending(DomainLoopFixture.session), false);
  expect(reply.body, contains('изменение сохранено'));
  expect(core.wire, hasLength(3));
  final journal = await configurationAction(
    tester,
    () => db.select(db.supportMutationJournal).get(),
  );
  expect(journal.length, 1);
  expect(journal.single.status, 'applied');
  expect(journal.single.sessionId == core.native.session, true);
  expect(journal.single.beforeCiphertext.isNotEmpty, true);
  expect(journal.single.afterCiphertext.isNotEmpty, true);
  final rows = await configurationAction(
    tester,
    () => db.select(db.trackerRows).get(),
  );
  expect(
    rows.where((row) => row.value == 'Supplied dormant correction').length,
    1,
  );
  expect(rows.where((row) => row.value == DomainLoopFixture.private).length, 1);
  expect(rows.singleWhere((row) => row.scope == 'system').value, '1');
  expect(
    '${jsonEncode(core.wire)}${reply.body}',
    isNot(contains('SYNTHETIC_PRIVATE_INITIALIZER_READ_FAILURE')),
  );
  f.noEgress(reply.body);
}

bool _isSessionInsertReturning(String statement) {
  final normalized = statement
      .replaceAll('"', '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .toLowerCase();
  return RegExp(
        r'^insert or ignore into chat_sessions\b',
      ).hasMatch(normalized) &&
      RegExp(r'\breturning\b').hasMatch(normalized);
}

ModalBottomSheetRoute<void> _originalConfirmation(WidgetTester tester) {
  final accept = find.byKey(const ValueKey('support_tool_confirmation_accept'));
  expect(accept, findsOneWidget);
  final route = ModalRoute.of<void>(tester.element(accept))!;
  expect(route, isA<ModalBottomSheetRoute<void>>());
  expect(route.isCurrent, true);
  return route as ModalBottomSheetRoute<void>;
}

Future<void> _staleApplyThenCancel(
  WidgetTester tester,
  DomainLoopFixture f,
  ModalBottomSheetRoute<void> originalSheet,
) async {
  final accept = find.byKey(const ValueKey('support_tool_confirmation_accept'));
  expect(accept, findsOneWidget);
  expect(ModalRoute.of<void>(tester.element(accept)), same(originalSheet));
  expect(originalSheet.isCurrent, true);
  final core = f.screen.core;
  int rootEntries() => core.native.sql.observations
      .where((entry) => entry.statement.trim() == 'PRAGMA busy_timeout')
      .length;
  final rootsBeforeApply = rootEntries();
  await configurationAction(tester, () => tester.tap(accept));
  await tester.pump();
  expect(
    originalSheet.isCurrent,
    true,
    reason: 'Stale Apply is a no-op, not a pop.',
  );
  expect(ModalRoute.of<void>(tester.element(accept)), same(originalSheet));
  expect(rootEntries(), rootsBeforeApply);
  expect(core.wire, hasLength(3));
  final journal = await configurationAction(
    tester,
    () => core.native.db.select(core.native.db.supportMutationJournal).get(),
  );
  expect(journal.isEmpty, true);
  final rows = await configurationAction(
    tester,
    () => core.native.db.select(core.native.db.trackerRows).get(),
  );
  expect(rows.where((row) => row.scope == 'ledger').length, 2);
  expect(
    rows
        .where((row) => row.scope == 'ledger')
        .every((row) => row.value == DomainLoopFixture.private),
    true,
  );
  final cancel = find.byKey(const ValueKey('support_tool_confirmation_cancel'));
  expect(cancel, findsOneWidget);
  expect(ModalRoute.of<void>(tester.element(cancel)), same(originalSheet));
  await f.cancel(
    tester,
  ); // Native Cancel on this SAME unresolved original sheet.
  expect(originalSheet.isCurrent, false);
}

bool _isExactRowRead(
  String statement,
  List<Object?> args, {
  required String table,
  required String column,
  required String id,
}) {
  final normalized = statement
      .replaceAll('"', '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .toLowerCase();
  final expected = 'select * from $table where $column = ?';
  return args.length == 1 &&
      args.single == id &&
      (normalized == expected || normalized == '$expected;');
}

Future<void> _expectNoEffect(WidgetTester tester, DomainLoopFixture f) async {
  final core = f.screen.core;
  final reply = await f.finish(tester);
  expect(reply.body, isNot(contains('изменение сохранено')));
  expect(
    await configurationAction(
      tester,
      () => core.native.db.select(core.native.db.supportMutationJournal).get(),
    ),
    isEmpty,
  );
  final rows = await configurationAction(
    tester,
    () => core.native.db.select(core.native.db.trackerRows).get(),
  );
  expect(rows.where((r) => r.value == 'Supplied dormant correction'), isEmpty);
  expect(core.wire.length, lessThanOrEqualTo(4));
  f.noEgress(reply.body);
}
