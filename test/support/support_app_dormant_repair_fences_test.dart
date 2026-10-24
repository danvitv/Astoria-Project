import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/chat_source_mutation_provider.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/state/agent_ops_jobs_provider.dart';
import 'package:glaze_flutter/features/chat/state/chat_native_owner_registry.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_native_repair_provider.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';

import 'support_app_dormant_repair_fixture.dart';

void main() {
  dormantRepairTest(
    'DORMANT loading real ChatNotifier registration BEFORE Apply retires claim with zero effect',
    (tester, f) async {
      final core = f.screen.core, c = core.container;
      scriptDormantRepair(f);
      await f.start(tester);
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
      await f.apply(tester);
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
      scriptDormantRepair(f);
      await f.start(tester);
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
      var liveReadStarted = false, loaded = false;
      core.native.sql.afterSelect = (statement, _) async {
        if (statement.contains('chat_sessions')) liveReadStarted = true;
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
      expect(liveReadStarted, false);
      expect(loaded, false);
      await configurationAction(tester, release.complete);
      final reply = await f.finish(tester);
      final live = await f.screen.join(tester, loading.$1);
      core.native.sql.afterSelect = null;
      core.native.sql.afterWrite = null;
      expect(live.session!.id, DomainLoopFixture.session);
      expect(loaded, true);
      expect(reply.body, contains('изменение сохранено'));
      expect(core.wire, hasLength(3));
      final rows = await configurationAction(
        tester,
        () => core.native.db.select(core.native.db.trackerRows).get(),
      );
      expect(
        rows.where((r) => r.value == 'Supplied dormant correction'),
        hasLength(1),
      );
      f.noEgress(reply.body);
    },
  );

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
              const CardEvolutionCollectorRunsCompanion(ownerId: Value('')),
            ),
      );
      await f.apply(tester);
      await _expectNoEffect(tester, f);
      expectStillDormant(f);
    },
  );

  dormantRepairTest(
    'DORMANT unknown active native job inventory alone denies admission',
    (tester, f) async {
      final core = f.screen.core, c = core.container;
      scriptDormantRepair(f);
      await f.start(tester);
      core.isolation.extraAllowed.add(agentOpsJobsProvider);
      await configurationAction(tester, () {
        expect(
          c.read(agentOpsJobsProvider.notifier).start('unknown-native-job'),
          true,
        );
      });
      await f.apply(tester);
      await _expectNoEffect(tester, f);
      expectStillDormant(f);
    },
  );

  dormantRepairTest(
    'DORMANT real source begin before effect alone denies admission',
    (tester, f) async {
      final c = f.screen.core.container;
      scriptDormantRepair(f);
      await f.start(tester);
      final settle = await configurationAction(
        tester,
        () => c
            .read(chatSourceMutationRegistryProvider)
            .beginMutation(sessionId: DomainLoopFixture.session),
      );
      try {
        await f.apply(tester);
        await _expectNoEffect(tester, f);
      } finally {
        await configurationAction(tester, settle);
      }
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
      final stop = tester
          .widget<GlazeActionButton>(
            find.byKey(const ValueKey('support_composer_stop_btn')),
          )
          .onTap!;
      var stopped = false;
      core.native.sql.afterSelect = (statement, _) async {
        if (!stopped && statement.contains('support_messages')) {
          stopped = true;
          stop();
        }
      };
      await f.apply(tester);
      await _expectNoEffect(tester, f);
      core.native.sql.afterSelect = null;
      expect(stopped, true);
      expectStillDormant(f);
    },
  );
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
