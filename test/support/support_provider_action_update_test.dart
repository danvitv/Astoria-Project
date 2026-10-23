import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';

import 'support_provider_action_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  providerActionTest(
    'narrow update/conditional once Undo preserve every unrelated row field',
    (f) async {
      final original = f.intent();
      final created = (await f.create(original: original)).applied!;
      final id = created.value!.connectionId;
      await (f.db.update(
        f.db.apiConfigs,
      )..where((t) => t.configId.equals(id))).write(
        const ApiConfigsCompanion(
          topP: Value(0.42),
          topK: Value(23),
          reasoningEffort: Value('high'),
          reasoningHistoryCount: Value(4),
          historyTrimTriggerPercent: Value(73),
          embeddingRequestsPerMinute: Value(7),
          firstChunkTimeoutMs: Value(12345),
          cacheControlTtl: Value('5min'),
        ),
      );
      final before = (await f.row(id))!;
      final choice = await f.choice(original);
      final review = (await f.service.prepareUpdate(
        choice,
        f.input(
          name: 'SYNTHETIC_RENAMED',
          model: 'synthetic-next',
          maxTokens: 1024,
          contextSize: 8192,
          temperature: 0.5,
        ),
      ))!;
      final approval = f.service.approve(review)!;
      final result = await f.service.execute(approval);
      expect(result.code, SupportProviderActionCode.applied);
      expect(
        await f.row(id),
        before.copyWith(
          name: 'SYNTHETIC_RENAMED',
          model: const Value('synthetic-next'),
          maxTokens: 1024,
          contextSize: 8192,
          temperature: 0.5,
        ),
      );
      expect(f.service.canUndo(result.applied!), isTrue);
      final undoReview = (await f.service.prepareUndo(
        original,
        result.applied!,
      ))!;
      expect(f.service.projectReview(undoReview)!.after!.name, before.name);
      final undone = await f.service.execute(f.service.approve(undoReview)!);
      expect(undone.code, SupportProviderActionCode.undone);
      expect(await f.row(id), before);
      expect(f.service.canUndo(result.applied!), isFalse);
      expect(await f.service.prepareUndo(original, result.applied!), isNull);
      expect(f.storage.operations, isNot(contains('delete')));
    },
  );
  providerActionTest(
    'routing/protocol/purpose/Gemini model cannot be narrow updates',
    (f) async {
      final original = f.intent();
      await f.create(
        original: original,
        draft: f.input(protocol: 'gemini'),
      );
      final choice = await f.choice(original);
      final before = await f.snapshotRows();
      expect(
        await f.service.prepareUpdate(
          choice,
          f.input(
            protocol: 'gemini',
            name: 'SYNTHETIC_NAME',
            model: 'other-model',
            endpoint: choice.value!.endpoint,
          ),
        ),
        isNull,
      );
      expect(await f.service.prepareUpdate(choice, f.input()), isNull);
      expect(
        await f.service.prepareUpdate(
          choice,
          f.input(
            protocol: 'gemini',
            name: 'SYNTHETIC_NAME',
            purpose: SupportProviderPurpose.studio,
          ),
        ),
        isNull,
      );
      expect(await f.snapshotRows(), before);
    },
  );
  providerActionTest(
    'ordinary identical-content mutation retires native observation and Undo',
    (f) async {
      final original = f.intent();
      final created = (await f.create(original: original)).applied!;
      final choice = await f.choice(original);
      final review = (await f.service.prepareUpdate(
        choice,
        f.input(name: 'SYNTHETIC_RENAME'),
      ))!;
      final result = await f.service.execute(f.service.approve(review)!);
      final saved = (await f.api.getById(created.value!.connectionId))!;
      await f.api.put(saved);
      expect(f.service.canUndo(result.applied!), isFalse);
      expect(
        await f.service.prepareUpdate(
          choice,
          f.input(name: 'SYNTHETIC_SECOND'),
        ),
        isNull,
      );
      expect(await f.service.prepareUndo(original, result.applied!), isNull);
    },
  );
  providerActionTest(
    'row conflict at native Undo settles conflict, never overwrites newer value',
    (f) async {
      final original = f.intent();
      await f.create(original: original);
      final review = (await f.service.prepareUpdate(
        await f.choice(original),
        f.input(name: 'SYNTHETIC_RENAME'),
      ))!;
      final result = await f.service.execute(f.service.approve(review)!);
      final undo = (await f.service.prepareUndo(original, result.applied!))!;
      final id = result.applied!.value!.connectionId;
      final approval = f.service.approve(undo)!;
      // Synthetic competing write bypasses observer to exercise full DB CAS.
      await (f.db.update(f.db.apiConfigs)..where((t) => t.configId.equals(id)))
          .write(const ApiConfigsCompanion(name: Value('SYNTHETIC_FOREIGN')));
      final conflict = await f.service.execute(approval);
      expect(conflict.code, SupportProviderActionCode.undoConflict);
      expect((await f.row(id))!.name, 'SYNTHETIC_FOREIGN');
      expect(f.service.canUndo(result.applied!), isFalse);
      expect(f.storage.operations, isNot(contains('delete')));
    },
  );
  providerActionTest(
    'native key permits fresh name/limits only; no model rebind',
    (f) async {
      final original = f.intent();
      final created = (await f.create(original: original)).applied!;
      final id = created.value!.connectionId;
      await f.saveSyntheticNativeKey(id, ProviderActionFixture.secret);
      final choice = await f.choice(original);
      final changingModel = (await f.service.prepareUpdate(
        choice,
        f.input(name: 'SYNTHETIC_RENAME', model: 'synthetic-next'),
      ))!;
      expect(
        (await f.service.execute(f.service.approve(changingModel)!)).code,
        SupportProviderActionCode.refused,
      );
      final freshChoice = await f.choice(original);
      final safe = (await f.service.prepareUpdate(
        freshChoice,
        f.input(name: 'SYNTHETIC_RENAME', maxTokens: 1024),
      ))!;
      expect(
        (await f.service.execute(f.service.approve(safe)!)).code,
        SupportProviderActionCode.applied,
      );
      expect((await f.row(id))!.apiKey, '');
      expect((await f.row(id))!.model, 'synthetic-model');
      expect(f.storage.operations, isNot(contains('delete')));
    },
  );
  providerActionTest(
    'actual prepared restart permits NEW safe model update without restoring old custody',
    (f) async {
      final oldIntent = f.intent();
      final old = (await f.create(original: oldIntent)).applied!;
      final id = old.value!.connectionId;
      final before = (await f.row(id))!;
      final preparation = Map.of(f.storage.values);
      expect(
        preparation.keys.any((key) => key.contains('native_prepared')),
        isTrue,
      );
      expect(
        preparation.keys.any((key) => key.contains('native_llm')),
        isFalse,
      );
      f.restartNative();
      f.useRealMetadata = true;
      expect(old.value, isNull);
      expect(f.service.canUndo(old), isFalse);
      final original = f.intent();
      final choice = await f.choice(original);
      final readiness = (await f.service.projectReadiness(choice))!;
      expect(readiness.configurationSaved, isTrue);
      expect(readiness.credentialConfigured, isFalse);
      expect(readiness.characterCount, 0);
      expect(readiness.verification, SupportProviderVerification.notTested);
      final review = (await f.service.prepareUpdate(
        choice,
        f.input(name: 'SYNTHETIC_FRESH_PREPARED', model: 'synthetic-next'),
      ))!;
      final result = await f.service.execute(f.service.approve(review)!);
      expect(result.code, SupportProviderActionCode.applied);
      expect(
        await f.row(id),
        before.copyWith(
          name: 'SYNTHETIC_FRESH_PREPARED',
          model: const Value('synthetic-next'),
        ),
      );
      expect(f.service.canUndo(result.applied!), isTrue);
      expect(f.service.canUndo(old), isFalse);
      final undo = (await f.service.prepareUndo(original, result.applied!))!;
      expect(
        (await f.service.execute(f.service.approve(undo)!)).code,
        SupportProviderActionCode.undone,
      );
      expect(await f.row(id), before);
      expect(f.storage.values, preparation);
      expect(f.storage.operations, isNot(contains('delete')));
    },
  );
  providerActionTest(
    'restart supports fresh protected update, never old approval/Undo restoration',
    (f) async {
      final oldIntent = f.intent();
      final old = (await f.create(original: oldIntent)).applied!;
      final id = old.value!.connectionId;
      await f.saveSyntheticNativeKey(id, ProviderActionFixture.secret);
      f.restartNative();
      expect(old.value, isNull);
      expect(f.service.canUndo(old), isFalse);
      final original = f.intent();
      final choice = await f.choice(original);
      final review = (await f.service.prepareUpdate(
        choice,
        f.input(name: 'SYNTHETIC_NEW_SAFE_NAME', maxTokens: 1024),
      ))!;
      final result = await f.service.execute(f.service.approve(review)!);
      expect(result.code, SupportProviderActionCode.applied);
      expect(result.applied!.value!.name, 'SYNTHETIC_NEW_SAFE_NAME');
      expect(f.service.canUndo(result.applied!), isTrue);
      expect(f.service.canUndo(old), isFalse);
      expect(f.storage.operations, isNot(contains('delete')));
      expect((await f.row(id))!.apiKey, '');
    },
  );

  for (final field in [
    'apiKey',
    'embeddingApiKey',
    'embeddingEnabled',
    'extraRequestParametersJson',
    'stream',
  ]) {
    providerActionTest(
      'unsafe saved $field is not an editable safe observation',
      (f) async {
        final original = f.intent();
        final applied = (await f.create(original: original)).applied!;
        final id = applied.value!.connectionId;
        final patch = switch (field) {
          'apiKey' => const ApiConfigsCompanion(
            apiKey: Value(ProviderActionFixture.secret),
          ),
          'embeddingApiKey' => const ApiConfigsCompanion(
            embeddingApiKey: Value(ProviderActionFixture.secret),
          ),
          'embeddingEnabled' => const ApiConfigsCompanion(
            embeddingEnabled: Value(true),
          ),
          'stream' => const ApiConfigsCompanion(stream: Value(false)),
          _ => const ApiConfigsCompanion(
            extraRequestParametersJson: Value('[{"enabled":false}]'),
          ),
        };
        await (f.db.update(
          f.db.apiConfigs,
        )..where((t) => t.configId.equals(id))).write(patch);
        final before = await f.snapshotRows();
        expect(
          (await f.service.observeConnections(
            original,
            SupportProviderPurpose.roleplay,
          ))!.choices,
          isEmpty,
        );
        expect(await f.snapshotRows(), before);
      },
    );
  }
}
