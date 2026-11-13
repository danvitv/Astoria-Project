import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/studio_preset_repo.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

void main() {
  late AppDatabase db;
  late StudioPresetRepo repo;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = StudioPresetRepo(db);
    await repo.upsert(
      const StudioPreset(
        id: 'custom',
        name: 'Custom',
        blocks: [
          StudioPresetBlock(
            id: 'ledger_system',
            content: 'CUSTOM',
            section: '',
            injectionPoint: 'ledger',
            enabled: false,
          ),
        ],
      ),
    );
  });
  tearDown(() => db.close());

  Future<StudioPresetRow> row() => (db.select(
    db.studioPresetRows,
  )..where((table) => table.presetId.equals('custom'))).getSingle();

  test('preview and ordinary reads never persist a consolidation', () async {
    final before = (await row()).toJson();
    await repo.getById('custom');
    final plan = await repo.previewLedgerInstructionUpgrade('custom');
    expect(plan.needsUpgrade, isTrue);
    expect((await row()).toJson(), before);
  });

  test(
    'confirmed upgrade only changes intended columns and preserves raw extras',
    () async {
      final source = await row();
      final blocks = jsonDecode(source.blocksJson) as List;
      (blocks.first as Map)['unknown_authored_field'] = {'keep': 'raw'};
      final runtime = jsonDecode(source.runtimeSettingsJson) as Map;
      runtime['unknown_runtime_setting'] = ['keep'];
      await (db.update(
        db.studioPresetRows,
      )..where((table) => table.presetId.equals('custom'))).write(
        StudioPresetRowsCompanion(
          blocksJson: Value(jsonEncode(blocks)),
          runtimeSettingsJson: Value(jsonEncode(runtime)),
        ),
      );
      final before = await row();
      final preview = await repo.previewLedgerInstructionUpgrade('custom');
      await repo.applyLedgerInstructionUpgrade(
        presetId: 'custom',
        expectedFingerprint: preview.expectedFingerprint,
      );
      final after = await row();
      final rawBlocks = jsonDecode(after.blocksJson) as List;
      expect(rawBlocks.first, blocks.first);
      expect((rawBlocks.first as Map)['enabled'], isFalse);
      final rawRuntime = jsonDecode(after.runtimeSettingsJson) as Map;
      expect(rawRuntime['unknown_runtime_setting'], ['keep']);
      expect(rawRuntime['ledgerInstructionRevision'], 1);
      final beforeFields = before.toJson();
      final afterFields = after.toJson();
      for (final key in beforeFields.keys) {
        if (['blocksJson', 'runtimeSettingsJson', 'updatedAt'].contains(key)) {
          continue;
        }
        expect(afterFields[key], beforeFields[key], reason: key);
      }
    },
  );

  test('stale preview rejects an unknown raw field change', () async {
    final preview = await repo.previewLedgerInstructionUpgrade('custom');
    final source = await row();
    final runtime = jsonDecode(source.runtimeSettingsJson) as Map;
    runtime['new_unknown_field'] = 'concurrent';
    await (db.update(
      db.studioPresetRows,
    )..where((table) => table.presetId.equals('custom'))).write(
      StudioPresetRowsCompanion(
        runtimeSettingsJson: Value(jsonEncode(runtime)),
      ),
    );
    final concurrent = (await row()).toJson();
    await expectLater(
      repo.applyLedgerInstructionUpgrade(
        presetId: 'custom',
        expectedFingerprint: preview.expectedFingerprint,
      ),
      throwsStateError,
    );
    expect((await row()).toJson(), concurrent);
  });

  test('stale preview rejects a concurrent known field change', () async {
    final preview = await repo.previewLedgerInstructionUpgrade('custom');
    await (db.update(db.studioPresetRows)
          ..where((table) => table.presetId.equals('custom')))
        .write(const StudioPresetRowsCompanion(name: Value('Concurrent name')));
    await expectLater(
      repo.applyLedgerInstructionUpgrade(
        presetId: 'custom',
        expectedFingerprint: preview.expectedFingerprint,
      ),
      throwsStateError,
    );
    expect((await row()).name, 'Concurrent name');
  });

  test(
    'marker survives deletion and repeat application performs no write',
    () async {
      final preview = await repo.previewLedgerInstructionUpgrade('custom');
      await repo.applyLedgerInstructionUpgrade(
        presetId: 'custom',
        expectedFingerprint: preview.expectedFingerprint,
      );
      await (db.update(db.studioPresetRows)
            ..where((table) => table.presetId.equals('custom')))
          .write(const StudioPresetRowsCompanion(blocksJson: Value('[]')));
      final before = (await row()).toJson();
      final repeat = await repo.previewLedgerInstructionUpgrade('custom');
      expect(repeat.needsUpgrade, isFalse);
      await repo.applyLedgerInstructionUpgrade(
        presetId: 'custom',
        expectedFingerprint: repeat.expectedFingerprint,
      );
      expect((await row()).toJson(), before);
    },
  );
}
