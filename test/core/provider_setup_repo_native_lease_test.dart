import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/keyless_api_config.dart';

import 'provider_setup_repo_fixture.dart';

KeylessApiConfigPatch safePatch(KeylessApiConfigView view) =>
    KeylessApiConfigPatch(
      displayName: 'SYNTHETIC_SAFE_RENAME',
      model: view.model,
      maxTokens: 1024,
      contextSize: 8192,
      temperature: 0.5,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  providerRepoTest(
    'keyless start, true outer commit and finish retain the observed native zone',
    (f) async {
      f.native.observerZones.clear();
      f.db.beforeOuterCommit = () async {
        expect(f.pendingFences, 1);
        expect(f.native.observerZones, [true]);
      };
      final created = (await f.create(f.draft()))!;
      f.clearHooks();
      expect(created.status, SupportMutationStatus.applied);
      expect(f.native.observerZones, [true, true]);
      expect(
        (await f.api.inspectKeyless(created.connectionId))!.nativeOwned,
        isTrue,
      );
    },
  );

  providerRepoTest(
    'native async settlement completes before receipt publication',
    (f) async {
      final draft = f.draft();
      final gate = JournalBarrier();
      f.native.beforeSettlement = gate.wait;
      var delivered = false;
      final job = f.create(draft).then((value) {
        delivered = true;
        return value;
      });
      await gate.entered.future;
      expect(delivered, isFalse);
      expect(f.native.revisionFor(draft.view.connectionId), isNull);
      expect((await f.journal('synthetic-create'))!.status, 'applied');
      expect(await f.row(draft.view.connectionId), isNotNull);
      final activeObservation = (await f.api.inspectKeyless(
        draft.view.connectionId,
      ))!;
      expect(activeObservation.nativeOwned, isFalse);
      expect(
        f.api.sameKeylessObservation(
          activeObservation,
          (await f.api.inspectKeyless(draft.view.connectionId))!,
        ),
        isFalse,
        reason:
            'Two null native stamps during settlement are not current proof.',
      );
      gate.release.complete();
      final created = (await job)!;
      f.clearHooks();
      expect(f.native.releaseCalls, 1);
      expect(
        (await f.api.inspectKeyless(created.connectionId))!.nativeOwned,
        isTrue,
      );
      final observed = (await f.api.inspectKeyless(created.connectionId))!;
      expect(
        await f.update(observed, safePatch(observed.view)),
        isNotNull,
        reason:
            'Original settled revision is usable, not an active/null stamp.',
      );
    },
  );

  providerRepoTest(
    'competition during settlement returns fact without ownership or resurrected Undo',
    (f) async {
      final draft = f.draft();
      final gate = JournalBarrier();
      f.native.beforeSettlement = gate.wait;
      final job = f.api.createKeyless(draft: draft, isCurrent: f.isCurrent);
      await gate.entered.future;
      f.native.ordinaryMutation(draft.view.connectionId);
      f.native.protectedConnections.add(draft.view.connectionId);
      gate.release.complete();
      final created = (await job)!;
      f.clearHooks();
      expect(created.after, draft.view);
      expect(
        f.native.revisionFor(draft.view.connectionId),
        isNotNull,
        reason:
            'A fresh competing stamp exists but must NOT be copied into this receipt.',
      );
      expect(
        (await f.api.inspectKeyless(created.connectionId))!.nativeOwned,
        isFalse,
      );
      f.proof.known = f.proof.credentialAbsent = f.proof.referencesAbsent =
          true;
      expect(
        await f.api.restoreKeyless(expected: created, isCurrent: f.isCurrent),
        isNull,
      );
      expect(await f.row(created.connectionId), isNotNull);
      expect(f.storage.operations, isNot(contains('delete')));
    },
  );

  providerRepoTest(
    'retirement while native settlement is awaited cannot erase original committed custody',
    (f) async {
      final gate = JournalBarrier();
      f.native.beforeSettlement = gate.wait;
      final job = f.create(f.draft());
      await gate.entered.future;
      f.current = false;
      gate.release.complete();
      final created = (await job)!;
      f.clearHooks();
      expect(created.status, SupportMutationStatus.applied);
      expect(await f.row(created.connectionId), isNotNull);
      expect(await f.create(f.draft(), journalId: 'no-retired-repeat'), isNull);
    },
  );

  providerRepoTest(
    'dispose during settlement retains factual return but no native ownership',
    (f) async {
      final draft = f.draft();
      final gate = JournalBarrier();
      f.native.beforeSettlement = gate.wait;
      final job = f.create(draft);
      await gate.entered.future;
      f.native.disposed = true;
      gate.release.complete();
      final created = (await job)!;
      f.clearHooks();
      expect(created.status, SupportMutationStatus.applied);
      expect(
        (await f.api.inspectKeyless(created.connectionId))!.nativeOwned,
        isFalse,
      );
    },
  );

  providerRepoTest(
    'release failure never double-releases or fabricates rollback after committed row',
    (f) async {
      final draft = f.draft();
      f.native.beforeSettlement = () async {
        throw StateError(ProviderRepoFixture.secretCanary);
      };
      Object? error;
      try {
        await f.create(draft);
      } catch (caught) {
        error = caught;
      }
      f.clearHooks();
      expect(error, isA<KeylessApiConfigException>());
      expect('$error', isNot(contains(ProviderRepoFixture.secretCanary)));
      expect(f.native.releaseCalls, 1);
      expect(await f.row(draft.view.connectionId), isNotNull);
      expect((await f.journal('synthetic-create'))!.status, 'applied');
      expect(
        (await f.api.inspectKeyless(draft.view.connectionId))!.nativeOwned,
        isFalse,
      );
    },
  );

  providerRepoTest(
    'fresh protected ownership after restart admits only a NEW reviewed safe update',
    (f) async {
      final created = (await f.create(f.draft()))!;
      f.native.protectedConnections.add(created.connectionId);
      f.native.ordinaryMutation(
        created.connectionId,
      ); // Synthetic key-entry epoch.
      await f.change(
        created.connectionId,
        const ApiConfigsCompanion(
          topK: Value(37),
          cacheControlTtl: Value('5min'),
          reasoningHistoryCount: Value(2),
        ),
      );
      final before = (await f.row(created.connectionId))!;
      final restarted = ApiConfigRepo(
        f.db,
        keylessMutations: f.native,
        onMutationStarted: f.observeMutation,
      );
      final setup = SupportProviderSetupRepo(
        db: f.db,
        apiRepo: restarted,
        supportRepo: f.support,
      );
      final observation = (await restarted.inspectKeyless(
        created.connectionId,
      ))!;
      expect(
        observation.nativeOwned,
        isFalse,
        reason: 'Inspection does not rehydrate old creation/approval custody.',
      );
      final patch = safePatch(observation.view);
      final updated = (await setup.update(
        expected: observation,
        patch: patch,
        pendingEvidence: f.evidence(
          journalId: 'fresh-protected-update',
          action: SupportProviderSetupAction.update,
          before: observation.view,
          after: patch.applyTo(observation.view),
        ),
        isCurrent: f.isCurrent,
      ))!;
      expect(updated.status, SupportMutationStatus.applied);
      expect(
        await f.row(created.connectionId),
        before.copyWith(
          name: patch.displayName,
          model: Value(patch.model),
          maxTokens: patch.maxTokens,
          contextSize: patch.contextSize,
          temperature: patch.temperature,
        ),
      );
      expect(
        (await restarted.inspectKeyless(created.connectionId))!.nativeOwned,
        isTrue,
        reason:
            'Only the NEW committed action obtains a private process marker.',
      );
      expect(
        await setup.undo(original: created, isCurrent: f.isCurrent),
        isNull,
      );
      expect(
        (await setup.undo(original: updated, isCurrent: f.isCurrent))!.status,
        SupportMutationStatus.undone,
      );
      expect(await f.row(created.connectionId), before);
    },
  );

  providerRepoTest(
    'protected native key denies model changes before row write with no key rebind/delete',
    (f) async {
      final created = (await f.create(f.draft()))!;
      f.native.protectedConnections.add(created.connectionId);
      f.native.ordinaryMutation(created.connectionId);
      final observation = (await f.api.inspectKeyless(created.connectionId))!;
      final before = await f.snapshot();
      f.events.clear();
      expect(await f.update(observation, f.patch()), isNull);
      expect(
        f.events.where(
          (e) => e.startsWith('update:') && e.contains('api_configs'),
        ),
        isEmpty,
      );
      expect(await f.snapshot(), before);
      expect(f.native.protectedConnections, contains(created.connectionId));
      expect(f.storage.operations, isNot(contains('delete')));
      expect(
        await f.update(
          (await f.api.inspectKeyless(created.connectionId))!,
          safePatch(observation.view),
          journalId: 'safe-after-denial',
        ),
        isNotNull,
      );
    },
  );

  providerRepoTest(
    'unknown protected record state denies rather than guessing credential absence',
    (f) async {
      final created = (await f.create(f.draft()))!;
      final observation = (await f.api.inspectKeyless(created.connectionId))!;
      f.native.credentialStateKnown = false;
      final before = await f.snapshot();
      expect(await f.update(observation, f.patch()), isNull);
      expect(await f.snapshot(), before);
    },
  );
}
