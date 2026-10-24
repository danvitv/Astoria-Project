import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_output_token_field.dart';
import 'package:glaze_flutter/shared/widgets/menu_group.dart';

import 'support_guidance_screen_fixture.dart';

const _fieldKey = ValueKey('support_settings_max_tokens');

Map<String, Object?> _settings(SupportAssistantSettings s) => {
  'mode': s.mode,
  'connection': s.apiConfigId,
  'model': s.modelId,
  'temperature': s.temperature,
  'maxTokens': s.maxTokens,
  'reasoning': s.reasoningEffort,
  'dcp': s.dcpCompressionEnabled,
};

Future<SupportAssistantSettings> _saved(
  WidgetTester tester,
  GuidanceScreenFixture f, [
  String id = GuidanceScreenFixture.session,
]) => f.action(
  tester,
  () => f.container.read(supportSessionStoreProvider).settingsFor(id),
);

Finder _input() => find.descendant(
  of: find.byKey(_fieldKey),
  matching: find.byType(TextField),
);

Future<void> _edit(
  WidgetTester tester,
  GuidanceScreenFixture f,
  String text,
) async {
  await f.reveal(tester, _input());
  await f.turns.real(tester, () => tester.enterText(_input(), text));
  await tester.pump();
}

Future<void> _finish(WidgetTester tester, GuidanceScreenFixture f) async {
  // MenuFieldItem's TextField uses the default completion -> unfocus behavior.
  await f.turns.real(
    tester,
    () => tester.testTextInput.receiveAction(TextInputAction.done),
  );
  await tester.pump();
  await f.idle(tester);
  await tester.pump();
}

