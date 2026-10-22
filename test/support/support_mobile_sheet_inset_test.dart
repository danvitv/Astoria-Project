import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:glaze_flutter/core/constants/support_assistant_availability.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/features/support_assistant/support_assistant_screen.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_sessions_panel.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_settings_panel.dart';
import 'package:glaze_flutter/shared/shell/desktop/desktop_layout_provider.dart';
import 'package:glaze_flutter/shared/shell/desktop/desktop_shell.dart';
import 'package:glaze_flutter/shared/shell/desktop/desktop_sidebar_surface.dart';
import 'package:glaze_flutter/shared/widgets/glaze_tab_bar.dart';
import 'package:glaze_flutter/shared/widgets/sheet_view.dart';

import 'helpers/support_desktop_shell_fixture.dart';
import 'helpers/support_native_widget_fixture.dart'
    show initializeNativeWidgetLocalization;

// Isolation is inherited unchanged from the settled actual-shell fixture:
// ONE flat root ProviderScope, memory presentation/prefs/theme, no App/catalog
// mount or DB construction, and rejecting DB/repo/vault/metadata startup ports.
// The real native controller/view stays unavailable with no selected session.
// These tests exercise geometry and sheet/session navigation, not native rights
// or mode persistence. In particular, mode controls are revealed/hit-tested but
// not activated through the presentation fake's real-notifier persistence path.
Finder _key(String value) => find.byKey(ValueKey(value));
Finder get _sheet => find.byType(SheetView);
Finder get _sheetBack =>
    find.descendant(of: _sheet, matching: find.byIcon(Icons.arrow_back));

Future<void> _mount(
  WidgetTester tester,
  SupportDesktopShellFixture fixture,
  GoRouter router,
  Size viewport,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = viewport;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  installShellPlatformTripwires(tester);
  await fixture.initialize(const {});
  addTearDown(fixture.dispose);
  addTearDown(router.dispose);
  await tester.pumpWidget(fixture.app(router));
  await tester.pumpAndSettle();
  expect(find.byType(DesktopShell), findsOneWidget);
  expect(find.byType(SupportAssistantScreen), findsOneWidget);
  expect(find.byType(DesktopSidebarSurface), findsNothing);
  final context = tester.element(find.byType(SupportAssistantScreen));
  expect(MediaQuery.sizeOf(context), viewport);
  expect(isDesktopLayout(context), isFalse);
  expect(supportAssistantWorkspaceEnabled, isFalse);
  fixture.expectNoExternalWork();
  expect(tester.takeException(), isNull);
}

void _expectContained(Rect child, Rect parent) {
  const slack = .5;
  expect(child.width, greaterThan(0));
  expect(child.height, greaterThan(0));
  expect(child.left, greaterThanOrEqualTo(parent.left - slack));
  expect(child.top, greaterThanOrEqualTo(parent.top - slack));
  expect(child.right, lessThanOrEqualTo(parent.right + slack));
  expect(child.bottom, lessThanOrEqualTo(parent.bottom + slack));
}

Rect _measuredHeader(WidgetTester tester, String title, Size viewport) {
  expect(_sheet, findsOneWidget);
  expect(_sheetBack.hitTestable(), findsOneWidget);
  // This is the actual GlobalKey-backed KeyedSubtree that SheetView measures,
  // enclosing both handle and app-bar row (including its bottom padding).
  // No private State access, guessed height, or title-only header proxy.
  final header = find
      .ancestor(
        of: _sheetBack,
        matching: find.byWidgetPredicate(
          (widget) => widget is KeyedSubtree && widget.key is GlobalKey,
        ),
      )
      .first;
  expect(find.descendant(of: _sheet, matching: header), findsOneWidget);
  expect(
    find.descendant(of: header, matching: find.text(title)),
    findsOneWidget,
  );
  final sheetBounds = tester.getRect(_sheet);
  final headerBounds = tester.getRect(header);
  _expectContained(sheetBounds, Offset.zero & viewport);
  _expectContained(headerBounds, sheetBounds);
  expect(headerBounds.top, closeTo(sheetBounds.top, .5));
  expect(headerBounds.height, greaterThan(tester.getSize(_sheetBack).height));
  expect(headerBounds.bottom, greaterThan(tester.getRect(_sheetBack).bottom));
  final sheet = tester.widget<SheetView>(_sheet);
  expect(sheet.showBack, isTrue);
  expect(sheet.onBack, isNotNull);
  return headerBounds;
}

void _expectBelowHeader(
  WidgetTester tester,
  Finder finder,
  Rect header, {
  Rect? within,
  bool hittable = true,
}) {
  expect(finder, findsOneWidget);
  final bounds = tester.getRect(finder);
  expect(bounds.top, greaterThanOrEqualTo(header.bottom - .5));
  _expectContained(bounds, within ?? tester.getRect(_sheet));
  if (hittable) expect(finder.hitTestable(), findsOneWidget);
}

