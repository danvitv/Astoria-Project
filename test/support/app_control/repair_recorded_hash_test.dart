import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_run_repo.dart';

import 'repair_gateway_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  repairGatewayTest(
    'actual canonical recorded run/effect hashes validate internally',
    (f) async {
      await f.repair.collector();
      final result = await f.call('astoria_session_integrity', {
        'session': f.sessionHandle,
        'operation': 'recordedHashes',
      });
      expect(result.content['code'], 'completed');
      final data = RepairGatewayFixture.data(result);
      expect(data['runsChecked'], 3);
      expect(data['effectsChecked'], 3);
      expect(data['issues'], isEmpty);
      expect(data['unhashedStores'], 'structural_notChecked');
      expect(data['narrativeTruth'], 'notChecked');
      final runs = await LedgerReconciliationRunRepo(
        f.base.db,
      ).readPhysicalSession(RepairFixture.session);
      for (final run in runs) {
        expect(jsonEncode(result.content), isNot(contains(run.contentHash)));
        expect(jsonEncode(result.content), isNot(contains(run.chainHash)));
      }
      f.safe(result);
    },
  );

  repairGatewayTest(
    'real stored hash mismatch is detected not replaced with recomputed digest',
    (f) async {
      await f.repair.collector();
      final db = f.base.db;
      final head = (await LedgerReconciliationRunRepo(
        db,
      ).readPhysicalSession(RepairFixture.session)).last;
      final tableName = db.ledgerReconciliationSuccessfulRuns.actualTableName;
      // Corrupt-at-insert synthetic durable row; no immutable UPDATE/trigger bypass.
      final raw =
          (await db
                  .customSelect(
                    'SELECT * FROM "$tableName" WHERE id=?',
                    variables: [Variable<String>(head.id)],
                  )
                  .getSingle())
              .data;
      final invalid = {
        ...raw,
        'id': 'synthetic-corrupt-recorded-hash',
        'ordinal': 4,
        'predecessor_chain_hash': head.chainHash,
        'chain_hash': 'SYNTHETIC_FALSE_RECORDED_CHAIN',
        'content_hash': 'SYNTHETIC_FALSE_RECORDED_HASH',
      };
      await db.customStatement(
        'INSERT INTO "$tableName" '
        '(${invalid.keys.map((k) => '"$k"').join(',')}) '
        'VALUES (${invalid.keys.map((_) => '?').join(',')})',
        invalid.values.toList(),
      );
      final before = await f.base.snapshot();
      final result = await f.call('astoria_session_integrity', {
        'session': f.sessionHandle,
        'operation': 'recordedHashes',
      });
      expect(result.content['code'], 'completed');
      expect(
        RepairGatewayFixture.data(result)['issues'],
        contains('invalidHash'),
      );
      expect(
        RepairGatewayFixture.data(result)['issues'],
        contains('invalidChain'),
      );
      expect(
        jsonEncode(result.content),
        isNot(contains('SYNTHETIC_FALSE_RECORDED_HASH')),
      );
      expect(await f.base.snapshot(), before);
      f.safe(result);
    },
  );

  repairGatewayTest(
    'corrupt stored schema returns fixed verdict without body or errors',
    (f) async {
      await f.base.db.customStatement(
        'UPDATE chat_sessions SET messages_json=? WHERE session_id=?',
        ['{SYNTHETIC_PRIVATE_BROKEN_SCHEMA', RepairFixture.session],
      );
      final before = await f.base.snapshot();
      final result = await f.call('astoria_session_integrity', {
        'session': f.sessionHandle,
        'operation': 'recordedHashes',
      });
      expect(
        RepairGatewayFixture.data(result)['issues'],
        contains('invalidSchema'),
      );
      expect(jsonEncode(result.content), isNot(contains('BROKEN_SCHEMA')));
      expect(await f.base.snapshot(), before);
      f.safe(result);
    },
  );
}
