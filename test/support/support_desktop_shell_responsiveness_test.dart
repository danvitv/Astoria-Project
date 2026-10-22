import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/features/support_assistant/support_assistant_screen.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_sessions_panel.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_settings_panel.dart';
import 'package:glaze_flutter/features/tools/tools_screen.dart';
import 'package:glaze_flutter/shared/shell/desktop/desktop_floating_provider.dart';
import 'package:glaze_flutter/shared/shell/desktop/desktop_glossary_popup.dart';
import 'package:glaze_flutter/shared/shell/desktop/desktop_layout_provider.dart';
import 'package:glaze_flutter/shared/shell/desktop/desktop_left_sidebar.dart';
import 'package:glaze_flutter/shared/shell/desktop/desktop_right_sidebar.dart';
import 'package:glaze_flutter/shared/shell/desktop/desktop_shell.dart';
import 'package:glaze_flutter/shared/shell/desktop/desktop_sidebar_surface.dart';
import 'package:glaze_flutter/shared/shell/desktop/sidebar_drag_handle.dart';
import 'package:glaze_flutter/shared/shell/desktop/sidebar_resizer.dart';
import 'package:glaze_flutter/shared/shell/desktop/sidebar_sheet_provider.dart';
import 'package:glaze_flutter/shared/widgets/glaze_scaffold.dart';
import 'package:glaze_flutter/shared/widgets/sheet_view.dart';

import 'helpers/support_desktop_shell_fixture.dart';
import 'helpers/support_native_widget_fixture.dart'
    show initializeNativeWidgetLocalization;

Finder _key(String key) => find.byKey(ValueKey(key));
Finder _surface(SidebarEdge edge) =>
    find.byWidgetPredicate((w) => w is DesktopSidebarSurface && w.edge == edge);
Finder _handle(SidebarEdge edge) => find.byWidgetPredicate(
  (w) =>
      w is SidebarDragHandle &&
      (edge == SidebarEdge.left
          ? w.leftController != null
          : w.rightController != null),
);

ProviderContainer _scope(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(SupportAssistantScreen)),
);
ProviderContainer _controllers(WidgetTester tester) =>
    ProviderScope.containerOf(
      tester.element(find.byType(SidebarDragHandle).first),
    );

Future<void> _pump(
  WidgetTester tester,
  SupportDesktopShellFixture fixture,
  GoRouter router, {
  double width = 1400,
  Map<String, Object> prefs = const {},
  String language = 'ru',
  double textScale = 1,
}) async {
  // Keep layout constraints AND MediaQuery (sheet sizing) on the same actual
  // viewport, as in the independent measured mobile-header scenarios.
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1000);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  installShellPlatformTripwires(tester);
  await fixture.initialize(prefs);
  addTearDown(fixture.dispose);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    fixture.app(router, language: language, textScale: textScale),
  );
  await tester.pumpAndSettle();
  expect(
    MediaQuery.sizeOf(tester.element(find.byType(DesktopShell))),
    Size(width, 1000),
  );
  fixture.expectNoExternalWork();
}

void _expectDesktop(
  WidgetTester tester, {
  required double left,
  required double right,
}) {
  expect(find.byType(DesktopShell), findsOneWidget);
  expect(find.byType(SupportAssistantScreen), findsOneWidget);
  expect(find.byType(SupportSessionsPanel), findsOneWidget);
  expect(find.byType(SupportSettingsPanel), findsOneWidget);
  expect(find.byType(DesktopLeftSidebar), findsNothing);
  expect(find.byType(DesktopRightSidebar), findsNothing);
  expect(_key('mobile_open_sessions_btn'), findsNothing);
  expect(tester.getSize(_surface(SidebarEdge.left)).width, closeTo(left, .1));
  expect(tester.getSize(_surface(SidebarEdge.right)).width, closeTo(right, .1));
  final center = tester.getRect(find.byType(SupportAssistantScreen));
  expect(center.width, greaterThanOrEqualTo(420));
  expect(
    center.left,
    closeTo(tester.getRect(_surface(SidebarEdge.left)).right, .1),
  );
  expect(
    center.right,
    closeTo(tester.getRect(_surface(SidebarEdge.right)).left, .1),
  );
  expect(
    isDesktopLayout(tester.element(find.byType(SupportAssistantScreen))),
    isTrue,
  );
  expect(tester.takeException(), isNull);
}

