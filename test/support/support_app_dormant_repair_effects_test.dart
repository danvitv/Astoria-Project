import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/chat_source_mutation_provider.dart';
import 'package:glaze_flutter/core/llm/transport/native_tool_types.dart';
import 'package:glaze_flutter/features/chat/state/chat_native_owner_registry.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_native_repair_provider.dart';

import 'support_app_dormant_repair_fixture.dart';

void main() {
  dormantRepairTest(
    'DORMANT MODEL real Collector selected delete and fresh same-parent Undo without target ChatNotifier',
    (tester, f) => _roundTrip(tester, f, collector: true),
  );
  dormantRepairTest(
    'DORMANT MODEL real Ledger correction revisions originals and fresh same-parent Undo without target ChatNotifier',
    (tester, f) => _roundTrip(tester, f, collector: false),
  );

  dormantRepairTest(
    'DORMANT fresh same-parent Undo preserves a competing latest value and records actual after-CAS conflict',
    (tester, f) async {
      final core = f.screen.core, c = core.container, db = core.native.db;
      scriptDormantRepair(f);
      await f.start(tester);
      await f.apply(tester);
      final applied = await f.finish(tester);
      expect(applied.body, contains('изменение сохранено'));
      await configurationAction(tester, () async {
        final repo = c.read(trackerRepoProvider);
        final target = (await repo.getBySessionId(
          DomainLoopFixture.session,
        )).singleWhere((row) => row.value == 'Supplied dormant correction');
        await repo.upsert(
          target.copyWith(value: 'Competing latest native value'),
        );
      });
      scriptDormantUndo(f);
      await f.start(tester);
      await f.apply(tester);
      final undone = await f.finish(tester);
      final rows = await configurationAction(
        tester,
        () => db.select(db.trackerRows).get(),
      );
      expect(
        rows.where((row) => row.value == 'Competing latest native value'),
        hasLength(1),
      );
      expect(rows.singleWhere((row) => row.scope == 'system').value, '1');
      expect(
        (await configurationAction(
          tester,
          () => db.select(db.supportMutationJournal).get(),
        )).single.status,
        'undo_conflict',
      );
      expect(core.wire, hasLength(5));
      expectStillDormant(f);
      f.noEgress('${applied.body}${undone.body}');
    },
  );

  domainLoopTest(
    'NEW representative loaded repair retains SAME genuine original queue',
    (tester, f) async {
      final core = f.screen.core, c = core.container;
      final original = c
          .read(chatNativeOwnerRegistryProvider)
          .existing(DomainLoopFixture.session)!;
      await configurationAction(tester, () => seedDomainCollector(f));
      scriptDormantRepair(f, collector: true);
      await f.start(tester);
      await f.apply(tester);
      final reply = await f.finish(tester);
      expect(reply.body, contains('изменение сохранено'));
      expect(
        identical(
          original.queue,
          c
              .read(chatNativeOwnerRegistryProvider)
              .existing(DomainLoopFixture.session)!
              .queue,
        ),
        true,
      );
      expect(
        await configurationAction(
          tester,
          () => core.native.db
              .select(core.native.db.cardEvolutionCollectorRuns)
              .get(),
        ),
        isEmpty,
      );
      expect(core.wire, hasLength(3));
      f.noEgress(reply.body);
    },
  );
}

