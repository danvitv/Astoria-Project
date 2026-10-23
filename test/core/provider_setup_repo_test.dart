import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/keyless_api_config.dart';

import 'provider_setup_repo_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  providerRepoTest(
    'strict create saves exact keyless fields and encrypted bound evidence',
    (f) async {
      final draft = f.draft();
      final result = (await f.create(draft))!;
      final row = (await f.row(result.connectionId))!;
      expect(result.status, SupportMutationStatus.applied);
      expect(result.before, isNull);
      expect(result.after, draft.view);
      expect(row.apiKey, '');
      expect(row.embeddingApiKey, '');
      expect(row.embeddingEnabled, isFalse);
      expect(row.embeddingUseSame, isFalse);
      expect(row.embeddingEndpoint, '');
      expect(row.embeddingModel, '');
      expect(row.embeddingLlmPresetId, '');
      expect(row.extraRequestParametersJson, '[]');
      expect(row.mode, 'chat');
      expect(row.endpoint, draft.view.endpoint);
      expect(row.model, draft.view.model);
      expect(row.name, draft.view.displayName);
      expect(row.maxTokens, draft.view.maxTokens);
      expect(row.contextSize, draft.view.contextSize);
      expect(row.temperature, draft.view.temperature);
      expect(row.stream, isTrue);
      expect(row.sessionIdMode, 'off');
      expect(
        (await f.api.inspectKeyless(result.connectionId))!.nativeOwned,
        isTrue,
      );
      final durable = (await f.support.getMutationById(result.journalId))!;
      final expected = f.evidence(
        journalId: result.journalId,
        action: SupportProviderSetupAction.create,
        after: draft.view,
      );
      expect(durable.beforeJson, expected.beforeJson);
      expect(durable.afterJson, expected.afterJson);
      final encrypted = (await f.journal(result.journalId))!;
      for (final canary in [
        ProviderRepoFixture.nameCanary,
        ProviderRepoFixture.urlCanary,
        ProviderRepoFixture.secretCanary,
      ]) {
        expect(encrypted.beforeCiphertext, isNot(contains(canary)));
        expect(encrypted.afterCiphertext, isNot(contains(canary)));
        expect('$result', isNot(contains(canary)));
      }
      expect(f.storage.operations, isNot(contains('delete')));
      expect(f.pendingFences, 0);
    },
  );

  providerRepoTest(
    'same reviewed ID collision never overwrites or retries with another ID',
    (f) async {
      final draft = f.draft();
      await f.create(draft);
      final before = await f.snapshot();
      expect(await f.create(draft, journalId: 'collision'), isNull);
      expect(await f.snapshot(), before);
      expect(await f.journal('collision'), isNull);
      expect((await f.db.select(f.db.apiConfigs).get()).length, 1);
    },
  );

  providerRepoTest('legacy collision preserves actual nonempty row key', (
    f,
  ) async {
    final draft = f.draft();
    await f.api.put(
      ApiConfig(
        id: draft.view.connectionId,
        name: 'SYNTHETIC_LEGACY',
        endpoint: draft.view.endpoint,
        model: draft.view.model,
        apiKey: ProviderRepoFixture.secretCanary,
      ),
    );
    final before = await f.snapshot();
    expect(await f.create(draft), isNull);
    expect(await f.snapshot(), before);
    expect(await f.api.inspectKeyless(draft.view.connectionId), isNull);
  });

  providerRepoTest(
    'narrow update and Undo preserve every unrelated original row field',
    (f) async {
      final created = (await f.create(f.draft()))!;
      // Synthetic direct setup of unrelated fields, not production mutation proof.
      await f.change(
        created.connectionId,
        const ApiConfigsCompanion(
          topP: Value(0.42),
          topK: Value(17),
          cacheControlTtl: Value('5min'),
          cacheBreakpointMode: Value('stable_prefix'),
          reasoningHistoryCount: Value(3),
          includeLastReasoning: Value(true),
          requestReasoning: Value(true),
          showNativeReasoning: Value(false),
          historyTrimMode: Value('stepped'),
          historyTrimTriggerPercent: Value(77),
          historyTrimStepPercent: Value(21),
          firstChunkTimeoutMs: Value(73000),
          omitTopP: Value(true),
          useSystemInstruction: Value(false),
          promptPostProcessing: Value('none'),
        ),
      );
      final before = (await f.row(created.connectionId))!;
      final expected = (await f.api.inspectKeyless(created.connectionId))!;
      final patch = f.patch();
      final updated = (await f.update(expected, patch))!;
      expect(updated.before, expected.view);
      expect(updated.after, patch.applyTo(expected.view));
      final exactEvidence = f.evidence(
        journalId: updated.journalId,
        action: SupportProviderSetupAction.update,
        before: expected.view,
        after: patch.applyTo(expected.view),
      );
      final appliedJournal = (await f.support.getMutationById(
        updated.journalId,
      ))!;
      expect(appliedJournal.beforeJson, exactEvidence.beforeJson);
      expect(appliedJournal.afterJson, exactEvidence.afterJson);
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
      final undone = (await f.setup.undo(
        original: updated,
        isCurrent: f.isCurrent,
      ))!;
      expect(undone.status, SupportMutationStatus.undone);
      expect(undone.before, updated.after);
      expect(undone.after, expected.view);
      expect(await f.row(created.connectionId), before);
      final undoneJournal = (await f.support.getMutationById(
        updated.journalId,
      ))!;
      expect(undoneJournal.beforeJson, exactEvidence.beforeJson);
      expect(undoneJournal.afterJson, exactEvidence.afterJson);
      expect(
        await f.setup.undo(original: updated, isCurrent: f.isCurrent),
        isNull,
      );
      expect(f.storage.operations, isNot(contains('delete')));
    },
  );

  providerRepoTest(
    'foreign repo/DB and restarted observations do not gain ownership',
    (f) async {
      final draft = f.draft();
      await f.create(draft);
      final observed = (await f.api.inspectKeyless(draft.view.connectionId))!;
      expect(
        f.api.sameKeylessObservation(
          observed,
          (await f.api.inspectKeyless(draft.view.connectionId))!,
        ),
        isTrue,
      );
      final other = ApiConfigRepo(f.db, keylessMutations: f.native);
      expect(
        other.sameKeylessObservation(
          observed,
          (await other.inspectKeyless(draft.view.connectionId))!,
        ),
        isFalse,
      );
      expect(
        await other.updateKeyless(
          expected: observed,
          patch: f.patch(),
          isCurrent: f.isCurrent,
        ),
        isNull,
      );
      final restarted = (await other.inspectKeyless(draft.view.connectionId))!;
      expect(restarted.nativeOwned, isFalse);
      expect(
        await other.updateKeyless(
          expected: restarted,
          patch: f.patch(),
          isCurrent: f.isCurrent,
        ),
        isNull,
      );
      final anotherDb = ProviderRepoFixture();
      try {
        await anotherDb.seed();
        expect(
          () => SupportProviderSetupRepo(
            db: f.db,
            apiRepo: anotherDb.api,
            supportRepo: f.support,
          ),
          throwsArgumentError,
        );
        expect(
          () => SupportProviderSetupRepo(
            db: f.db,
            apiRepo: f.api,
            supportRepo: anotherDb.support,
          ),
          throwsArgumentError,
        );
        expect(
          await anotherDb.api.updateKeyless(
            expected: observed,
            patch: f.patch(),
            isCurrent: anotherDb.isCurrent,
          ),
          isNull,
        );
      } finally {
        anotherDb.clearHooks();
        await anotherDb.db.close();
      }
    },
  );

  for (final edit in ['put', 'putFromMap', 'delete-recreate']) {
    providerRepoTest(
      '$edit ordinary same-content ABA retires native update authority',
      (f) async {
        final draft = f.draft();
        await f.create(draft);
        final observed = (await f.api.inspectKeyless(draft.view.connectionId))!;
        final legacy = (await f.api.getById(draft.view.connectionId))!;
        if (edit == 'delete-recreate') {
          await f.api.delete(draft.view.connectionId);
        }
        if (edit == 'putFromMap') {
          await f.api.putFromMap(legacy.toJson());
        } else {
          await f.api.put(legacy);
        }
        final before = await f.snapshot();
        expect(await f.update(observed, f.patch()), isNull);
        expect(await f.snapshot(), before);
        expect(
          (await f.api.inspectKeyless(draft.view.connectionId))!.nativeOwned,
          isFalse,
        );
      },
    );
  }

  for (final unsafe in [
    const ApiConfigsCompanion(apiKey: Value(ProviderRepoFixture.secretCanary)),
    const ApiConfigsCompanion(
      embeddingApiKey: Value(ProviderRepoFixture.secretCanary),
    ),
    const ApiConfigsCompanion(embeddingEnabled: Value(true)),
    const ApiConfigsCompanion(embeddingUseSame: Value(true)),
    const ApiConfigsCompanion(
      embeddingLlmPresetId: Value('synthetic-reference'),
    ),
    const ApiConfigsCompanion(
      extraRequestParametersJson: Value('[{"enabled":false}]'),
    ),
    const ApiConfigsCompanion(mode: Value('embedding')),
    const ApiConfigsCompanion(
      endpoint: Value(
        'https://synthetic.invalid/v1/chat/completions?key=CANARY',
      ),
    ),
  ]) {
    providerRepoTest(
      'stored unsafe field shape has no keyless observation ${unsafe.toColumns(false).keys}',
      (f) async {
        final draft = f.draft();
        await f.create(draft);
        await f.change(draft.view.connectionId, unsafe);
        expect(await f.api.inspectKeyless(draft.view.connectionId), isNull);
      },
    );
  }

  providerRepoTest(
    'missing native mutation bridge fails closed without DB/vault effect',
    (f) async {
      final noBridge = ApiConfigRepo(f.db);
      final before = await f.snapshot();
      expect(
        await noBridge.createKeyless(draft: f.draft(), isCurrent: f.isCurrent),
        isNull,
      );
      expect(await f.snapshot(), before);
    },
  );

  providerRepoTest(
    'invalid native values reject with fixed errors, not source canaries',
    (f) async {
      for (final endpoint in [
        'https://user:${ProviderRepoFixture.secretCanary}@synthetic.invalid/v1/chat/completions',
        'https://synthetic.invalid/v1/chat/completions?key=${ProviderRepoFixture.secretCanary}',
        'https://synthetic.invalid/%2e%2e/v1/chat/completions',
      ]) {
        Object? error;
        try {
          KeylessApiConfigDraft(
            nativeId: NativeKeylessConnectionId.generate(),
            displayName: ProviderRepoFixture.nameCanary,
            providerId: 'custom_chat_completion',
            protocol: 'custom_chat_completion',
            endpoint: endpoint,
            model: 'synthetic-model',
            maxTokens: 512,
            contextSize: 4096,
            temperature: 0.7,
          );
        } catch (caught) {
          error = caught;
        }
        expect(error, isA<FormatException>());
        expect('$error', isNot(contains(ProviderRepoFixture.secretCanary)));
        expect('$error', isNot(contains(ProviderRepoFixture.nameCanary)));
      }
    },
  );
}