Future<void> _sheet(WidgetTester tester, String button, Type panel) async {
  expect(_key(button).hitTestable(), findsOneWidget);
  await tester.tap(_key(button));
  await tester.pumpAndSettle();
  final finder = find.byType(SheetView);
  expect(finder, findsOneWidget);
  final view = tester.widget<SheetView>(finder);
  expect(view.showBack, isTrue);
  expect(view.onBack, isNotNull);
  expect(tester.getSize(finder).height, inInclusiveRange(1, 1000));
  expect(
    find.descendant(of: finder, matching: find.byType(panel)),
    findsOneWidget,
  );
  final back = find.descendant(
    of: finder,
    matching: find.byIcon(Icons.arrow_back),
  );
  expect(back.hitTestable(), findsOneWidget);
  await tester.tap(back);
  await tester.pumpAndSettle();
  expect(finder, findsNothing);
  expect(tester.takeException(), isNull);
}

Offset _grip(WidgetTester tester, SidebarEdge edge) {
  final rect = tester.getRect(_handle(edge));
  // The handle straddles a clipped divider; use its visible half.
  return Offset(
    edge == SidebarEdge.left ? rect.left + 1 : rect.right - 1,
    rect.top + 300,
  );
}

Future<void> _doubleClick(WidgetTester tester, SidebarEdge edge) async {
  final position = _grip(tester, edge);
  await tester.tapAt(position);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tapAt(position);
  // Expansion changes the target immediately but the surface starts at the
  // old rail width. Check that first frame and a real in-between frame too.
  await tester.pump();
  _expectSupportModesForRealWidths(tester);
  await tester.pump(const Duration(milliseconds: 80));
  _expectSupportModesForRealWidths(tester);
  await tester.pumpAndSettle();
}

void _expectSupportModesForRealWidths(WidgetTester tester) {
  final left = tester.widget<DesktopSidebarSurface>(_surface(SidebarEdge.left));
  final right = tester.widget<DesktopSidebarSurface>(
    _surface(SidebarEdge.right),
  );
  expect(
    tester
        .widget<SupportSessionsPanel>(find.byType(SupportSessionsPanel))
        .collapsed,
    left.width < kSidebarCollapseThreshold ||
        tester.getSize(_surface(SidebarEdge.left)).width <
            LeftSidebarController.minWidth,
  );
  expect(
    tester
        .widget<SupportSettingsPanel>(find.byType(SupportSettingsPanel))
        .collapsed,
    right.width < kSidebarCollapseThreshold ||
        tester.getSize(_surface(SidebarEdge.right)).width <
            RightSidebarController.expandedMin,
  );
  expect(tester.takeException(), isNull);
}

