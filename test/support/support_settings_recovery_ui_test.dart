import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/features/support_assistant/support_assistant_screen.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_settings_panel.dart';
import 'helpers/workspace_test_harness.dart';
import 'helpers/support_native_widget_fixture.dart';

class _Settings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings();
}

class _RecoveryWorkspace extends SupportWorkspaceNotifier {
  _RecoveryWorkspace(this.availability);
  final SupportSettingsAvailability availability;
  int recoveries = 0;
  @override
  SupportWorkspaceState build() => SupportWorkspaceState(
    sessions: [
      SupportSessionSummary(
        id: 'a',
        title: 'Synthetic session',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
    ],
    activeSessionId: 'a',
    settingsAvailability: availability,
    isLoading: false,
  );
  @override
  Future<bool> recoverSettings({
    required String sessionId,
    required bool confirmed,
  }) async {
    if (sessionId == state.activeSessionId && confirmed) recoveries++;
    return true;
  }

  void switchSession() =>
      state = state.copyWith(activeSessionId: 'gone', sessions: []);
  void partialFailure() => state = state.copyWith(
    settingsAvailability: SupportSettingsAvailability.available,
    messagesBySession: {
      'a': [
        SupportMessageItem(
          id: 'u',
          sessionId: 'a',
          role: SupportMessageRole.user,
          body: 'Durably saved user',
          createdAt: DateTime.utc(2026),
        ),
      ],
    },
    error: 'Сообщение сохранено, но ответ помощника не удалось сохранить.',
  );
}

Widget _host(Widget child, _RecoveryWorkspace workspace, {GoRouter? router}) =>
    NativeWidgetIsolation(
      overrides: (_) => [
        appSettingsProvider.overrideWith(_Settings.new),
        supportWorkspaceProvider.overrideWith(() => workspace),
        supportConnectionsProvider.overrideWithValue(const []),
      ],
      child: router == null
          ? MaterialApp(home: Scaffold(body: child))
          : MaterialApp.router(routerConfig: router),
    );

void main() {
  setUpAll(initializeNativeWidgetLocalization);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'route post-frame topic survives initial loading and empty history with real notifier and synthetic ports',
    (tester) async {
      final h = WorkspaceHarness();
      h.dispose();
      addTearDown(h.close);
      h.store.sessions.clear();
      h.store.messages.clear();
      h.store.availability.clear();
      final gate = h.store.gates['load'] = WorkspaceGate();
      final router = GoRouter(
        initialLocation: '/support?topic=theme',
        routes: [
          GoRoute(
            path: '/support',
            builder: (_, state) => SupportAssistantScreen(
              initialTopic: state.uri.queryParameters['topic'],
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...memoryNativeWidgetOverrides(h.db, h.repo),
            appSettingsProvider.overrideWith(_Settings.new),
            supportSessionStoreProvider.overrideWithValue(h.store),
            supportConnectionMetadataProvider.overrideWith(
              (ref) async => const [],
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      expect(gate.entered.isCompleted, isTrue);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SupportAssistantScreen)),
      );
      expect(container.read(supportWorkspaceProvider).lastHandledTopic, isNull);
      gate.release.complete();
      await tester.pumpAndSettle();
      final workspace = container.read(supportWorkspaceProvider);
      expect(workspace.lastHandledTopic, 'theme_setup');
      expect(workspace.sessions.length, 1);
      expect(
        workspace.activeMessages.single.cards
            .whereType<SetupActionCard>()
            .single
            .topicId,
        'theme_setup',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'corrupt settings show no valid defaults and require explicit confirmation; cancellation does not reset',
    (tester) async {
      final workspace = _RecoveryWorkspace(SupportSettingsAvailability.corrupt);
      await tester.pumpWidget(_host(const SupportSettingsPanel(), workspace));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('support_connection_selector')),
        findsNothing,
      );
      expect(find.text('Temperature'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('support_settings_recover')));
      await tester.pumpAndSettle();
      expect(find.text('Сбросить настройки сессии?'), findsOneWidget);
      expect(workspace.recoveries, 0);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(workspace.recoveries, 0);
      await tester.tap(find.byKey(const ValueKey('support_settings_recover')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сбросить настройки'));
      await tester.pumpAndSettle();
      expect(workspace.recoveries, 1);
    },
  );

  testWidgets('locked and unavailable settings have no reset affordance', (
    tester,
  ) async {
    for (final availability in [
      SupportSettingsAvailability.locked,
      SupportSettingsAvailability.unavailable,
    ]) {
      await tester.pumpWidget(
        _host(const SupportSettingsPanel(), _RecoveryWorkspace(availability)),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('support_settings_recover')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('support_settings_retry')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('support_model_selector')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets(
    'switching selection while confirmation is open cannot reset a different session',
    (tester) async {
      final workspace = _RecoveryWorkspace(SupportSettingsAvailability.corrupt);
      await tester.pumpWidget(_host(const SupportSettingsPanel(), workspace));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('support_settings_recover')));
      await tester.pumpAndSettle();
      workspace.switchSession();
      await tester.tap(find.text('Сбросить настройки'));
      await tester.pumpAndSettle();
      expect(workspace.recoveries, 0);
    },
  );

  testWidgets(
    'disposal during confirmation does not call the disposed workspace',
    (tester) async {
      final workspace = _RecoveryWorkspace(SupportSettingsAvailability.corrupt);
      await tester.pumpWidget(_host(const SupportSettingsPanel(), workspace));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('support_settings_recover')));
      await tester.pumpAndSettle();
      expect(find.text('Сбросить настройки сессии?'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(workspace.recoveries, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'workspace blocks composer for unavailable settings and shows partial-success user plus safe error',
    (tester) async {
      final workspace = _RecoveryWorkspace(SupportSettingsAvailability.locked);
      final router = GoRouter(
        initialLocation: '/support',
        routes: [
          GoRoute(
            path: '/support',
            builder: (_, _) => const SupportAssistantScreen(),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        _host(const SupportAssistantScreen(), workspace, router: router),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('support_composer_send_btn')),
            )
            .onPressed,
        isNull,
      );
      expect(find.textContaining('Отправка заблокирована'), findsOneWidget);
      workspace.partialFailure();
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(
        find.text('Durably saved user', findRichText: true),
        findsOneWidget,
      );
      expect(find.textContaining('Сообщение сохранено'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
