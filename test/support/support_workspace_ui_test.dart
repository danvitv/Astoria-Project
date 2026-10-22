import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/features/support_assistant/support_assistant_screen.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_card_view.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_composer_bar.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_sessions_panel.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_settings_panel.dart';
import 'package:glaze_flutter/shared/shell/desktop/desktop_left_sidebar.dart';
import 'package:glaze_flutter/shared/shell/desktop/desktop_right_sidebar.dart';
import 'package:glaze_flutter/shared/shell/desktop/desktop_shell.dart';
import 'package:glaze_flutter/shared/widgets/sheet_view.dart';
import 'helpers/support_native_widget_fixture.dart';

class _Settings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings();
}

/// Explicit fake state: no DB, credential vault, transport, or runtime files.
class _Workspace extends SupportWorkspaceNotifier {
  int sends = 0;
  final Completer<bool>? sendResult;

  _Workspace({this.sendResult});

  @override
  SupportWorkspaceState build() => SupportWorkspaceState(
    sessions: [
      SupportSessionSummary(
        id: 'fake-session',
        title: 'Тестовая сессия',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
    ],
    activeSessionId: 'fake-session',
    messagesBySession: const {},
    settings: const SupportAssistantSettings(),
    isLoading: false,
  );

  @override
  Future<bool> sendUserMessage(String text) async {
    sends++;
    return sendResult == null ? false : sendResult!.future;
  }
}

Widget _scope(Widget child, _Workspace workspace) => NativeWidgetIsolation(
  overrides: (_) => [
    appSettingsProvider.overrideWith(_Settings.new),
    supportWorkspaceProvider.overrideWith(() => workspace),
    supportConnectionsProvider.overrideWithValue(const []),
  ],
  child: child,
);

GoRouter _router({bool desktop = false}) => GoRouter(
  initialLocation: '/support',
  routes: [
    ShellRoute(
      builder: (_, _, child) => desktop ? DesktopShell(child: child) : child,
      routes: [
        GoRoute(
          path: '/support',
          builder: (_, _) => const SupportAssistantScreen(),
        ),
      ],
    ),
    for (final path in [
      '/characters',
      '/tools/api',
      '/menu/themes',
      '/tools/lorebooks/settings',
    ])
      GoRoute(
        path: path,
        builder: (_, _) => Scaffold(body: Text(path)),
      ),
  ],
);

void main() {
  setUpAll(initializeNativeWidgetLocalization);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('rejected send retains draft and concurrent send is blocked', (
    tester,
  ) async {
    final pending = Completer<bool>();
    final workspace = _Workspace(sendResult: pending);
    final router = _router();
    addTearDown(router.dispose);
    await tester.pumpWidget(
      _scope(MaterialApp.router(routerConfig: router), workspace),
    );
    await tester.pumpAndSettle();
    final input = find.descendant(
      of: find.byKey(const ValueKey('support_composer_input')),
      matching: find.byType(TextField),
    );
    await tester.enterText(input, 'Сохрани мой черновик');
    await tester.tap(find.byKey(const ValueKey('support_composer_send_btn')));
    await tester.pump();
    final button = tester.widget<IconButton>(
      find.byKey(const ValueKey('support_composer_send_btn')),
    );
    expect(button.onPressed, isNull);
    expect(workspace.sends, 1);
    pending.complete(false);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(input).controller!.text,
      'Сохрани мой черновик',
    );
    expect(find.textContaining('Сообщение не сохранено'), findsOneWidget);
  });

  testWidgets('accepted send never clears a newer draft', (tester) async {
    final controller = TextEditingController(text: 'Первый');
    final pending = Completer<bool>();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _scope(
        MaterialApp(
          home: Scaffold(
            body: SupportComposerBar(
              controller: controller,
              onSend: (_) => pending.future,
            ),
          ),
        ),
        _Workspace(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('support_composer_send_btn')));
    controller.text = 'Новый черновик';
    pending.complete(true);
    await tester.pumpAndSettle();
    expect(controller.text, 'Новый черновик');
  });

  testWidgets('mobile sheets reuse panels and explicit back dismisses each', (
    tester,
  ) async {
    final router = _router();
    addTearDown(router.dispose);
    await tester.pumpWidget(
      _scope(MaterialApp.router(routerConfig: router), _Workspace()),
    );
    await tester.pumpAndSettle();
    for (final key in [
      'mobile_open_sessions_btn',
      'mobile_open_settings_btn',
    ]) {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
      final sheet = tester.widget<SheetView>(find.byType(SheetView));
      expect(sheet.showBack, isTrue);
      expect(sheet.onBack, isNotNull);
      expect(
        key.contains('sessions')
            ? find.byType(SupportSessionsPanel)
            : find.byType(SupportSettingsPanel),
        findsOneWidget,
      );
      expect(tester.getSize(find.byType(SheetView)).height.isFinite, isTrue);
      sheet.onBack!();
      await tester.pumpAndSettle();
      expect(find.byType(SheetView), findsNothing);
    }
  });

  testWidgets('collapsed sessions strip can open existing history', (
    tester,
  ) async {
    await tester.pumpWidget(
      _scope(
        const MaterialApp(
          home: Scaffold(body: SupportSessionsPanel(collapsed: true)),
        ),
        _Workspace(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('support_collapsed_history_btn')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Тестовая сессия'), findsOneWidget);
    tester.widget<SheetView>(find.byType(SheetView)).onBack!();
    await tester.pumpAndSettle();
    expect(find.byType(SheetView), findsNothing);
  });

  testWidgets(
    'desktop support mounts support sidebars instead of regular chat',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final router = _router(desktop: true);
      addTearDown(router.dispose);
      await tester.pumpWidget(
        _scope(MaterialApp.router(routerConfig: router), _Workspace()),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DesktopShell), findsOneWidget);
      expect(find.byType(SupportSessionsPanel), findsOneWidget);
      expect(find.byType(SupportSettingsPanel), findsOneWidget);
      expect(find.byType(DesktopLeftSidebar), findsNothing);
      expect(find.byType(DesktopRightSidebar), findsNothing);
      expect(
        find.byKey(const ValueKey('mobile_open_sessions_btn')),
        findsNothing,
      );
    },
  );

  testWidgets('provider welcome action opens actual API route', (tester) async {
    final router = _router();
    addTearDown(router.dispose);
    await tester.pumpWidget(
      _scope(MaterialApp.router(routerConfig: router), _Workspace()),
    );
    await tester.pumpAndSettle();
    final action = find.byKey(const ValueKey('quick_action_provider_setup'));
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(find.text('/tools/api'), findsOneWidget);
  });

  testWidgets('mutation and export cards cannot claim or execute success', (
    tester,
  ) async {
    var applied = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SupportCardView(
            card: const MutationPlanCard(
              planId: 'p',
              domain: 'theme',
              title: 'Test',
              beforeSummary: 'A',
              afterSummary: 'B',
              applied: true,
            ),
            onApplyPlan: (_) => applied = true,
          ),
        ),
      ),
    );
    expect(find.text('Применено'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('apply_plan_p')));
    expect(applied, isFalse);
    expect(find.text('Применение пока недоступно'), findsOneWidget);
  });
}
