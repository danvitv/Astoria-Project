import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/native_provider_credentials.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/features/settings/api_list_provider.dart';

import 'support_provider_vertical_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  providerVerticalTest(
    'loaded empty picker publishes native create without selecting an ID',
    (f) async {
      expect(await f.container.read(apiListProvider.future), isEmpty);
      final selection = f.container.read(activeApiPresetIdProvider);
      final published = Completer<ApiConfig>();
      final sub = f.container.listen(apiListProvider, (_, next) {
        final list = next.value;
        if (list?.length == 1 && !published.isCompleted) {
          published.complete(list!.single);
        }
      });
      try {
        final binding = f.bind();
        final review = (await binding.prepare(f.input()))!;
        final actual = await binding.confirm(review)!;
        expect(actual.code, SupportProviderActionCode.applied);
        final cached = await published.future;
        expect(cached.id, actual.applied!.value!.connectionId);
        expect(cached.apiKey, isEmpty);
        expect(cached.embeddingApiKey, isEmpty);
        expect(f.container.read(activeApiPresetIdProvider), selection);
        expect(f.container.read(activeApiConfigProvider)!.id, cached.id);
        expect(f.requests, isEmpty);
      } finally {
        sub.close();
      }
    },
  );

  providerVerticalTest(
    'cached next-run limits and picker follow native update and exact Undo',
    (f) async {
      final binding = f.bind();
      final created = await binding.confirm(
        (await binding.prepare(f.input()))!,
      )!;
      final original = created.applied!;
      final key = (await binding.prepareKeyEntry(original))!;
      await key.submitNativeSecret('SYNTHETIC_PICKER_ONLY_KEY');
      final before = (await f.container.read(apiListProvider.future)).single;
      final selected = f.container.read(activeApiPresetIdProvider);
      final updated = Completer<ApiConfig>(), restored = Completer<ApiConfig>();
      var expectingUndo = false;
      final sub = f.container.listen(apiListProvider, (_, next) {
        final list = next.value;
        if (list?.length != 1) return;
        final row = list!.single;
        if (!expectingUndo &&
            row.name == 'Updated synthetic' &&
            !updated.isCompleted) {
          updated.complete(row);
        }
        if (expectingUndo && row.name == before.name && !restored.isCompleted) {
          restored.complete(row);
        }
      });
      try {
        final choice = (await binding.observe(
          SupportProviderPurpose.roleplay,
        ))!.choices.single;
        final review = (await binding.prepare(
          const SupportProviderSetupInput(
            purpose: SupportProviderPurpose.roleplay,
            name: 'Updated synthetic',
            protocol: 'openai',
            endpoint: 'https://api.openai.com/v1/chat/completions',
            model: 'synthetic-model',
            maxTokens: 2048,
            contextSize: 65536,
            temperature: 0.2,
          ),
          updating: choice,
        ))!;
        final applied = await binding.confirm(review)!;
        expect(applied.code, SupportProviderActionCode.applied);
        final current = await updated.future;
        expect(current.maxTokens, 2048);
        expect(current.contextSize, 65536);
        expect(current.temperature, 0.2);
        final stamp = f.native.sources.captureOriginalStamp();
        final prepared = await f.native.sources.prepare(
          originalStamp: stamp,
          configuration: (await f.container.read(
            apiListProvider.future,
          )).single,
          purpose: NativeProviderPurpose.roleplay,
          isCurrent: () => f.uiCurrent,
        );
        expect(prepared.configuration.maxTokens, 2048);
        expect(prepared.configuration.apiKey, isEmpty);
        expectingUndo = true;
        final undo = (await binding.prepareUndo(applied.applied!))!;
        expect(
          (await binding.confirm(undo)!).code,
          SupportProviderActionCode.undone,
        );
        final afterUndo = await restored.future;
        expect(afterUndo, before);
        expect(f.container.read(activeApiPresetIdProvider), selected);
        expect(f.requests, isEmpty);
      } finally {
        sub.close();
      }
    },
  );
}
