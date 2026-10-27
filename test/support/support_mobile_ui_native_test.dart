import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_provider_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_theme_controls.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_theme_sheet.dart';
import 'package:glaze_flutter/shared/widgets/sheet_view.dart';

import 'support_provider_screen_fixture.dart';
import 'support_theme_screen_helpers.dart' as theme;

Finder _key(String value) => find.byKey(ValueKey(value));

void _viewport(WidgetTester tester, double width) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 844);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
}

void _fixed(WidgetTester tester, Finder control) {
  expect(control.hitTestable(), findsOneWidget);
  expect(
    find.ancestor(of: control, matching: find.byType(ListView)),
    findsNothing,
  );
  final bounds = tester.getRect(control),
      sheet = tester.getRect(find.byType(SheetView));
  expect(bounds.left, greaterThanOrEqualTo(sheet.left));
  expect(bounds.right, lessThanOrEqualTo(sheet.right));
  expect(bounds.bottom, lessThanOrEqualTo(844 - tester.view.viewInsets.bottom));
  expect(bounds.height, greaterThanOrEqualTo(48));
}

void main() {
  for (final width in [320.0, 390.0]) {
    for (final brightness in Brightness.values) {
      providerScreenTest(
        'mobile $width $brightness provider: real form, keyboard, exact review',
        (tester, f) async {
          _viewport(tester, width);
          await f.mount(tester, textScale: 1.6, brightness: brightness);
          await f.tap(tester, 'support_provider_open');
          final original = f.controller(tester)!;
          await f.tap(tester, 'support_provider_mode_create');
          await f.tap(tester, 'support_provider_protocol');
          await f.reveal(tester, _key('support_provider_protocol_gemini'));
          await f.tap(tester, 'support_provider_protocol_openai');
          await f.text(
            tester,
            'support_provider_name',
            'Synthetic mobile provider',
          );
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          await tester.pump();
          await f.text(
            tester,
            'support_provider_model',
            'synthetic-mobile-model',
          );
          await f.text(tester, 'support_provider_temperature', '0.8');
          expect(
            tester.getRect(_key('support_provider_temperature')).bottom,
            lessThanOrEqualTo(544),
          );
          await f.tap(tester, 'support_provider_review');
          expect(f.controller(tester), same(original));
          expect(original.review, isNotNull);
          expect(
            original.binding.preview(original.review!)?.after?.model,
            'synthetic-mobile-model',
          );
          _fixed(tester, _key('support_provider_confirm'));
          await f.reveal(tester, find.text('synthetic-mobile-model').last);
          _fixed(tester, _key('support_provider_confirm'));
          expect(original.originalJob, isNull); // review is not Apply
          expect(f.root.requests, isEmpty);
          await f.tap(tester, 'support_provider_review_cancel');
          expect(original.review, isNull);
          expect(find.byType(SupportProviderSheet), findsOneWidget);
          await f.tap(tester, 'support_provider_cancel');
        },
      );

      testWidgets(
        'mobile $width $brightness theme: real choices and pinned original confirmation',
        (tester) async {
          _viewport(tester, width);
          final f = theme.ThemeScreenFixture();
          await f.run(tester, () async {
            await tester.pumpWidget(f.host(scale: 1.6, brightness: brightness));
            await tester.pumpAndSettle();
            final c = await theme.openThemes(tester, f);
            await theme.readThemes(tester, f, c);
            final list = _key('support_theme_scroll');
            await theme.reveal(
              tester,
              f,
              _key('support_theme_mode_choice_system'),
              list,
            );
            theme.fullControl(
              tester,
              _key('support_theme_mode_choice_system'),
              list,
            );
            await theme.reviewTheme(tester, f, c);
            final review = c.review;
            expect(review, isNotNull);
            expect(
              tester
                  .widget<SupportThemeButton>(_key('support_theme_confirm'))
                  .onTap,
              isNotNull,
            );
            _fixed(tester, _key('support_theme_confirm'));
            tester.view.viewInsets = const FakeViewPadding(bottom: 300);
            await tester.pumpAndSettle();
            // This is passive content, not one control that must fit in a frame.
            // Read both ends through the original bounded vertical traversal;
            // the real Confirm must still fit and hit-test in every frame.
            final after = _key('support_theme_after');
            final portions = find.descendant(
              of: after,
              matching: find.byType(Text),
            );
            await theme.reveal(tester, f, portions.first, list);
            _fixed(tester, _key('support_theme_confirm'));
            final displayed = tester
                .widget<SupportThemeValueBlock>(after)
                .value;
            final expected = c.intent!.preview(review!)!.after;
            expect(
              (displayed.id, displayed.name, displayed.mode, displayed.accent),
              (expected.id, expected.name, expected.mode, expected.accent),
            );
            expect(
              portions,
              findsNWidgets(5),
            ); // heading and all four safe fields
            await theme.reveal(tester, f, portions.last, list);
            expect(
              tester
                  .widget<SupportThemeSheet>(find.byType(SupportThemeSheet))
                  .controller,
              same(c),
            );
            expect(c.review, same(review));
            _fixed(tester, _key('support_theme_confirm'));
            expect(c.originalJob, isNull);
            await f.gesture(
              tester,
              () => tester.tap(_key('support_theme_cancel')),
            );
            await tester.pumpAndSettle();
            expect(find.byType(SupportThemeSheet), findsNothing);
          });
        },
      );
    }
  }
}
