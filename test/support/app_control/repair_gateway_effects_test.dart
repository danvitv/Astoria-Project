import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/session_repair_repo.dart';

import 'repair_gateway_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  repairGatewayTest(
    'native exact Collector deletion and original receipt Undo',
    (f) async {
      await f.repair.collector();
      final before = await f.repair.snapshotExcept({
        'support_mutation_journal',
        'card_evolution_collector_runs',
      });
      final target = await f.target('collectorAttempt');
      final result = await f.call('astoria_session_repair', {
        'target': target,
        'operation': 'deleteUnusedCollector',
      });
      expect(result.content['code'], 'completed');
      expect(result.content['effect'], 'persisted');
      final request = f.confirmation.requests.single;
      expect(request.target, target);
      expect(request.arguments, {
        'target': target,
        'operation': 'deleteUnusedCollector',
      });
      expect(request.observation, isA<SessionRepairPlan>());
      expect(request.preview['affectedRecords'], 1);
      expect(request.preview['manualRevisionBumps'], 0);
      expect(request.preview['bodyAccess'], 'notGranted');
      expect(
        await f.base.db.select(f.base.db.cardEvolutionCollectorRuns).get(),
        isEmpty,
      );
      final journal =
          (await f.base.db.select(f.base.db.supportMutationJournal).get())
              .single;
      expect(journal.status, 'applied');
      expect(journal.beforeCiphertext, isNot(contains(RepairFixture.canary)));
      expect(f.base.events.any((e) => e.startsWith('encrypt:')), isTrue);
      expect(f.native.invalidated, [RepairFixture.session]);
      expect(f.container.read(repairGatewayNativeStateProvider), 1);
      f.safe(result);
      final undo = await f.call('astoria_session_repair_undo', {
        'receipt': RepairGatewayFixture.data(result)['receipt'],
      });
      expect(undo.content['code'], 'completed');
      expect(RepairGatewayFixture.data(undo)['outcome'], 'undone');
      expect(
        (await f.base.db.select(f.base.db.cardEvolutionCollectorRuns).get())
            .single
            .failureDetail,
        RepairFixture.canary,
      );
      expect(
        await f.repair.snapshotExcept({
          'support_mutation_journal',
          'card_evolution_collector_runs',
        }),
        before,
      );
      expect(f.confirmation.requests.length, 2);
      expect(f.container.read(repairGatewayNativeStateProvider), 2);
      expect(
        f.confirmation.requests.last.observation,
        isA<SessionRepairReceipt>(),
      );
      f.safe(undo);
      final replay = await f.call('astoria_session_repair_undo', {
        'receipt': RepairGatewayFixture.data(result)['receipt'],
      });
      expect(replay.content['code'], 'unavailable');
    },
  );

  repairGatewayTest(
    'native Ledger correction bumps durable fence and restores exact original',
    (f) async {
      final originalRows = await f.base.db.select(f.base.db.trackerRows).get();
      final target = await f.target('liveLedger');
      final result = await f.call('astoria_session_repair', {
        'target': target,
        'operation': 'correctLedger',
        'value': 'SYNTHETIC_NEW_VALUE',
      });
      expect(result.content['code'], 'completed');
      expect(
        f.confirmation.requests.single.arguments['value'],
        'SYNTHETIC_NEW_VALUE',
      );
      expect(f.confirmation.requests.single.preview['manualRevisionBumps'], 1);
      final changed = await f.base.db.select(f.base.db.trackerRows).get();
      expect(changed.where((r) => r.value == 'SYNTHETIC_NEW_VALUE').length, 1);
      expect(changed.where((r) => r.value == RepairFixture.canary).length, 1);
      expect(changed.singleWhere((r) => r.scope == 'system').value, '1');
      expect(
        (await f.base.db.select(f.base.db.trackerSnapshots).get())
            .single
            .trackersJson,
        '[]',
      );
      final undo = await f.call('astoria_session_repair_undo', {
        'receipt': RepairGatewayFixture.data(result)['receipt'],
      });
      expect(RepairGatewayFixture.data(undo)['outcome'], 'undone');
      final restored = await f.base.db.select(f.base.db.trackerRows).get();
      expect(
        restored
            .where((r) => r.scope == 'ledger')
            .map((r) => r.toJson())
            .toList(),
        originalRows.map((r) => r.toJson()).toList(),
      );
      expect(restored.singleWhere((r) => r.scope == 'system').value, '2');
      f.safe(result);
      f.safe(undo);
    },
  );

  repairGatewayTest(
    'actual three DB scalar repairs and conditional Undo preserve domains',
    (f) async {
      final targets = [
        f.groupHandle,
        f.integrityAdapter.bindTarget(
          const DatabaseMaintenanceTarget.characterMembership(
            characterId: 'missing-character',
            folderId: 'character-folder',
          ),
          f.original,
        ),
        f.integrityAdapter.bindTarget(
          const DatabaseMaintenanceTarget.presetMembership(
            presetId: 'ordinary-only',
            folderId: 'preset-folder',
            presetKind: DatabaseMaintenancePresetKind.agentic,
          ),
          f.original,
        ),
      ];
      for (final target in targets) {
        final result = await f.call('astoria_database_repair', {
          'target': target,
        });
        expect(result.content['code'], 'completed');
        expect(RepairGatewayFixture.data(result)['affectedRows'], 1);
        final undo = await f.call('astoria_database_repair_undo', {
          'receipt': RepairGatewayFixture.data(result)['receipt'],
        });
        expect(RepairGatewayFixture.data(undo)['outcome'], 'undone');
        f.safe(undo);
      }
      expect((await f.base.character('legacy'))['variant_group_id'], '');
      expect(await f.base.memberCount('ordinary-only', 'agentic'), 1);
      expect(await f.base.memberCount('collision', 'normal'), 1);
      expect(await f.base.memberCount('collision', 'agentic'), 1);
      expect(
        (await f.base.db.select(f.base.db.supportMutationJournal).get()).length,
        3,
      );
    },
  );

  repairGatewayTest(
    'registered all-table health is bounded metadata and performs no AEAD',
    (f) async {
      f.base.events.clear();
      final seen = <String>{};
      int? offset = 0;
      while (offset != null) {
        final result = await f.call('astoria_database_health', {
          'offset': offset,
        });
        expect(result.content['code'], 'completed');
        final data = RepairGatewayFixture.data(result);
        expect(data['registeredTables'], f.base.db.allTables.length);
        expect(data['expectedVersion'], f.base.db.schemaVersion);
        seen.addAll(
          (data['tables'] as List).cast<Map>().map((r) => r['table'] as String),
        );
        offset = data['nextOffset'] as int?;
        f.safe(result);
      }
      expect(seen, f.base.db.allTables.map((t) => t.actualTableName).toSet());
      expect(
        f.base.events.any(
          (e) => e.startsWith('encrypt:') || e.startsWith('decrypt-'),
        ),
        isFalse,
      );
      expect(f.confirmation.requests, isEmpty);
    },
  );

  repairGatewayTest(
    'malformed observation reports fixed issues without body access',
    (f) async {
      await f.repair.collector();
      await f.repair.observation(malformed: true);
      final before = await f.base.snapshot();
      final result = await f.inspect();
      expect(result.content['code'], 'completed');
      final records = (RepairGatewayFixture.data(result)['records'] as List)
          .cast<Map>();
      expect(
        records.singleWhere((r) => r['kind'] == 'observation')['issues'],
        contains('malformedPayload'),
      );
      expect(jsonEncode(result.content), isNot(contains('PRIVATE_MALFORMED')));
      expect(await f.base.snapshot(), before);
      f.safe(result);
    },
  );

  repairGatewayTest(
    'actual retained after-state conflict settles Undo without target write',
    (f) async {
      final target = await f.target('liveLedger');
      final result = await f.call('astoria_session_repair', {
        'target': target,
        'operation': 'correctLedger',
        'value': 'SYNTHETIC_NEW_VALUE',
      });
      expect(result.content['code'], 'completed');
      await f.base.db.customStatement(
        'UPDATE tracker_rows SET value=? WHERE session_id=? AND scope=?',
        ['SYNTHETIC_LATER_CHANGE', RepairFixture.session, 'ledger'],
      );
      final before = await f.repair.snapshotExcept({
        'support_mutation_journal',
      });
      final undo = await f.call('astoria_session_repair_undo', {
        'receipt': RepairGatewayFixture.data(result)['receipt'],
      });
      expect(undo.content['code'], 'conflict');
      expect(RepairGatewayFixture.data(undo)['outcome'], 'undoConflict');
      expect(RepairGatewayFixture.data(undo)['affectedRecords'], 0);
      expect(
        await f.repair.snapshotExcept({'support_mutation_journal'}),
        before,
      );
      f.safe(undo);
    },
  );
}
