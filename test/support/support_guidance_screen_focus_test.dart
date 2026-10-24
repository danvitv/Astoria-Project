import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_guidance_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_settings_panel.dart';
import 'package:glaze_flutter/shared/widgets/glaze_switch.dart';
import 'package:glaze_flutter/shared/widgets/menu_group.dart';

import 'support_guidance_screen_fixture.dart';

const _controls = {
  SupportGuidanceTarget.mode: 'support_settings_mode',
  SupportGuidanceTarget.temperature: 'support_settings_temperature',
  SupportGuidanceTarget.maxTokens: 'support_settings_max_tokens',
  SupportGuidanceTarget.reasoning: 'support_reasoning_selector',
  SupportGuidanceTarget.dcp: 'support_settings_dcp',
  SupportGuidanceTarget.model: 'support_model_selector',
  SupportGuidanceTarget.connection: 'support_connection_selector',
};

Map<String, Object?> _values(SupportAssistantSettings settings) => {
  'mode': settings.mode,
  'connection': settings.apiConfigId,
  'model': settings.modelId,
  'temperature': settings.temperature,
  'maxTokens': settings.maxTokens,
  'reasoning': settings.reasoningEffort,
  'dcp': settings.dcpCompressionEnabled,
};

void main() {
  guidanceScreenTest(
    'typed mode/scalar cards isolate controls; profile/model pickers persist through actual notifier without resolution',
    (tester, f) async {
      for (final entry in _controls.entries) {
        await f.tapKey(tester, 'support_guidance_${entry.key.name}');
        expect(
          tester
              .widget<SupportGuidanceSheet>(find.byType(SupportGuidanceSheet))
              .target,
          entry.key,
        );
        final panel = find.byType(SupportSettingsPanel);
        expect(panel, findsOneWidget);
        final chosen = find.descendant(
          of: panel,
          matching: find.byKey(ValueKey(entry.value)),
        );
        await f.reveal(tester, chosen);
        for (final unrelated in _controls.values.where(
          (key) => key != entry.value,
        )) {
          // A connection profile includes its paired model selector. Scalar,
          // reasoning, DCP and mode cards must not expose that broader form.
          if (entry.key == SupportGuidanceTarget.connection &&
              unrelated == 'support_model_selector') {
            continue;
          }
          expect(
            find.descendant(
              of: panel,
              matching: find.byKey(ValueKey(unrelated)),
            ),
            findsNothing,
            reason: '${entry.key.name} is not the entire settings menu.',
          );
        }
        expect(
          find.byKey(const ValueKey('support_privacy_group')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('support_panel_diag_action')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('support_panel_report_action')),
          findsNothing,
        );
        final before = await f.action(
          tester,
          () => f.container
              .read(supportSessionStoreProvider)
              .settingsFor(GuidanceScreenFixture.session),
        );
        switch (entry.key) {
          case SupportGuidanceTarget.mode:
            await f.tap(
              tester,
              find.descendant(
                of: chosen,
                matching: find.text(SupportAssistantMode.onboarding.shortLabel),
              ),
            );
          case SupportGuidanceTarget.connection:
            await f.tap(tester, chosen);
            await f.tap(tester, find.text(guidanceProfile.displayName).last);
          case SupportGuidanceTarget.model:
            await f.tap(tester, chosen);
            final field = find.byType(TextField);
            await f.reveal(tester, field);
            await f.turns.real(
              tester,
              () => tester.enterText(field, 'explicit-manual-model'),
            );
            await tester.pump();
            await f.tap(tester, find.text('Сохранить идентификатор'));
          case SupportGuidanceTarget.temperature:
            final range = tester.widget<MenuRangeItem>(chosen);
            final slider = find.descendant(
              of: chosen,
              matching: find.byType(Slider),
            );
            await f.reveal(tester, slider);
            final bounds = tester.getRect(slider);
            await f.turns.real(
              tester,
              () => tester.tapAt(
                Offset(bounds.left + bounds.width * 0.8, bounds.center.dy),
              ),
            );
            expect(range.value, before.temperature);
          case SupportGuidanceTarget.maxTokens:
            final input = find.descendant(
              of: chosen,
              matching: find.byType(TextField),
            );
            await f.turns.real(tester, () => tester.enterText(input, '131072'));
            await tester.pump();
            await f.turns.real(
              tester,
              () => tester.testTextInput.receiveAction(TextInputAction.done),
            );
          case SupportGuidanceTarget.reasoning:
            await f.tap(tester, chosen);
            await f.tap(
              tester,
              find.text(SupportReasoningEffort.high.label).last,
            );
          case SupportGuidanceTarget.dcp:
            expect(
              find.text(
                'Предпочтение сохраняется; runtime сжатия пока недоступен',
              ),
              findsOneWidget,
            );
            await f.tap(
              tester,
              find.descendant(of: chosen, matching: find.byType(GlazeSwitch)),
            );
          default:
            fail('Unexpected focused target');
        }
        await tester.pump();
        await f.idle(tester);
        final saved = (await f.action(
          tester,
          () => f.container
              .read(supportSessionStoreProvider)
              .settingsFor(GuidanceScreenFixture.session),
        ));
        switch (entry.key) {
          case SupportGuidanceTarget.mode:
            expect(saved.mode, SupportAssistantMode.onboarding);
          case SupportGuidanceTarget.connection:
            expect(saved.apiConfigId, guidanceProfile.connectionId);
            expect(saved.modelId, guidanceProfile.model);
          case SupportGuidanceTarget.model:
            expect(saved.modelId, 'explicit-manual-model');
          case SupportGuidanceTarget.temperature:
            expect(saved.temperature, isNot(before.temperature));
            expect(saved.maxTokens, before.maxTokens);
          case SupportGuidanceTarget.maxTokens:
            expect(saved.maxTokens, 131072);
            expect(saved.temperature, before.temperature);
          case SupportGuidanceTarget.reasoning:
            expect(saved.reasoningEffort, SupportReasoningEffort.high);
          case SupportGuidanceTarget.dcp:
            expect(saved.dcpCompressionEnabled, isFalse);
          default:
            fail('Unexpected focused target');
        }
        final changed = entry.key == SupportGuidanceTarget.connection
            ? {'connection', 'model'}
            : {entry.key.name};
        final unchangedBefore = _values(before)
          ..removeWhere((key, _) => changed.contains(key));
        final unchangedAfter = _values(saved)
          ..removeWhere((key, _) => changed.contains(key));
        expect(
          unchangedAfter,
          unchangedBefore,
          reason:
              'Actual notifier changes only the requested parameter/profile.',
        );
        expect((await f.saved(tester)).grants, isEmpty);
        expect(f.runtime.recipientConfirmed, isFalse);
        f.noReadersOrWire();
        await f.closeTop(tester);
      }
      expect(await f.messageCount(tester), 0);
    },
    screen: false,
  );
}