Future<void> _escape(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(initializeNativeWidgetLocalization);

  for (final width in [360.0, 767.0]) {
    testWidgets(
      'actual shell at $width uses bounded mobile panels and explicit route back',
      (tester) async {
        final fixture = SupportDesktopShellFixture();
        final router = testGoRouterShellRoute();
        await _pump(tester, fixture, router, width: width);
        expect(find.byType(DesktopSidebarSurface), findsNothing);
        expect(find.byType(SupportSessionsPanel), findsNothing);
        expect(find.byType(SupportSettingsPanel), findsNothing);
        expect(
          isDesktopLayout(tester.element(find.byType(SupportAssistantScreen))),
          isFalse,
        );
        await _sheet(tester, 'mobile_open_sessions_btn', SupportSessionsPanel);
        await _sheet(tester, 'mobile_open_settings_btn', SupportSettingsPanel);
        final scaffold = tester.widget<GlazeScaffold>(
          find.byType(GlazeScaffold),
        );
        expect(scaffold.showBack, isTrue);
        final back = find.descendant(
          of: find.byType(GlazeScaffold),
          matching: find.byIcon(Icons.arrow_back_ios_new_rounded),
        );
        expect(back.hitTestable(), findsOneWidget);
        await tester.tap(back);
        await tester.pumpAndSettle();
        expect(router.routeInformationProvider.value.uri.path, '/characters');
        expect(find.text('Synthetic characters route'), findsOneWidget);
        fixture.expectNoExternalWork();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    '768 boundary fits right first and preserves persisted defaults',
    (tester) async {
      final fixture = SupportDesktopShellFixture();
      await _pump(
        tester,
        fixture,
        testGoRouterShellRoute(),
        width: 768,
        prefs: {'gz_left_sidebar_width': 280, 'gz_right_sidebar_width': 300.0},
      );
      _expectDesktop(tester, left: 280, right: 64);
      final scope = _controllers(tester);
      expect(scope.read(leftSidebarControllerProvider).width, 280);
      expect(scope.read(rightSidebarControllerProvider).width, 300);
      expect(scope.read(rightSidebarControllerProvider).collapsed, isFalse);
      expect(fixture.prefs.get('gz_left_sidebar_width'), 280);
      expect(fixture.prefs.get('gz_right_sidebar_width'), 300.0);
      expect(fixture.prefs.get('gz_right_sidebar_width_collapsed'), isNull);
      await _sheet(
        tester,
        'support_collapsed_settings_btn',
        SupportSettingsPanel,
      );
      fixture.expectNoExternalWork();
    },
  );

  testWidgets(
    'wide shell has one native center and two expanded support panels',
    (tester) async {
      final fixture = SupportDesktopShellFixture();
      await _pump(tester, fixture, testGoRouterShellRoute());
      _expectDesktop(tester, left: 280, right: 300);
      expect(_key('support_new_session_btn').hitTestable(), findsOneWidget);
      expect(_key('support_connection_selector').hitTestable(), findsOneWidget);
      expect(_key('support_sessions_back_btn').hitTestable(), findsOneWidget);
      fixture.expectNoExternalWork();
    },
  );

  testWidgets(
    'wide forceMobile and live width/setting transitions preserve user widths',
    (tester) async {
      final fixture = SupportDesktopShellFixture(forceMobile: true);
      await _pump(tester, fixture, testGoRouterShellRoute());
      await _sheet(tester, 'mobile_open_settings_btn', SupportSettingsPanel);
      fixture.settings.setForceMobile(false);
      await tester.pumpAndSettle();
      _expectDesktop(tester, left: 280, right: 300);
      final left = _controllers(tester).read(leftSidebarControllerProvider);
      final right = _controllers(tester).read(rightSidebarControllerProvider);
      tester.view.physicalSize = const Size(767, 1000);
      await tester.pumpAndSettle();
      expect(find.byType(DesktopSidebarSurface), findsNothing);
      expect(_key('mobile_open_sessions_btn').hitTestable(), findsOneWidget);
      tester.view.physicalSize = const Size(768, 1000);
      await tester.pumpAndSettle();
      _expectDesktop(tester, left: 280, right: 64);
      expect(
        identical(
          _controllers(tester).read(leftSidebarControllerProvider),
          left,
        ),
        isTrue,
      );
      fixture.settings.setForceMobile(true);
      await tester.pumpAndSettle();
      expect(find.byType(DesktopSidebarSurface), findsNothing);
      await _sheet(tester, 'mobile_open_sessions_btn', SupportSessionsPanel);
      tester.view.physicalSize = const Size(1400, 1000);
      fixture.settings.setForceMobile(false);
      await tester.pumpAndSettle();
      _expectDesktop(tester, left: 280, right: 300);
      expect(
        identical(
          _controllers(tester).read(rightSidebarControllerProvider),
          right,
        ),
        isTrue,
      );
      expect(left.width, 280);
      expect(right.width, 300);
      fixture.expectNoExternalWork();
    },
  );

  for (final rails in [(true, false), (false, true), (true, true)]) {
    testWidgets(
      'persisted rails left=${rails.$1} right=${rails.$2} keep controls reachable',
      (tester) async {
        final fixture = SupportDesktopShellFixture();
        await _pump(
          tester,
          fixture,
          testGoRouterShellRoute(),
          prefs: {
            'gz_left_sidebar_width_collapsed': rails.$1 ? '1' : '0',
            'gz_right_sidebar_width_collapsed': rails.$2 ? '1' : '0',
            'gz_right_sidebar_collapsed_width': 72.0,
          },
        );
        _expectDesktop(
          tester,
          left: rails.$1 ? 64 : 280,
          right: rails.$2 ? 72 : 300,
        );
        if (rails.$1) {
          await _sheet(
            tester,
            'support_collapsed_history_btn',
            SupportSessionsPanel,
          );
          await tester.tap(find.byTooltip('+ Новая сессия'));
        } else {
          await tester.tap(_key('support_new_session_btn'));
        }
        await tester.pumpAndSettle();
        expect(fixture.workspace.creations, 1);
        if (rails.$2) {
          await _sheet(
            tester,
            'support_collapsed_settings_btn',
            SupportSettingsPanel,
          );
        }
        fixture.expectNoExternalWork();
      },
    );
  }

  testWidgets(
    'controller-only notifications refit both columns without unrelated rebuild',
    (tester) async {
      final fixture = SupportDesktopShellFixture();
      final router = testGoRouterShellRoute();
      await _pump(tester, fixture, router, width: 1020);
      final left = _controllers(tester).read(leftSidebarControllerProvider);
      final right = _controllers(tester).read(rightSidebarControllerProvider);
      final shellState = tester.state(find.byType(DesktopShell));
      final sessionsState = tester.state(find.byType(SupportSessionsPanel));
      left.beginDrag();
      left.width = 600;
      // Observe the live frame, not only the final animated size. The opposite
      // edge must yield immediately even though only the left grip is active.
      await tester.pump();
      _expectDesktop(tester, left: 536, right: 64);
      expect(
        tester
            .widget<SupportSettingsPanel>(find.byType(SupportSettingsPanel))
            .collapsed,
        isTrue,
      );
      expect(
        _key('support_collapsed_settings_btn').hitTestable(),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      _expectDesktop(tester, left: 536, right: 64);
      expect(left.width, 600);
      expect(right.width, 300);
      left.width = 280;
      await tester.pump();
      _expectDesktop(tester, left: 280, right: 300);
      await tester.pumpAndSettle();
      _expectDesktop(tester, left: 280, right: 300);
      right.beginDrag();
      right.handleDragUpdate(90, false);
      await tester.pumpAndSettle();
      _expectDesktop(tester, left: 280, right: 64);
      expect(
        tester
            .widget<SupportSettingsPanel>(find.byType(SupportSettingsPanel))
            .collapsed,
        isTrue,
      );
      right.handleDragUpdate(300, true);
      await tester.pumpAndSettle();
      _expectDesktop(tester, left: 280, right: 300);
      // A raw expanded drag width between the collapse threshold and the
      // expanded minimum still needs usable rail controls, not squeezed rows.
      right.handleDragUpdate(150, false);
      await tester.pump();
      _expectDesktop(tester, left: 280, right: 150);
      expect(right.collapsed, isFalse);
      expect(
        _key('support_collapsed_settings_btn').hitTestable(),
        findsOneWidget,
      );
      left.width = 150;
      await tester.pump();
      _expectDesktop(tester, left: 150, right: 150);
      expect(left.collapsed, isFalse);
      expect(
        _key('support_collapsed_history_btn').hitTestable(),
        findsOneWidget,
      );
      left.width = 280;
      right.handleDragUpdate(300, false);
      await tester.pump();
      _expectDesktop(tester, left: 280, right: 300);
      left.endDrag();
      right.endDrag();
      expect(
        identical(tester.state(find.byType(DesktopShell)), shellState),
        isTrue,
      );
      expect(
        identical(
          tester.state(find.byType(SupportSessionsPanel)),
          sessionsState,
        ),
        isTrue,
      );
      expect(router.routeInformationProvider.value.uri.path, '/support');
      expect(fixture.prefs.get('gz_left_sidebar_width'), isNull);
      fixture.expectNoExternalWork();
    },
  );

  testWidgets(
    'history rail selects an existing session and route-back remains reachable',
    (tester) async {
      final fixture = SupportDesktopShellFixture();
      final router = testGoRouterShellRoute();
      await _pump(
        tester,
        fixture,
        router,
        prefs: {'gz_left_sidebar_width_collapsed': '1'},
      );
      await tester.tap(_key('support_collapsed_history_btn'));
      await tester.pumpAndSettle();
      final sheet = find.byType(SheetView);
      final row = _key('support_session_row_second');
      expect(row.hitTestable(), findsOneWidget);
      expect(_key('support_new_session_btn').hitTestable(), findsOneWidget);
      expect(_key('support_sessions_back_btn').hitTestable(), findsOneWidget);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
      expect(
        _scope(tester).read(supportWorkspaceProvider).activeSessionId,
        'second',
      );
      await tester.tap(_key('support_collapsed_history_btn'));
      await tester.pumpAndSettle();
      await tester.tap(_key('support_sessions_back_btn'));
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/characters');
      fixture.expectNoExternalWork();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'actual drag grips and double-click update geometry and save raw widths',
    (tester) async {
      final fixture = SupportDesktopShellFixture();
      await _pump(tester, fixture, testGoRouterShellRoute());
      final left = _controllers(tester).read(leftSidebarControllerProvider);
      final right = _controllers(tester).read(rightSidebarControllerProvider);
      var gesture = await tester.startGesture(_grip(tester, SidebarEdge.left));
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      expect(left.dragging, isTrue);
      expect(left.width, 320);
      expect(tester.getSize(_surface(SidebarEdge.left)).width, 320);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(left.dragging, isFalse);
      expect(fixture.prefs.get('gz_left_sidebar_width'), 320);
      gesture = await tester.startGesture(_grip(tester, SidebarEdge.right));
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump();
      expect(right.dragging, isTrue);
      expect(right.width, 340);
      expect(tester.getSize(_surface(SidebarEdge.right)).width, 340);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(fixture.prefs.get('gz_right_sidebar_width'), 340);
      await _doubleClick(tester, SidebarEdge.left);
      _expectDesktop(tester, left: 64, right: 340);
      await _doubleClick(tester, SidebarEdge.right);
      _expectDesktop(tester, left: 64, right: 64);
      await _doubleClick(tester, SidebarEdge.left);
      await _doubleClick(tester, SidebarEdge.right);
      _expectDesktop(tester, left: 280, right: 340);
      fixture.expectNoExternalWork();
    },
  );

  testWidgets(
    'retained regular panel floor/content and Escape are isolated on enter/exit',
    (tester) async {
      final fixture = SupportDesktopShellFixture();
      final router = testGoRouterShellRoute();
      await _pump(
        tester,
        fixture,
        router,
        prefs: {'gz_right_sidebar_width': 200.0},
      );
      final container = _scope(tester);
      var mounts = 0;
      final panel = SidebarPanel(
        id: 'synthetic-panel',
        builder: (_) {
          mounts++;
          return const Text('Retained regular tool body');
        },
      );
      container.read(rightSidebarPanelProvider.notifier).state = panel;
      await tester.pumpAndSettle();
      _expectDesktop(tester, left: 280, right: 200);
      expect(mounts, 0);
      expect(find.text('Retained regular tool body'), findsNothing);
      final input = find.descendant(
        of: _key('support_composer_input'),
        matching: find.byType(TextField),
      );
      await tester.tap(input);
      await _escape(tester);
      expect(
        identical(container.read(rightSidebarPanelProvider), panel),
        isTrue,
      );
      router.go('/characters');
      await tester.pumpAndSettle();
      expect(find.byType(DesktopLeftSidebar), findsOneWidget);
      expect(find.byType(DesktopRightSidebar), findsOneWidget);
      expect(find.text('Retained regular tool body'), findsOneWidget);
      expect(tester.getSize(_surface(SidebarEdge.right)).width, 384);
      final regularMounts = mounts;
      router.go('/support');
      await tester.pumpAndSettle();
      _expectDesktop(tester, left: 280, right: 200);
      expect(mounts, regularMounts);
      expect(
        identical(container.read(rightSidebarPanelProvider), panel),
        isTrue,
      );
      expect(fixture.prefs.get('gz_right_sidebar_width'), 200.0);
      expect(fixture.workspace.creations, 0);
      expect(fixture.workspace.retries, 0);
      // The ordinary visible panel still keeps its original Escape behavior.
      router.go('/characters');
      await tester.pumpAndSettle();
      await tester.tap(_key('synthetic_regular_focus'));
      await _escape(tester);
      expect(container.read(rightSidebarPanelProvider), isNull);
      expect(find.text('Retained regular tool body'), findsNothing);
      expect(tester.getSize(_surface(SidebarEdge.right)).width, 200);
      expect(find.byType(ToolsScreen), findsOneWidget);
      expect(
        tester.widget<ToolsScreen>(find.byType(ToolsScreen)).inSidebar,
        isTrue,
      );
      fixture.expectNoExternalWork();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Escape pops only visible floating/glossary overlays and retains hidden panel/term',
    (tester) async {
      final fixture = SupportDesktopShellFixture();
      await _pump(tester, fixture, testGoRouterShellRoute());
      final container = _scope(tester);
      final panel = SidebarPanel(
        id: 'retained',
        builder: (_) => throw StateError('Hidden panel leaked'),
      );
      container.read(rightSidebarPanelProvider.notifier).state = panel;
      container.read(glossaryPopupVisibleProvider.notifier).state = true;
      final input = find.descendant(
        of: _key('support_composer_input'),
        matching: find.byType(TextField),
      );
      await tester.tap(input);
      container.read(desktopFloatingStackProvider.notifier).state = [
        'synthetic-bottom',
        'synthetic-top',
      ];
      await tester.pumpAndSettle();
      await _escape(tester);
      expect(container.read(desktopFloatingStackProvider), [
        'synthetic-bottom',
      ]);
      expect(container.read(glossaryPopupVisibleProvider), isTrue);
      await _escape(tester);
      expect(container.read(desktopFloatingStackProvider), isEmpty);
      expect(container.read(glossaryPopupVisibleProvider), isTrue);
      await _escape(tester);
      expect(container.read(glossaryPopupVisibleProvider), isFalse);
      expect(
        container.read(glossaryPopupTermProvider),
        'synthetic-retained-term',
      );
      await _escape(tester);
      expect(
        identical(container.read(rightSidebarPanelProvider), panel),
        isTrue,
      );
      fixture.expectNoExternalWork();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a regular panel temporary auto-expansion is retained without its floor on support',
    (tester) async {
      final fixture = SupportDesktopShellFixture();
      final router = testGoRouterShellRoute(initialLocation: '/characters');
      await _pump(
        tester,
        fixture,
        router,
        prefs: {
          'gz_right_sidebar_width_collapsed': '1',
          'gz_right_sidebar_collapsed_width': 72.0,
        },
      );
      final container = _controllers(tester);
      final right = container.read(rightSidebarControllerProvider);
      expect(right.collapsed, isTrue);
      final panel = SidebarPanel(
        id: 'temporary-regular-panel',
        builder: (_) => const Text('Temporary regular panel body'),
      );
      container.read(rightSidebarPanelProvider.notifier).state = panel;
      await tester.pumpAndSettle();
      expect(right.wasAutoExpanded, isTrue);
      expect(right.width, 300);
      expect(tester.getSize(_surface(SidebarEdge.right)).width, 384);
      router.go('/support');
      await tester.pumpAndSettle();
      _expectDesktop(tester, left: 280, right: 300);
      expect(find.text('Temporary regular panel body'), findsNothing);
      expect(right.wasAutoExpanded, isTrue);
      expect(fixture.prefs.get('gz_right_sidebar_width_collapsed'), '1');
      expect(fixture.prefs.get('gz_right_sidebar_collapsed_width'), 72.0);
      router.go('/characters');
      await tester.pumpAndSettle();
      expect(
        identical(container.read(rightSidebarPanelProvider), panel),
        isTrue,
      );
      expect(find.text('Temporary regular panel body'), findsOneWidget);
      expect(tester.getSize(_surface(SidebarEdge.right)).width, 384);
      fixture.expectNoExternalWork();
      expect(tester.takeException(), isNull);
    },
  );

  for (final availability in [
    SupportSettingsAvailability.locked,
    SupportSettingsAvailability.corrupt,
    SupportSettingsAvailability.unavailable,
  ]) {
    testWidgets(
      'collapsed settings $availability still opens safe error/retry UI',
      (tester) async {
        final fixture = SupportDesktopShellFixture(
          availability: availability,
          error: 'Synthetic safe storage failure',
        );
        await _pump(
          tester,
          fixture,
          testGoRouterShellRoute(),
          prefs: {'gz_right_sidebar_width_collapsed': '1'},
        );
        _expectDesktop(tester, left: 280, right: 64);
        await tester.tap(_key('support_collapsed_settings_btn'));
        await tester.pumpAndSettle();
        expect(_key('support_settings_retry').hitTestable(), findsOneWidget);
        expect(
          _key('support_settings_recover'),
          availability == SupportSettingsAvailability.corrupt
              ? findsOneWidget
              : findsNothing,
        );
        await tester.tap(_key('support_settings_retry'));
        await tester.pumpAndSettle();
        expect(fixture.workspace.retries, 1);
        tester.widget<SheetView>(find.byType(SheetView)).onBack!();
        await tester.pumpAndSettle();
        fixture.expectNoExternalWork();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('EN_US scaled rail sheets retain usable bounded controls', (
    tester,
  ) async {
    final fixture = SupportDesktopShellFixture();
    await _pump(
      tester,
      fixture,
      testGoRouterShellRoute(),
      width: 768,
      language: 'en',
      textScale: 1.3,
      prefs: {
        'gz_left_sidebar_width_collapsed': '1',
        'gz_right_sidebar_width_collapsed': '1',
      },
    );
    _expectDesktop(tester, left: 64, right: 64);
    await _sheet(tester, 'support_collapsed_history_btn', SupportSessionsPanel);
    await _sheet(
      tester,
      'support_collapsed_settings_btn',
      SupportSettingsPanel,
    );
    fixture.expectNoExternalWork();
  });
}
