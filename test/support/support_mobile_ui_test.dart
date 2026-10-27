import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/features/support_assistant/support_assistant_screen.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_action_strip.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_guidance_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_provider_entry.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_provider_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_settings_panel.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_theme_entry.dart';
import 'package:glaze_flutter/shared/widgets/sheet_view.dart';

import 'helpers/support_desktop_shell_fixture.dart';
import 'helpers/support_native_widget_fixture.dart';

Finder key(String value, {bool skipOffstage = true}) =>
    find.byKey(ValueKey(value), skipOffstage: skipOffstage);

void contained(
  WidgetTester tester,
  Finder child,
  Rect parent, {
  bool hit = true,
}) {
  expect(child, findsOneWidget);
  final rect = tester.getRect(child);
  expect(rect.left, greaterThanOrEqualTo(parent.left - .5));
  expect(rect.right, lessThanOrEqualTo(parent.right + .5));
  expect(rect.top, greaterThanOrEqualTo(parent.top - .5));
  expect(rect.bottom, lessThanOrEqualTo(parent.bottom + .5));
  if (hit) expect(child.hitTestable(), findsOneWidget);
}

Future<void> reveal(WidgetTester tester, String target, String list) async {
  final scrollable = find
      .descendant(of: key(list), matching: find.byType(Scrollable))
      .first;
  await tester.scrollUntilVisible(
    key(target),
    180,
    scrollable: scrollable,
    maxScrolls: 30,
  );
  await Scrollable.ensureVisible(tester.element(key(target)), alignment: .5);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(initializeNativeWidgetLocalization);
  for (final width in [320.0, 390.0]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'actual mobile $width $brightness: drawer, sheets, back and IME',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 844);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetViewInsets);
          installShellPlatformTripwires(tester);
          final fixture = SupportDesktopShellFixture();
          await fixture.initialize(const {});
          addTearDown(fixture.dispose);
          final router = testGoRouterShellRoute();
          addTearDown(router.dispose);
          await tester.pumpWidget(
            fixture.app(router, textScale: 1.6, brightness: brightness),
          );
          await tester.pumpAndSettle();
          final screen = find.byType(SupportAssistantScreen);
          final original = tester.state(screen);
          final viewport = Offset.zero & Size(width, 844);
          for (final action in [
            'mobile_open_settings_btn',
            'mobile_open_sessions_btn',
            'support_drawer_toggle',
            'support_composer_send_btn',
          ]) {
            contained(tester, key(action), viewport);
            expect(
              tester.getSize(key(action)).shortestSide,
              greaterThanOrEqualTo(48),
            );
          }
          expect(
            tester
                .widget<IconButton>(key('support_composer_send_btn'))
                .onPressed,
            isNull,
          );
          await tester.tap(key('support_drawer_toggle'));
          await tester.pumpAndSettle();
          expect(
            tester.widget<IconButton>(key('support_drawer_toggle')).isSelected,
            isTrue,
          );
          final themeState = tester.state(find.byType(SupportThemeEntry));
          final providerState = tester.state(find.byType(SupportProviderEntry));
          expect(
            find.ancestor(
              of: key('support_composer_send_btn'),
              matching: find.byKey(const ValueKey('support_bottom_actions')),
            ),
            findsNothing,
          );
          contained(
            tester,
            key('support_theme_open'),
            tester.getRect(key('support_action_drawer')),
          );
          await tester.tap(key('support_theme_open'));
          await tester.pumpAndSettle();
          // The actual default-OFF entry opens only its passive prerequisite sheet.
          expect(find.byType(SheetView), findsOneWidget);
          expect(
            tester
                .widget<SupportActionTile>(
                  key('support_theme_open', skipOffstage: false),
                )
                .selected,
            isTrue,
          );
          await tester.tap(find.byIcon(Icons.arrow_back));
          await tester.pumpAndSettle();
          await tester.tap(key('support_provider_open'));
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<SupportProviderSheet>(find.byType(SupportProviderSheet))
                .controller,
            isNull,
          );
          await tester.tap(key('support_provider_cancel'));
          await tester.pumpAndSettle();
          await reveal(
            tester,
            'support_panel_report_action',
            'support_bottom_actions',
          );
          expect(
            tester
                .widget<SupportActionTile>(key('support_panel_report_action'))
                .onTap,
            isNull,
          );
          await tester.tap(key('support_drawer_close'));
          await tester.pumpAndSettle();
          await tester.tap(key('support_drawer_toggle'));
          await tester.pumpAndSettle();
          expect(
            tester.state(find.byType(SupportThemeEntry)),
            same(themeState),
          );
          expect(
            tester.state(find.byType(SupportProviderEntry)),
            same(providerState),
          );
          await tester.tap(key('support_drawer_close'));
          await tester.pumpAndSettle();
          await tester.tap(key('mobile_open_sessions_btn'));
          await tester.pumpAndSettle();
          expect(
            find.text('История Астории'),
            findsNothing,
          ); // no duplicate header
          final collapsed = tester.getRect(find.byType(SheetView));
          // Real SheetView handle gesture, not invoking its private resize callback.
          await tester.tapAt(Offset(collapsed.center.dx, collapsed.top + 12));
          await tester.pumpAndSettle();
          expect(
            tester.getSize(find.byType(SheetView)).height,
            greaterThan(collapsed.height),
          );
          final search = find.descendant(
            of: key('support_session_search_input'),
            matching: find.byType(TextField),
          );
          await tester.tap(search);
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          await tester.pumpAndSettle();
          await reveal(
            tester,
            'support_session_row_second',
            'support_sessions_scroll',
          );
          contained(
            tester,
            key('support_session_row_second'),
            Rect.fromLTRB(0, 0, width, 544),
          );
          await tester.tap(key('support_session_row_second'));
          await tester.pumpAndSettle();
          tester.view.resetViewInsets();
          await tester.pumpAndSettle();
          expect(
            ProviderScope.containerOf(
              tester.element(screen),
            ).read(supportWorkspaceProvider).activeSessionId,
            'second',
          );
          await tester.tap(key('mobile_open_settings_btn'));
          await tester.pumpAndSettle();
          expect(find.byType(SupportSettingsPanel), findsOneWidget);
          await reveal(
            tester,
            'support_privacy_group',
            'support_settings_scroll',
          );
          contained(
            tester,
            key('support_privacy_group'),
            tester.getRect(find.byType(SheetView)),
          );
          await tester.tap(find.byIcon(Icons.arrow_back));
          await tester.pumpAndSettle();
          expect(tester.state(screen), same(original));
          expect(router.routeInformationProvider.value.uri.path, '/support');
          expect(find.byType(SupportGuidanceSheet), findsNothing);
          fixture.expectNoExternalWork();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
