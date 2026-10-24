import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/models/database_maintenance.dart';
import 'package:glaze_flutter/core/db/repositories/database_maintenance_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';

import 'maintenance_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  maintenanceTest('group: narrow write, encrypted originals and exact Undo', (
    f,
  ) async {
    final unrelated = await f.character('unrelated');
    final before = await f.snapshot();
    final plan = (await f.prepare(
      const DatabaseMaintenanceTarget.characterGroup('legacy'),
    ))!;
    expect(
      await f.snapshot(),
      before,
      reason: 'Preview has no durable effect.',
    );
    expect(plan.affectedRows, 1);
    expect(plan.requiresNativeConfirmation, isTrue);
    expect(plan.toString(), isNot(contains(MaintenanceFixture.canary)));
    final applied = (await f.repo.apply(plan: plan, isCurrent: f.isCurrent))!;
    expect(applied.outcome, DatabaseMaintenanceMutationOutcome.applied);
    expect((await f.character('legacy'))['variant_group_id'], 'legacy');
    expect(await f.character('unrelated'), unrelated);
    final raw = (await f.db.select(f.db.supportMutationJournal).get()).single;
    expect(raw.status, 'applied');
    expect(raw.beforeCiphertext, isNot(contains('groupId')));
    expect(raw.afterCiphertext, isNot(contains('groupId')));
    final record = (await f.support.getMutationById(plan.operationId))!;
    final nativeBefore = SupportMutationEvidence.decode(record.beforeJson)!;
    final nativeAfter = SupportMutationEvidence.decode(record.afterJson)!;
    expect(jsonDecode(nativeBefore)['groupId'], '');
    expect(jsonDecode(nativeAfter)['groupId'], 'legacy');
    expect(record.beforeJson, isNot(contains(MaintenanceFixture.canary)));
    expect(await f.repo.apply(plan: plan, isCurrent: f.isCurrent), isNull);
    final undone = (await f.repo.undo(
      receipt: applied,
      isCurrent: f.isCurrent,
    ))!;
    expect(undone.outcome, DatabaseMaintenanceMutationOutcome.undone);
    expect((await f.character('legacy'))['variant_group_id'], '');
    expect(await f.character('unrelated'), unrelated);
    expect(await f.repo.undo(receipt: applied, isCurrent: f.isCurrent), isNull);
    expect(
      await f.repo.apply(plan: plan, isCurrent: f.isCurrent),
      isNull,
      reason: 'Original operation cannot replay even after exact Undo.',
    );
  });

  maintenanceTest('character membership removes exactly the dangling row', (
    f,
  ) async {
    final plan = (await f.prepare(
      const DatabaseMaintenanceTarget.characterMembership(
        characterId: 'missing-character',
        folderId: 'character-folder',
      ),
    ))!;
    final applied = (await f.repo.apply(plan: plan, isCurrent: f.isCurrent))!;
    final rows = await f.db.select(f.db.characterFolderMembers).get();
    expect(rows.length, 1);
    expect(rows.single.charId, 'unrelated');
    final undone = (await f.repo.undo(
      receipt: applied,
      isCurrent: f.isCurrent,
    ))!;
    expect(undone.outcome, DatabaseMaintenanceMutationOutcome.undone);
    final restored = await f.db.select(f.db.characterFolderMembers).get();
    expect(restored.length, 2);
    expect(
      restored.singleWhere((r) => r.charId == 'missing-character').addedAt,
      7,
    );
  });

  maintenanceTest(
    'ordinary and Studio colliding IDs retain independent custody',
    (f) async {
      for (final kind in DatabaseMaintenancePresetKind.values) {
        expect(
          await f.prepare(
            DatabaseMaintenanceTarget.presetMembership(
              presetId: 'collision',
              folderId: 'preset-folder',
              presetKind: kind,
            ),
          ),
          isNull,
        );
      }
      expect(
        await f.prepare(
          const DatabaseMaintenanceTarget.presetMembership(
            presetId: 'ordinary-only',
            folderId: 'preset-folder',
            presetKind: DatabaseMaintenancePresetKind.normal,
          ),
        ),
        isNull,
      );
      final plan = (await f.prepare(
        const DatabaseMaintenanceTarget.presetMembership(
          presetId: 'ordinary-only',
          folderId: 'preset-folder',
          presetKind: DatabaseMaintenancePresetKind.agentic,
        ),
      ))!;
      final applied = (await f.repo.apply(plan: plan, isCurrent: f.isCurrent))!;
      expect(await f.memberCount('ordinary-only', 'agentic'), 0);
      expect(await f.memberCount('ordinary-only', 'normal'), 1);
      expect(await f.memberCount('collision', 'normal'), 1);
      expect(await f.memberCount('collision', 'agentic'), 1);
      expect(
        (await f.repo.undo(receipt: applied, isCurrent: f.isCurrent))!.outcome,
        DatabaseMaintenanceMutationOutcome.undone,
      );
      expect(await f.memberCount('ordinary-only', 'agentic'), 1);
    },
  );

  maintenanceTest(
    'missing ordinary member is not saved by colliding Studio ID',
    (f) async {
      await f.db.customStatement('DELETE FROM presets WHERE preset_id = ?', [
        'collision',
      ]);
      final plan = (await f.prepare(
        const DatabaseMaintenanceTarget.presetMembership(
          presetId: 'collision',
          folderId: 'preset-folder',
          presetKind: DatabaseMaintenancePresetKind.normal,
        ),
      ))!;
      final applied = (await f.repo.apply(plan: plan, isCurrent: f.isCurrent))!;
      expect(applied.outcome, DatabaseMaintenanceMutationOutcome.applied);
      expect(await f.memberCount('collision', 'normal'), 0);
      expect(await f.memberCount('collision', 'agentic'), 1);
    },
  );

  maintenanceTest(
    'Undo conflict refuses to overwrite a later exact-row change',
    (f) async {
      final plan = (await f.prepare(
        const DatabaseMaintenanceTarget.characterGroup('legacy'),
      ))!;
      final applied = (await f.repo.apply(plan: plan, isCurrent: f.isCurrent))!;
      await f.db.customStatement(
        'UPDATE characters SET description = ? WHERE char_id = ?',
        ['SYNTHETIC_NEW_PRIVATE', 'legacy'],
      );
      final before = await f.character('legacy');
      final conflict = (await f.repo.undo(
        receipt: applied,
        isCurrent: f.isCurrent,
      ))!;
      expect(conflict.outcome, DatabaseMaintenanceMutationOutcome.undoConflict);
      expect(await f.character('legacy'), before);
      expect(
        (await f.db.select(f.db.supportMutationJournal).get()).single.status,
        'undo_conflict',
      );
    },
  );

  maintenanceTest('plan is privately owned by its exact repository instance', (
    f,
  ) async {
    final plan = (await f.prepare(
      const DatabaseMaintenanceTarget.characterGroup('legacy'),
    ))!;
    final second = DatabaseMaintenanceRepo(f.db, f.support);
    final before = await f.snapshot();
    expect(await second.apply(plan: plan, isCurrent: f.isCurrent), isNull);
    expect(await f.snapshot(), before);
  });
}