void main() {
  guidanceScreenTest(
    'one signed manual field persists -1 and large limits only on completion',
    (tester, f) async {
      final initial = await _saved(tester, f);
      final other = _settings(
        await _saved(tester, f, GuidanceScreenFixture.other),
      );
      await f.tapKey(tester, 'support_guidance_maxTokens');
      expect(find.byType(SupportOutputTokenField), findsOneWidget);
      expect(find.byType(MenuFieldItem), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byType(Slider), findsNothing);
      expect(find.byType(MenuSwitchItem), findsNothing);
      expect(find.byType(MenuSelectorItem), findsNothing);
      final input = tester.widget<TextField>(_input());
      expect(input.controller!.text, initial.maxTokens.toString());
      expect(
        input.keyboardType,
        const TextInputType.numberWithOptions(signed: true),
      );
      expect(
        find.text('-1 — не передавать лимит ответа модели.'),
        findsOneWidget,
      );
      for (final tokens in [-1, 131072, 8192, 1]) {
        final before = await _saved(tester, f);
        await _edit(tester, f, tokens.toString());
        expect(_settings(await _saved(tester, f)), _settings(before));
        await _finish(tester, f);
        final durable = await _saved(tester, f);
        expect(durable.maxTokens, tokens);
        expect(
          _settings(durable)..remove('maxTokens'),
          _settings(initial)..remove('maxTokens'),
        );
        expect(tester.widget<TextField>(_input()).controller!.text, '$tokens');
      }
      await f.closeTop(tester);
      await f.tapKey(tester, 'support_guidance_maxTokens');
      expect(tester.widget<TextField>(_input()).controller!.text, '1');
      expect(
        _settings(await _saved(tester, f, GuidanceScreenFixture.other)),
        other,
      );
      expect((await f.saved(tester)).grants, isEmpty);
      expect(f.runtime.recipientConfirmed, isFalse);
      expect(await f.messageCount(tester), 0);
      f.noReadersOrWire();
      await f.closeTop(tester);
    },
    screen: false,
  );

  guidanceScreenTest(
    'invalid text shows one fixed error and never persists or clamps',
    (tester, f) async {
      final before = _settings(await _saved(tester, f));
      await f.tapKey(tester, 'support_guidance_maxTokens');
      for (final text in [
        '0',
        '-2',
        '',
        'not-a-number',
        '1.5',
        '0x100',
        '2147483648',
        '999999999999999999999999999999999',
      ]) {
        final epoch = f.runtime.epoch;
        final owner = f.runtime.writeOwner;
        await _edit(tester, f, text);
        await _finish(tester, f);
        expect(
          find.text('Введи -1 или целое число от 1 до 2147483647.'),
          findsOneWidget,
        );
        expect(
          tester
              .widget<MenuFieldItem>(find.byType(MenuFieldItem))
              .helperIsError,
          isTrue,
        );
        expect(_settings(await _saved(tester, f)), before);
        expect(f.runtime.epoch, epoch);
        expect(f.runtime.writeOwner, owner);
      }
      // Correcting the same draft clears the error without another control.
      await _edit(tester, f, '-1');
      expect(
        find.text('Введи -1 или целое число от 1 до 2147483647.'),
        findsNothing,
      );
      await _finish(tester, f);
      expect((await _saved(tester, f)).maxTokens, -1);
      expect((await f.saved(tester)).grants, isEmpty);
      expect(await f.messageCount(tester), 0);
      f.noReadersOrWire();
      await f.closeTop(tester);
    },
    screen: false,
  );

  guidanceScreenTest(
    'invalid integer setter and store encoding refuse before any durable change',
    (tester, f) async {
      final before = _settings(await _saved(tester, f));
      final original = f.workspace.captureSettingsIntent();
      final epoch = f.runtime.epoch;
      final owner = f.runtime.writeOwner;
      for (final value in [0, -2, 0x80000000]) {
        final accepted = await f.action(
          tester,
          () => f.workspace.setMaxTokens(value, intent: original),
        );
        expect(accepted, isFalse);
        await f.action(tester, () async {
          await expectLater(
            f.container
                .read(supportSessionStoreProvider)
                .changeSettings(
                  GuidanceScreenFixture.session,
                  (settings) => settings.copyWith(maxTokens: value),
                ),
            throwsArgumentError,
          );
        });
        expect(_settings(await _saved(tester, f)), before);
        expect(f.runtime.epoch, epoch);
        expect(f.runtime.writeOwner, owner);
      }
      f.noReadersOrWire();
    },
    screen: false,
  );

  for (final replacement in ['B', 'ABA', 'closed']) {
    guidanceScreenTest(
      'original focused token draft cannot commit after $replacement',
      (tester, f) async {
        final a = _settings(await _saved(tester, f));
        final b = _settings(
          await _saved(tester, f, GuidanceScreenFixture.other),
        );
        await f.tapKey(tester, 'support_guidance_maxTokens');
        await _edit(tester, f, '-1');
        final originalWidget = tester.widget<SupportOutputTokenField>(
          find.byKey(_fieldKey),
        );
        final originalIntent = originalWidget.intent;
        expect(originalIntent?.isCurrent, isTrue);
        final originalFocus = tester
            .widget<Focus>(
              find
                  .descendant(
                    of: find.byKey(_fieldKey),
                    matching: find.byType(Focus),
                  )
                  .first,
            )
            .onFocusChange!;
        if (replacement == 'closed') {
          await f.closeTop(tester);
        } else {
          await f.action(tester, () async {
            f.workspace.selectSession(GuidanceScreenFixture.other);
            await f.workspace.refresh();
            if (replacement == 'ABA') {
              f.workspace.selectSession(GuidanceScreenFixture.session);
              await f.workspace.refresh();
            }
          });
          await tester.pump();
          await f.idle(tester);
        }
        expect(originalIntent?.isCurrent, isFalse);
        await f.turns.real(tester, () async => originalFocus(false));
        expect(
          await f.action(
            tester,
            () => originalWidget.notifier.setMaxTokens(
              -1,
              intent: originalIntent,
            ),
          ),
          isFalse,
        );
        await tester.pump();
        await f.idle(tester);
        expect(_settings(await _saved(tester, f)), a);
        expect(
          _settings(await _saved(tester, f, GuidanceScreenFixture.other)),
          b,
        );
        expect(await f.messageCount(tester), 0);
        f.noReadersOrWire();
        if (replacement != 'closed') await f.closeTop(tester);
      },
      screen: false,
    );
  }
}
