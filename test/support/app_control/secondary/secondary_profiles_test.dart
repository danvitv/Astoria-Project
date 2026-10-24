import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/studio_regex.dart';
import 'package:glaze_flutter/core/llm/transport/native_tool_types.dart';
import 'package:glaze_flutter/core/state/global_regex_provider.dart';
import 'package:glaze_flutter/core/state/studio_regex_provider.dart';
import 'package:glaze_flutter/features/extensions/providers/extension_presets_provider.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_provider.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/secondary/support_app_secondary_profiles_adapter.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_secondary_provider.dart';

import 'secondary_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SecondaryFixture fixture;
  setUp(() async => fixture = await SecondaryFixture.create());
  tearDown(() async => fixture.close());

  test(
    'original extension read cannot publish after its native owner is disposed',
    () async {
      final original = fixture.container.read(
        extensionPresetsProvider.notifier,
      );
      final pendingRead = original.refresh();
      // Dispose during the actual SQLite read, not after waiting for loading.
      fixture.disposeNativeOwners();
      expect(original.mounted, false);
      await pendingRead;
      expect(original.mounted, false);
      expect(fixture.prefs.getKeys(), isEmpty);
    },
  );

  test(
    'unsettled actual native preference owners return unavailable, not invented state',
    () async {
      await fixture.close();
      final gate = Completer<SharedPreferences>();
      fixture = await SecondaryFixture.create(preferencesReady: gate.future);
      final registry = fixture.registry();
      final result = await registry.execute(
        secondaryCall('astoria_secondary_profiles_read', {'domain': 'image'}),
        fixture.context(),
      );
      expect(result.content['code'], 'unavailable');
      expect(result.content['effect'], 'none');
      gate.complete(fixture.prefs);
      await fixture.container.read(globalRegexProvider.future);
      await fixture.container.read(studioRegexProvider.future);
      await fixture.container.read(imageGenSettingsProvider.future);
    },
  );

  test(
    'retained projection conflicts with later actual owner state without publishing body',
    () async {
      final adapters = fixture.container.read(
        supportAppControlSecondaryAdaptersProvider,
      );
      await fixture.container.read(globalRegexProvider.future);
      await fixture.container.read(studioRegexProvider.future);
      await fixture.container.read(imageGenSettingsProvider.future);
      final adapter = adapters
          .whereType<SupportAppSecondaryProfilesAdapter>()
          .single;
      final context = fixture.context();
      final prepared = await adapter.prepare(
        'astoria_secondary_profiles_read',
        {'domain': 'globalRegex'},
        context,
      );
      await fixture.container
          .read(globalRegexProvider.notifier)
          .addRegex(
            const PresetRegex(
              id: secondaryPrivateCanary,
              name: secondaryPrivateCanary,
              regex: secondaryPrivateCanary,
            ),
          );
      expect(prepared!.observationIsCurrent(), false);
      final result = await prepared.execute(() => context.current);
      expect(result.code.name, 'stale');
      expect(result.effect.name, 'none');
      expect(result.data, isEmpty);
    },
  );

  test(
    'original regex/image notifiers backed by synthetic preferences expose counts only',
    () async {
      final registry = fixture.registry();
      await fixture.container.read(globalRegexProvider.future);
      await fixture.container.read(studioRegexProvider.future);
      await fixture.container.read(imageGenSettingsProvider.future);
      const privateScript = PresetRegex(
        id: secondaryPrivateCanary,
        name: secondaryPrivateCanary,
        regex: secondaryPrivateCanary,
        replacement: secondaryPrivateCanary,
      );
      await fixture.container
          .read(globalRegexProvider.notifier)
          .addRegex(privateScript);
      await fixture.container
          .read(studioRegexProvider.notifier)
          .addRegex(
            const StudioRegex(
              script: privateScript,
              stages: {'final', 'cleaner'},
            ),
          );
      await fixture.container
          .read(imageGenSettingsProvider.notifier)
          .save(
            const ImageGenSettings(
              enabled: true,
              concurrentGeneration: true,
              customApiKey: secondaryPrivateCanary,
              customEndpoint: secondaryPrivateCanary,
              customModel: secondaryPrivateCanary,
              refInstruction: secondaryPrivateCanary,
              references: [
                ReferenceImage(
                  name: secondaryPrivateCanary,
                  imageData: secondaryPrivateCanary,
                  description: secondaryPrivateCanary,
                ),
              ],
              styles: [
                ImageStyle(
                  id: secondaryPrivateCanary,
                  name: secondaryPrivateCanary,
                  value: secondaryPrivateCanary,
                ),
              ],
              comfyui: ComfyUiImageSettings(
                workflows: [
                  ComfyUiWorkflow(
                    id: secondaryPrivateCanary,
                    name: secondaryPrivateCanary,
                    json: secondaryPrivateCanary,
                  ),
                ],
              ),
            ),
          );
      final before = {
        for (final key in fixture.prefs.getKeys()) key: fixture.prefs.get(key),
      };
      final context = fixture.context();
      for (final domain in ['globalRegex', 'studioRegex', 'image']) {
        final result = await registry.execute(
          secondaryCall('astoria_secondary_profiles_read', {'domain': domain}),
          context,
        );
        expect(result.content['code'], 'completed');
        expect(result.content['effect'], 'none');
        expect(
          jsonEncode(result.content),
          isNot(contains(secondaryPrivateCanary)),
        );
        final data = secondaryData(result);
        expect(data['activationControlAvailable'], false);
        expect(data['generationAvailable'], false);
        if (domain == 'image') {
          expect(data['referenceCount'], 1);
          expect(data['styleCount'], 1);
          expect(data['workflowCount'], 1);
          expect(data['enabled'], true);
          expect(data['credentialValidity'], 'unknown');
        } else {
          expect(data['scriptCount'], 1);
          expect(data['enabledCount'], 1);
          expect(data['stageBindingCount'], domain == 'studioRegex' ? 2 : 0);
        }
      }
      expect({
        for (final key in fixture.prefs.getKeys()) key: fixture.prefs.get(key),
      }, before);
    },
  );

  test(
    'strict fields, Cancel and absent activation/generation definitions do not mutate',
    () async {
      final registry = fixture.registry();
      await fixture.container.read(globalRegexProvider.future);
      await fixture.container.read(studioRegexProvider.future);
      await fixture.container.read(imageGenSettingsProvider.future);
      final before = {
        for (final key in fixture.prefs.getKeys()) key: fixture.prefs.get(key),
      };
      final native = SyntheticOriginalConfirmation();
      final context = fixture.context(confirmation: native);
      // Native-denied credential fields never reach the application registry.
      expect(
        () => secondaryCall('astoria_secondary_profiles_read', {
          'domain': 'image',
          'apiKey': 'owned-model-key',
        }),
        throwsA(
          isA<NativeToolException>().having(
            (error) => error.reason,
            'reason',
            NativeToolReason.denied,
          ),
        ),
      );
      // Benign unknown fields do reach the registry and must fail its contract.
      for (final args in [
        {'domain': 'image', 'paidApproved': true},
        {'domain': 'globalRegex', 'pattern': secondaryPrivateCanary},
        {'domain': 'image', 'path': 'owned-model-path'},
        {'domain': 'image', 'unexpectedField': true},
        {'domain': 'not-an-admitted-domain'},
      ]) {
        final result = await registry.execute(
          secondaryCall('astoria_secondary_profiles_read', args),
          context,
        );
        expect(result.content['code'], 'invalidArguments');
        expect(result.content['effect'], 'none');
        expect(secondaryData(result), isEmpty);
      }
      final cancelled = fixture.context()..cancelToken.cancel();
      final result = await registry.execute(
        secondaryCall('astoria_secondary_profiles_read', {'domain': 'image'}),
        cancelled,
      );
      expect(result.content['code'], 'cancelled');
      expect(result.content['effect'], 'none');
      expect(secondaryData(result), isEmpty);
      for (final name in [
        'astoria_regex_enable',
        'astoria_image_generate',
        'astoria_gallery_delete',
      ]) {
        final refused = await registry.execute(secondaryCall(name), context);
        expect(refused.content['code'], 'unknownAction');
        expect(refused.content['effect'], 'none');
      }
      expect(native.calls, 0);
      expect({
        for (final key in fixture.prefs.getKeys()) key: fixture.prefs.get(key),
      }, before);
    },
  );
}
