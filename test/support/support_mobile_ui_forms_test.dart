import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_action_strip.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_composer_bar.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_model_prompt_preview_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_model_selection_form.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_user_message_editor.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';
import 'package:glaze_flutter/shared/widgets/glaze_bottom_sheet.dart';
import 'package:glaze_flutter/shared/widgets/menu_group.dart';

import 'helpers/support_prompt_preview_fixture.dart';

Finder _key(String value) => find.byKey(ValueKey(value));
void _viewport(WidgetTester tester, double width) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 844);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
}

void main() {
  for (final width in [320.0, 390.0]) {
    testWidgets(
      'mobile $width original editor result survives IME with pinned Save',
      (tester) async {
        _viewport(tester, width);
        final fixture = SupportPromptPreviewFixture();
        final results = <String?>[];
        await fixture.run(tester, () async {
          await tester.pumpWidget(
            fixture.host(
              Builder(
                builder: (context) => TextButton(
                  key: const ValueKey('open_editor'),
                  onPressed: () => showSupportUserMessageEditor(
                    context,
                    initialText: 'SYNTHETIC-ORIGINAL',
                    isCurrent: () => true,
                  ).then(results.add),
                  child: const Text('Open editor'),
                ),
              ),
              scale: 1.6,
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(_key('open_editor'));
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<GlazeActionButton>(_key('support_message_edit_save'))
                .onTap,
            isNull,
          );
          final field = find.descendant(
            of: _key('support_message_edit_field'),
            matching: find.byType(TextField),
          );
          await tester.enterText(field, 'SYNTHETIC-EDITED');
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          await tester.pumpAndSettle();
          expect(
            tester.getRect(_key('support_message_edit_save')).bottom,
            lessThanOrEqualTo(544),
          );
          expect(
            find.ancestor(
              of: _key('support_message_edit_save'),
              matching: find.byType(SingleChildScrollView),
            ),
            findsNothing,
          );
          await tester.tap(_key('support_message_edit_save'));
          await tester.pumpAndSettle();
          expect(results, ['SYNTHETIC-EDITED']);
        });
      },
    );
    testWidgets(
      'mobile $width composer: real callbacks, draft/IME, busy and live Stop',
      (tester) async {
        _viewport(tester, width);
        final fixture = SupportPromptPreviewFixture();
        final controller = TextEditingController();
        final pending = Completer<bool>();
        var sends = 0, stops = 0;
        await fixture.run(tester, () async {
          await tester.pumpWidget(
            fixture.host(
              Scaffold(
                body: Column(
                  children: [
                    const Expanded(child: SizedBox()),
                    SupportComposerBar(
                      useActionDrawer: true,
                      controller: controller,
                      onSend: (_) {
                        sends++;
                        return pending.future;
                      },
                      onLocalHelp: (_) async => false,
                      onCompact: null,
                      onStop: () => stops++,
                    ),
                  ],
                ),
              ),
              scale: 1.6,
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<IconButton>(_key('support_composer_send_btn'))
                .onPressed,
            isNull,
          );
          final field = find.descendant(
            of: _key('support_composer_input'),
            matching: find.byType(TextField),
          );
          await tester.enterText(field, 'SYNTHETIC-DRAFT');
          controller.value = controller.value.copyWith(
            composing: const TextRange(start: 0, end: 2),
          );
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          expect(sends, 0); // active IME composition never becomes a send
          controller.value = controller.value.copyWith(
            composing: TextRange.empty,
          );
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          await tester.pumpAndSettle();
          await tester.tap(_key('support_drawer_toggle'));
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<SupportActionTile>(_key('support_composer_compact_btn'))
                .onTap,
            isNull,
          );
          expect(
            tester.getRect(_key('support_composer_send_btn')).bottom,
            lessThanOrEqualTo(544),
          );
          await tester.tap(_key('support_composer_send_btn'));
          await tester.pump();
          expect(sends, 1);
          expect(controller.text, 'SYNTHETIC-DRAFT'); // no optimistic clear
          expect(
            tester
                .widget<IconButton>(_key('support_composer_send_btn'))
                .onPressed,
            isNull,
          );
          expect(
            tester
                .widget<IconButton>(_key('support_composer_stop_btn'))
                .onPressed,
            isNotNull,
          );
          await tester.tap(_key('support_composer_stop_btn'));
          expect(stops, 1);
          controller.text = 'SYNTHETIC-NEWER-DRAFT';
          pending.complete(true);
          await tester.pumpAndSettle();
          expect(controller.text, 'SYNTHETIC-NEWER-DRAFT');
          expect(sends, 1);
        });
        controller.dispose();
      },
    );

    testWidgets(
      'mobile $width model picker: loading, open and actual selected draft',
      (tester) async {
        _viewport(tester, width);
        final fixture = SupportPromptPreviewFixture();
        final models = Completer<List<String>>();
        final selected = <String?>[];
        await fixture.run(tester, () async {
          await tester.pumpWidget(
            fixture.host(
              Builder(
                builder: (context) => Center(
                  child: TextButton(
                    key: const ValueKey('open_models'),
                    onPressed: () => GlazeBottomSheet.show<void>(
                      context,
                      title: 'Модель Астории',
                      child: SupportModelSelectionForm(
                        initialModel: 'synthetic-first',
                        models: const [],
                        loadModels:
                            ({required isCurrent, required cancelToken}) =>
                                models.future,
                        isCurrent: () => true,
                        onSelect: selected.add,
                      ),
                    ),
                    child: const Text('Open model picker'),
                  ),
                ),
              ),
              scale: 1.6,
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(_key('open_models'));
          await tester.pumpAndSettle();
          expect(find.text('Загрузка моделей…'), findsOneWidget);
          expect(selected, isEmpty);
          models.complete(['synthetic-first', 'synthetic-last']);
          await tester.pumpAndSettle();
          final dropdown = _key('support_model_dropdown');
          final originalScroll = Scrollable.of(tester.element(dropdown));
          expect(originalScroll.widget.axisDirection, AxisDirection.down);
          await Scrollable.ensureVisible(
            tester.element(dropdown),
            alignment: .5,
          );
          await tester.pumpAndSettle();
          expect(dropdown.hitTestable(), findsOneWidget);
          await tester.tap(dropdown);
          await tester.pumpAndSettle();
          expect(_key('support_model_option_synthetic-first'), findsOneWidget);
          await Scrollable.ensureVisible(
            tester.element(_key('support_model_option_synthetic-last')),
            alignment: .5,
          );
          await tester.pumpAndSettle();
          expect(
            Scrollable.of(
              tester.element(_key('support_model_option_synthetic-last')),
            ),
            same(originalScroll),
          );
          expect(
            _key('support_model_option_synthetic-last').hitTestable(),
            findsOneWidget,
          );
          await tester.tap(_key('support_model_option_synthetic-last'));
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<MenuSelectorItem>(_key('support_model_dropdown'))
                .currentValue,
            'synthetic-last',
          );
          expect(selected, isEmpty); // a draft choice is not a save/permission
          final manual = find.descendant(
            of: _key('support_model_manual_id'),
            matching: find.byType(TextField),
          );
          await Scrollable.ensureVisible(tester.element(manual), alignment: .5);
          await tester.pumpAndSettle();
          expect(Scrollable.of(tester.element(manual)), same(originalScroll));
          expect(manual.hitTestable(), findsOneWidget);
          await tester.tap(manual);
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          await tester.pumpAndSettle();
          await Scrollable.ensureVisible(tester.element(manual), alignment: .5);
          await tester.pumpAndSettle();
          expect(manual.hitTestable(), findsOneWidget);
          expect(tester.getRect(manual).bottom, lessThanOrEqualTo(544));
          expect(selected, isEmpty);
        });
      },
    );

    testWidgets(
      'mobile $width passive prompt preview pins once-only original decisions',
      (tester) async {
        _viewport(tester, width);
        final fixture = SupportPromptPreviewFixture();
        final decisions = <bool>[];
        bool current() => true;
        final isCurrent = current;
        final ValueChanged<bool> onDecision = decisions.add;
        final values = SupportPromptPreviewValues(
          originLabel: 'preview.example.invalid',
          operationLabel: 'Synthetic text',
          modelLabel: 'Synthetic model',
          gameMessageCount: 0,
          supportMessageCount: 0,
          sections: [
            for (var i = 0; i < 10; i++)
              SupportPromptPreviewSection(
                role: SupportPromptPreviewRole.user,
                text: 'SYNTHETIC-SECTION-$i\n' * 6,
              ),
          ],
        );
        await fixture.run(tester, () async {
          await tester.pumpWidget(
            fixture.host(
              Builder(
                builder: (context) => TextButton(
                  key: const ValueKey('open_preview'),
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    backgroundColor: Colors.transparent,
                    builder: (_) => SupportModelPromptPreviewSheet(
                      values: values,
                      isCurrent: isCurrent,
                      onDecision: onDecision,
                    ),
                  ),
                  child: const Text('Open preview'),
                ),
              ),
              scale: 1.6,
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(_key('open_preview'));
          await tester.pumpAndSettle();
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          await tester.pumpAndSettle();
          final sheet = find.byType(SupportModelPromptPreviewSheet);
          expect(ModalRoute.of(tester.element(sheet))!.isCurrent, isTrue);
          final list = find.descendant(
            of: sheet,
            matching: _key('support_prompt_preview_scroll'),
          );
          expect(list, findsOneWidget);
          final initialScroll = find.descendant(
            of: list,
            matching: find.byType(Scrollable),
          );
          expect(initialScroll, findsOneWidget);
          final outerElement = tester.element(initialScroll);
          // Lazy SelectableText sections later add their own Scrollables. Keep
          // this original outer element, never reselect all nested scroll views.
          final scroll = find.byElementPredicate(
            (element) => identical(element, outerElement),
          );
          final original = tester.state<ScrollableState>(scroll);
          expect(original.widget.axisDirection, AxisDirection.down);
          expect(
            tester.element(
              find.ancestor(of: scroll, matching: find.byType(ListView)),
            ),
            same(tester.element(list)),
          );
          expect(
            tester.widget<ListView>(list).childrenDelegate.estimatedChildCount,
            isNotNull,
          );
          final lastSection = find.descendant(
            of: list,
            matching: _key('support_prompt_preview_section_9'),
          );
          // Search the original finite list, not a fixed count of 200px drags.
          // Both drag moves stay within its actual IME-clipped viewport.
          while (lastSection.evaluate().isEmpty) {
            final position = original.position;
            expect(position.hasContentDimensions, isTrue);
            expect(position.maxScrollExtent.isFinite, isTrue);
            final before = position.pixels;
            final remaining = position.maxScrollExtent - before;
            if (remaining <= 0) break;
            final visible = tester
                .getRect(scroll)
                .intersect(Offset.zero & Size(width, 544));
            final room = visible.height / 2 - kDragSlopDefault;
            expect(room, greaterThan(0));
            expect(
              tester
                  .hitTestOnBinding(visible.center)
                  .path
                  .any(
                    (entry) =>
                        identical(entry.target, tester.renderObject(scroll)),
                  ),
              isTrue,
            );
            final travel = remaining.clamp(0, room).toDouble();
            await tester.dragFrom(
              visible.center,
              Offset(0, -travel - kDragSlopDefault),
            );
            await tester.pumpAndSettle();
            expect(tester.state<ScrollableState>(scroll), same(original));
            expect(original.position.pixels, greaterThan(before));
          }
          expect(lastSection, findsOneWidget);
          expect(Scrollable.of(tester.element(lastSection)), same(original));
          await Scrollable.ensureVisible(tester.element(lastSection));
          await tester.pumpAndSettle();
          expect(tester.state<ScrollableState>(scroll), same(original));
          final viewport = tester.getRect(scroll);
          expect(
            tester.getRect(lastSection).top,
            inInclusiveRange(viewport.top, viewport.bottom),
          );
          expect(
            _key('support_prompt_preview_confirm').hitTestable(),
            findsOneWidget,
          );
          expect(
            find.ancestor(
              of: _key('support_prompt_preview_confirm'),
              matching: find.byType(ListView),
            ),
            findsNothing,
          );
          expect(
            tester.getRect(_key('support_prompt_preview_cancel')).bottom,
            lessThanOrEqualTo(544),
          );
          await tester.tap(_key('support_prompt_preview_confirm'));
          await tester.pump();
          expect(decisions, [true]);
          expect(
            _key('support_prompt_preview_confirm').hitTestable(),
            findsOneWidget,
          );
          // No second native callback is fabricated; the real once gate disables it.
          await tester.tap(_key('support_prompt_preview_confirm'));
          expect(decisions, [true]);
        });
      },
    );
  }
}