Future<void> _closeAndExpectScreen(
  WidgetTester tester,
  SupportDesktopShellFixture fixture,
  GoRouter router,
  State screenState,
) async {
  await tester.tap(_sheetBack);
  await tester.pumpAndSettle();
  expect(_sheet, findsNothing);
  expect(find.byType(SupportSessionsPanel), findsNothing);
  expect(find.byType(SupportSettingsPanel), findsNothing);
  expect(router.routeInformationProvider.value.uri.path, '/support');
  expect(
    identical(tester.state(find.byType(SupportAssistantScreen)), screenState),
    isTrue,
  );
  expect(_key('mobile_open_sessions_btn').hitTestable(), findsOneWidget);
  expect(_key('mobile_open_settings_btn').hitTestable(), findsOneWidget);
  fixture.expectNoExternalWork();
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(initializeNativeWidgetLocalization);

  for (final width in [360.0, 767.0]) {
    final viewport = Size(width, 1000);

    testWidgets(
      'actual $width mobile sessions clear the measured sheet header',
      (tester) async {
        final fixture = SupportDesktopShellFixture();
        final router = testGoRouterShellRoute();
        await _mount(tester, fixture, router, viewport);
        final screenState = tester.state(find.byType(SupportAssistantScreen));
        await tester.tap(_key('mobile_open_sessions_btn'));
        await tester.pumpAndSettle();
        final header = _measuredHeader(
          tester,
          'История сессий Астории',
          viewport,
        );
        final panel = find.byType(SupportSessionsPanel);
        _expectBelowHeader(tester, panel, header, hittable: false);
        _expectBelowHeader(tester, find.text('История Астории'), header);
        _expectBelowHeader(tester, _key('support_sessions_back_btn'), header);
        _expectBelowHeader(tester, _key('support_new_session_btn'), header);
        _expectBelowHeader(tester, _key('support_session_row_first'), header);
        fixture.expectNoExternalWork();
        expect(tester.takeException(), isNull);
        await _closeAndExpectScreen(tester, fixture, router, screenState);

        // Reopening proves the existing sheet latch/back flow remains usable;
        // selection is the fixture's memory-only callback, not DB/native work.
        await tester.tap(_key('mobile_open_sessions_btn'));
        await tester.pumpAndSettle();
        await tester.tap(_key('support_session_row_second'));
        await tester.pumpAndSettle();
        expect(_sheet, findsNothing);
        expect(
          ProviderScope.containerOf(
            tester.element(find.byType(SupportAssistantScreen)),
          ).read(supportWorkspaceProvider).activeSessionId,
          'second',
        );
        expect(router.routeInformationProvider.value.uri.path, '/support');
        await tester.tap(_key('mobile_open_sessions_btn'));
        await tester.pumpAndSettle();
        final reopenedHeader = _measuredHeader(
          tester,
          'История сессий Астории',
          viewport,
        );
        _expectBelowHeader(
          tester,
          _key('support_sessions_back_btn'),
          reopenedHeader,
        );
        await tester.tap(_key('support_sessions_back_btn'));
        await tester.pumpAndSettle();
        expect(_sheet, findsNothing);
        expect(find.byType(SupportAssistantScreen), findsNothing);
        expect(router.routeInformationProvider.value.uri.path, '/characters');
        expect(find.text('Synthetic characters route'), findsOneWidget);
        fixture.expectNoExternalWork();
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('actual $width mobile modes clear the measured sheet header', (
      tester,
    ) async {
      final fixture = SupportDesktopShellFixture();
      final router = testGoRouterShellRoute();
      await _mount(tester, fixture, router, viewport);
      final screenState = tester.state(find.byType(SupportAssistantScreen));
      await tester.tap(_key('mobile_open_settings_btn'));
      await tester.pumpAndSettle();
      final header = _measuredHeader(tester, 'Настройки Астории', viewport);
      _expectBelowHeader(
        tester,
        find.byType(SupportSettingsPanel),
        header,
        hittable: false,
      );
      _expectBelowHeader(tester, find.text('Режим Астории'), header);
      final tabs = find.descendant(
        of: _sheet,
        matching: find.byType(GlazeTabBar),
      );
      _expectBelowHeader(tester, tabs, header);
      final tabBounds = tester.getRect(tabs);
      for (final mode in SupportAssistantMode.values) {
        if (mode == SupportAssistantMode.hybrid) {
          // The production pill strip shows 2.35 tabs. Reveal the third using
          // the actual horizontal gesture, without scrolling the form upwards.
          await tester.drag(tabs, Offset(-tabBounds.width, 0));
          await tester.pumpAndSettle();
        }
        final label = find.descendant(
          of: tabs,
          matching: find.text(mode.shortLabel),
        );
        final target = find
            .ancestor(
              of: label,
              matching: find.byWidgetPredicate(
                (widget) => widget is GestureDetector && widget.onTap != null,
              ),
            )
            .first;
        _expectBelowHeader(tester, target, header, within: tabBounds);
        _expectBelowHeader(tester, label, header, within: tabBounds);
      }
      fixture.expectNoExternalWork();
      expect(tester.takeException(), isNull);
      await _closeAndExpectScreen(tester, fixture, router, screenState);
    });
  }
}
