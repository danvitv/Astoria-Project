import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';

import 'provider_setup_repo_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final reason in [
    'unknown',
    'credential-unknown-or-present',
    'references',
  ]) {
    providerRepoTest('create Undo denies $reason without any vault deletion', (
      f,
    ) async {
      final created = (await f.create(f.draft()))!;
      final beforeRow = await f.row(created.connectionId);
      f.proof.known = reason != 'unknown';
      f.proof.credentialAbsent = reason != 'credential-unknown-or-present';
      f.proof.referencesAbsent = reason != 'references';
      final operations = List.of(f.storage.operations);
      final denied = (await f.setup.undo(
        original: created,
        isCurrent: f.isCurrent,
      ))!;
      expect(denied.status, SupportMutationStatus.undoConflict);
      expect(await f.row(created.connectionId), beforeRow);
      expect(
        f.storage.operations.skip(operations.length),
        isNot(contains('delete')),
      );
      expect(f.proof.held, 0);
      expect(
        await f.setup.undo(original: created, isCurrent: f.isCurrent),
        isNull,
      );
    });
  }

  providerRepoTest(
    'create Undo requires held positive absence proof through outer commit',
    (f) async {
      final created = (await f.create(f.draft()))!;
      f.proof.known = f.proof.credentialAbsent = f.proof.referencesAbsent =
          true;
      f.db.beforeOuterCommit = () async {
        expect(f.proof.held, 1);
        expect(f.pendingFences, 1);
        expect(await f.api.inspectKeyless(created.connectionId), isNull);
      };
      final undone = (await f.setup.undo(
        original: created,
        isCurrent: f.isCurrent,
      ))!;
      f.clearHooks();
      expect(undone.status, SupportMutationStatus.undone);
      expect(await f.row(created.connectionId), isNull);
      expect(f.proof.held, 0);
      expect(f.pendingFences, 0);
      expect(f.storage.operations, isNot(contains('delete')));
    },
  );

  providerRepoTest(
    'changed exact row makes update Undo conflict, never full-row restoration',
    (f) async {
      final created = (await f.create(f.draft()))!;
      final observation = (await f.api.inspectKeyless(created.connectionId))!;
      final updated = (await f.update(observation, f.patch()))!;
      await f.change(
        created.connectionId,
        const ApiConfigsCompanion(topK: Value(99)),
      );
      final row = await f.row(created.connectionId);
      final denied = (await f.setup.undo(
        original: updated,
        isCurrent: f.isCurrent,
      ))!;
      expect(denied.status, SupportMutationStatus.undoConflict);
      expect(await f.row(created.connectionId), row);
    },
  );

  providerRepoTest(
    'native credential revision rotation denies update Undo even with equal row',
    (f) async {
      final created = (await f.create(f.draft()))!;
      final observation = (await f.api.inspectKeyless(created.connectionId))!;
      final updated = (await f.update(observation, f.patch()))!;
      final row = await f.row(created.connectionId);
      f.native.ordinaryMutation(created.connectionId);
      final denied = (await f.setup.undo(
        original: updated,
        isCurrent: f.isCurrent,
      ))!;
      expect(denied.status, SupportMutationStatus.undoConflict);
      expect(await f.row(created.connectionId), row);
    },
  );

  providerRepoTest('foreign composition cannot consume original Undo receipt', (
    f,
  ) async {
    final created = (await f.create(f.draft()))!;
    final observed = (await f.api.inspectKeyless(created.connectionId))!;
    final updated = (await f.update(observed, f.patch()))!;
    final foreign = SupportProviderSetupRepo(
      db: f.db,
      apiRepo: f.api,
      supportRepo: f.support,
    );
    expect(
      await foreign.undo(original: updated, isCurrent: f.isCurrent),
      isNull,
    );
    expect(
      (await f.setup.undo(original: updated, isCurrent: f.isCurrent))!.status,
      SupportMutationStatus.undone,
    );
  });

  providerRepoTest(
    'once restore receipt cannot be reused or restored after ABA',
    (f) async {
      final draft = f.draft();
      final created = (await f.api.createKeyless(
        draft: draft,
        isCurrent: f.isCurrent,
      ))!;
      final observed = (await f.api.inspectKeyless(created.connectionId))!;
      final updated = (await f.api.updateKeyless(
        expected: observed,
        patch: f.patch(),
        isCurrent: f.isCurrent,
      ))!;
      final after = (await f.api.getById(created.connectionId))!;
      await f.api.put(after);
      expect(
        await f.api.restoreKeyless(expected: updated, isCurrent: f.isCurrent),
        isNull,
      );
      expect(
        await f.api.restoreKeyless(expected: updated, isCurrent: f.isCurrent),
        isNull,
      );
      expect(await f.api.getById(created.connectionId), after);
    },
  );
}
