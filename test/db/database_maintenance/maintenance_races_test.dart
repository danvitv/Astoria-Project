import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/models/database_maintenance.dart';

import 'maintenance_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  maintenanceTest(
    'retired original operation cannot be replaced by a fresh callback',
    (f) async {
      final plan = (await f.prepare(
        const DatabaseMaintenanceTarget.characterGroup('legacy'),
      ))!;
      final before = await f.snapshot();
      f.current = false;
      expect(await f.repo.apply(plan: plan, isCurrent: () => true), isNull);
      expect(await f.snapshot(), before);
    },
  );

  maintenanceTest(
    'changed row at same timestamp refuses without journal/effect',
    (f) async {
      final plan = (await f.prepare(
        const DatabaseMaintenanceTarget.characterGroup('legacy'),
      ))!;
      await f.db.customStatement(
        'UPDATE characters SET description = ? WHERE char_id = ?',
        ['SYNTHETIC_CHANGED_NO_TIMESTAMP', 'legacy'],
      );
      final before = await f.snapshot();
      expect(await f.repo.apply(plan: plan, isCurrent: f.isCurrent), isNull);
      expect(await f.snapshot(), before);
    },
  );

  maintenanceTest('formerly missing dependency now exists: no deletion', (
    f,
  ) async {
    final plan = (await f.prepare(
      const DatabaseMaintenanceTarget.characterMembership(
        characterId: 'missing-character',
        folderId: 'character-folder',
      ),
    ))!;
    await f.db.customStatement(
      'INSERT INTO characters '
      '(char_id, name, variant_group_id) VALUES (?, ?, ?)',
      ['missing-character', 'SYNTHETIC_RECOVERED_OWNER', 'missing-character'],
    );
    final before = await f.snapshot();
    expect(await f.repo.apply(plan: plan, isCurrent: f.isCurrent), isNull);
    expect(await f.snapshot(), before);
  });

  maintenanceTest(
    'existing dependency changed at same timestamp: no deletion',
    (f) async {
      final plan = (await f.prepare(
        const DatabaseMaintenanceTarget.characterMembership(
          characterId: 'missing-character',
          folderId: 'character-folder',
        ),
      ))!;
      await f.db.customStatement(
        'UPDATE character_folders SET name = ? WHERE folder_id = ?',
        ['SYNTHETIC_CHANGED_FOLDER', 'character-folder'],
      );
      final before = await f.snapshot();
      expect(await f.repo.apply(plan: plan, isCurrent: f.isCurrent), isNull);
      expect(await f.snapshot(), before);
    },
  );

  maintenanceTest(
    'cancellation inside actual AEAD reservation rolls everything back',
    (f) async {
      final plan = (await f.prepare(
        const DatabaseMaintenanceTarget.characterGroup('legacy'),
      ))!;
      final before = await f.snapshot();
      f.hook = (event) async {
        if (event.startsWith('encrypt:') &&
            event.contains('support_mutation_journal')) {
          f.current = false;
        }
      };
      expect(await f.repo.apply(plan: plan, isCurrent: f.isCurrent), isNull);
      f.hook = null;
      expect(await f.snapshot(), before);
    },
  );

  maintenanceTest(
    'dependency changes during encrypted reservation are rechecked',
    (f) async {
      final plan = (await f.prepare(
        const DatabaseMaintenanceTarget.characterMembership(
          characterId: 'missing-character',
          folderId: 'character-folder',
        ),
      ))!;
      final before = await f.snapshot();
      f.hook = (event) async {
        if (event.startsWith('encrypt:') &&
            event.contains('support_mutation_journal')) {
          f.hook = null;
          await f.db.customStatement(
            'INSERT INTO characters '
            '(char_id, name, variant_group_id) VALUES (?, ?, ?)',
            ['missing-character', 'SYNTHETIC_NEW_OWNER', 'missing-character'],
          );
        }
      };
      expect(await f.repo.apply(plan: plan, isCurrent: f.isCurrent), isNull);
      f.hook = null;
      expect(
        await f.snapshot(),
        before,
        reason:
            'Same outer transaction rolls back reservation and test insertion.',
      );
    },
  );

  maintenanceTest(
    'retirement after provisional effect rolls effect and journal back',
    (f) async {
      final plan = (await f.prepare(
        const DatabaseMaintenanceTarget.characterGroup('legacy'),
      ))!;
      final before = await f.snapshot();
      f.hook = (event) async {
        if (event.startsWith(
          'update:UPDATE "characters" SET variant_group_id',
        )) {
          f.current = false;
        }
      };
      expect(await f.repo.apply(plan: plan, isCurrent: f.isCurrent), isNull);
      f.hook = null;
      expect(await f.snapshot(), before);
    },
  );

  maintenanceTest('journal failure cannot leave an unjournaled scalar effect', (
    f,
  ) async {
    final plan = (await f.prepare(
      const DatabaseMaintenanceTarget.characterGroup('legacy'),
    ))!;
    final before = await f.snapshot();
    f.hook = (event) async {
      if (event.startsWith('update:UPDATE "characters" SET variant_group_id')) {
        f.hook = (next) async {
          if (next.startsWith('decrypt-before:')) {
            throw StateError(MaintenanceFixture.canary);
          }
        };
      }
    };
    await expectLater(
      f.repo.apply(plan: plan, isCurrent: f.isCurrent),
      throwsA(isA<DatabaseMaintenanceException>()),
    );
    f.clearHooks();
    expect(await f.snapshot(), before);
    expect(
      const DatabaseMaintenanceException().toString(),
      isNot(contains(MaintenanceFixture.canary)),
    );
  });

  maintenanceTest(
    'credential-like identities and oversized private guards refuse',
    (f) async {
      expect(
        await f.prepare(
          const DatabaseMaintenanceTarget.characterGroup('sk-synthetic-secret'),
        ),
        isNull,
      );
      await f.db.customStatement(
        'UPDATE characters SET description = ? WHERE char_id = ?',
        [List.filled(65537, 'x').join(), 'legacy'],
      );
      final before = await f.snapshot();
      expect(
        await f.prepare(
          const DatabaseMaintenanceTarget.characterGroup('legacy'),
        ),
        isNull,
      );
      expect(await f.snapshot(), before);
    },
  );

  maintenanceTest(
    'membership Undo refuses newly present source without reinsertion',
    (f) async {
      final plan = (await f.prepare(
        const DatabaseMaintenanceTarget.characterMembership(
          characterId: 'missing-character',
          folderId: 'character-folder',
        ),
      ))!;
      final applied = (await f.repo.apply(plan: plan, isCurrent: f.isCurrent))!;
      await f.db.customStatement(
        'INSERT INTO characters '
        '(char_id, name, variant_group_id) VALUES (?, ?, ?)',
        ['missing-character', 'SYNTHETIC_RECOVERED_OWNER', 'missing-character'],
      );
      final before = await f.character('missing-character');
      final result = (await f.repo.undo(
        receipt: applied,
        isCurrent: f.isCurrent,
      ))!;
      expect(result.outcome, DatabaseMaintenanceMutationOutcome.undoConflict);
      expect(await f.character('missing-character'), before);
      expect((await f.db.select(f.db.characterFolderMembers).get()).length, 1);
    },
  );

  maintenanceTest(
    'introduced collateral trigger invalidates an original narrow plan',
    (f) async {
      final plan = (await f.prepare(
        const DatabaseMaintenanceTarget.characterGroup('legacy'),
      ))!;
      await f.db.customStatement(
        'CREATE TRIGGER synthetic_collateral '
        'AFTER UPDATE ON characters BEGIN '
        "DELETE FROM characters WHERE char_id = 'unrelated'; END",
      );
      final before = await f.snapshot();
      expect(await f.repo.apply(plan: plan, isCurrent: f.isCurrent), isNull);
      expect(await f.snapshot(), before);
    },
  );

  maintenanceTest(
    'caller outer transaction cannot obtain provisional applied custody',
    (f) async {
      final plan = (await f.prepare(
        const DatabaseMaintenanceTarget.characterGroup('legacy'),
      ))!;
      final before = await f.snapshot();
      await f.db.transaction(() async {
        expect(await f.repo.apply(plan: plan, isCurrent: f.isCurrent), isNull);
        expect(
          await f.prepare(
            const DatabaseMaintenanceTarget.characterGroup('legacy'),
          ),
          isNull,
        );
      });
      expect(await f.snapshot(), before);
    },
  );
}
