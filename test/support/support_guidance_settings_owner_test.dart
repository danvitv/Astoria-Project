import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/shared/widgets/menu_group.dart';

import 'support_guidance_screen_fixture.dart';

Map<String, Object?> _values(SupportAssistantSettings s) => {
  'mode': s.mode,
  'api': s.apiConfigId,
  'model': s.modelId,
  'temperature': s.temperature,
  'tokens': s.maxTokens,
  'reasoning': s.reasoningEffort,
  'dcp': s.dcpCompressionEnabled,
};

Future<Map<String, Object?>> _saved(
  WidgetTester tester,
  GuidanceScreenFixture f,
  String id,
) async => _values(
  await f.action(
    tester,
    () => f.container.read(supportSessionStoreProvider).settingsFor(id),
  ),
);

void main() {
  for (final returnToOriginal in [false, true]) {
    guidanceScreenTest(
      'original focused model confirm cannot adopt ${returnToOriginal ? 'A-B-A' : 'B'}',
      (tester, f) async {
        final a = await _saved(tester, f, GuidanceScreenFixture.session);
        final b = await _saved(tester, f, GuidanceScreenFixture.other);
        final lifetime = f.runtime.lifetime;
        await f.tapKey(tester, 'support_guidance_model');
        await f.tapKey(tester, 'support_model_selector');
        final field = find.byType(TextField);
        await f.reveal(tester, field);
        await f.turns.real(
          tester,
          () => tester.enterText(field, 'must-not-adopt-replacement'),
        );
        await tester.pump();
        final save = find.ancestor(
          of: find.text('Сохранить идентификатор'),
          matching: find.byType(MenuItem),
        );
        final retained = tester.widget<MenuItem>(save).onTap;

        await f.action(tester, () async {
          f.workspace.selectSession(GuidanceScreenFixture.other);
          await f.workspace.refresh();
          if (returnToOriginal) {
            f.workspace.selectSession(GuidanceScreenFixture.session);
            await f.workspace.refresh();
          }
        });
        await f.idle(tester);
        expect(f.runtime.lifetime, isNot(lifetime));
        // Retain the exact original native confirm, not a new current-B form.
        await f.turns.real(tester, () async => retained());
        await tester.pump();
        await f.idle(tester);
        expect(await _saved(tester, f, GuidanceScreenFixture.session), a);
        expect(await _saved(tester, f, GuidanceScreenFixture.other), b);
        expect(await f.messageCount(tester), 0);
        f.noReadersOrWire();
        await f.closeTop(tester);
        await f.closeTop(tester);
      },
      screen: false,
    );
  }

  guidanceScreenTest(
    'closed original model modal cannot confirm while session remains A',
    (tester, f) async {
      final before = await _saved(tester, f, GuidanceScreenFixture.session);
      await f.tapKey(tester, 'support_guidance_model');
      await f.tapKey(tester, 'support_model_selector');
      final save = find.ancestor(
        of: find.text('Сохранить идентификатор'),
        matching: find.byType(MenuItem),
      );
      final retained = tester.widget<MenuItem>(save).onTap;
      await f.closeTop(tester);
      await f.turns.real(tester, () async => retained());
      await tester.pump();
      await f.idle(tester);
      expect(await _saved(tester, f, GuidanceScreenFixture.session), before);
      f.noReadersOrWire();
      await f.closeTop(tester);
    },
    screen: false,
  );

  guidanceScreenTest(
    'original display fence reaches every scalar/settings write',
    (tester, f) async {
      var displayed = true;
      final original = f.workspace.captureSettingsIntent(
        isOriginalUiCurrent: () => displayed,
      );
      expect(original?.isCurrent, isTrue);
      final before = await _saved(tester, f, GuidanceScreenFixture.session);
      displayed = false;
      final outcomes = await f.action(
        tester,
        () async => [
          await f.workspace.setMode(
            SupportAssistantMode.onboarding,
            intent: original,
          ),
          await f.workspace.selectConnection(
            guidanceProfile.connectionId,
            defaultModelId: guidanceProfile.model,
            intent: original,
          ),
          await f.workspace.selectModel('stale-model', intent: original),
          await f.workspace.setTemperature(1.4, intent: original),
          await f.workspace.setMaxTokens(8192, intent: original),
          await f.workspace.setReasoningEffort(
            SupportReasoningEffort.high,
            intent: original,
          ),
          await f.workspace.setDcpCompression(false, intent: original),
        ],
      );
      expect(outcomes, everyElement(isFalse));
      expect(await _saved(tester, f, GuidanceScreenFixture.session), before);
      f.noReadersOrWire();
    },
    screen: false,
  );
}