Future<void> _roundTrip(
  WidgetTester tester,
  DomainLoopFixture f, {
  required bool collector,
}) async {
  final core = f.screen.core, c = core.container, db = core.native.db;
  if (collector)
    await configurationAction(tester, () => seedDomainCollector(f));
  final original = await configurationAction(
    tester,
    () => c.read(chatRepoProvider).getById(DomainLoopFixture.session),
  );
  final definitions = c.read(supportAppActionRegistryProvider).definitions;
  expect(definitions.length, inInclusiveRange(41, 42));
  expect(definitions.length, lessThanOrEqualTo(NativeToolLimits.definitions));
  expect(definitions.where((d) => d.name.contains('dormant')), isEmpty);
  expectStillDormant(f);
  var sawSynchronousFence = false;
  core.native.sql.afterSelect = (statement, _) async {
    if (statement.startsWith('SELECT (coalesce(length(CAST(') &&
        statement.contains('chat_sessions')) {
      sawSynchronousFence = c
          .read(chatSourceMutationRegistryProvider)
          .isSessionPending(DomainLoopFixture.session);
    }
  };
  scriptDormantRepair(f, collector: collector);
  await f.start(tester);
  expect(sawSynchronousFence, true);
  expect(
    c
        .read(chatSourceMutationRegistryProvider)
        .isSessionPending(DomainLoopFixture.session),
    false,
    reason:
        'Preparation source and original queue settle BEFORE native confirmation.',
  );
  expectStillDormant(f);
  await f.apply(tester);
  final applied = await f.finish(tester);
  core.native.sql.afterSelect = null;
  expect(applied.status, 'stopped');
  expect(applied.body, contains('изменение сохранено'));
  expect(applied.body, contains('обновление нативных представлений ожидается'));
  expect(
    core.wire,
    hasLength(3),
    reason: 'Consumed ROOT admits no retry/next POST.',
  );
  final journal = await configurationAction(
    tester,
    () => db.select(db.supportMutationJournal).get(),
  );
  expect(journal.single.status, 'applied');
  expect(journal.single.beforeCiphertext, isNotEmpty);
  expect(
    journal.single.beforeCiphertext,
    isNot(contains(DomainLoopFixture.private)),
  );
  expect(journal.single.afterCiphertext, isNotEmpty);
  if (collector) {
    expect(
      await configurationAction(
        tester,
        () => db.select(db.cardEvolutionCollectorRuns).get(),
      ),
      isEmpty,
    );
  } else {
    final rows = await configurationAction(
      tester,
      () => db.select(db.trackerRows).get(),
    );
    expect(
      rows.where((r) => r.value == 'Supplied dormant correction'),
      hasLength(1),
    );
    expect(rows.singleWhere((r) => r.scope == 'system').value, '1');
    expect(
      rows.where((r) => r.value == DomainLoopFixture.private),
      hasLength(1),
    );
  }
  expectStillDormant(f);
  scriptDormantUndo(f);
  await f.start(tester);
  await f.apply(tester);
  final undone = await f.finish(tester);
  expect(undone.body, contains('изменение сохранено'));
  expect(core.wire, hasLength(5));
  if (collector) {
    final restored = await configurationAction(
      tester,
      () => db.select(db.cardEvolutionCollectorRuns).get(),
    );
    expect(restored.single.failureDetail, DomainLoopFixture.private);
    expect(restored.single.id, 'domain-failed-collector');
  } else {
    final restored = await configurationAction(
      tester,
      () => db.select(db.trackerRows).get(),
    );
    expect(
      restored
          .where((r) => r.scope == 'ledger')
          .every((r) => r.value == DomainLoopFixture.private),
      true,
    );
    expect(restored.singleWhere((r) => r.scope == 'system').value, '2');
  }
  final latest = await configurationAction(
    tester,
    () => c.read(chatRepoProvider).getById(DomainLoopFixture.session),
  );
  expect(
    latest!.messages.map((m) => m.toJson()).toList(),
    original!.messages.map((m) => m.toJson()).toList(),
  );
  expect(
    (await configurationAction(
      tester,
      () => db.select(db.trackerSnapshots).get(),
    )).single.trackersJson,
    '[]',
  );
  expectStillDormant(f);
  expect(
    c
        .read(supportAppNativeRepairPortProvider)
        .existingQueue(DomainLoopFixture.session),
    null,
    reason:
        'Maintenance custody is removed only after its actual original queued settlement.',
  );
  f.noEgress('${applied.body}${undone.body}');
}
