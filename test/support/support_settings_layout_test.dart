import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_settings_panel.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'helpers/support_native_widget_fixture.dart';

class _FakeWorkspace extends SupportWorkspaceNotifier {
  @override
  SupportWorkspaceState build() =>
      const SupportWorkspaceState(settings: SupportAssistantSettings());
}

Widget _panel() => NativeWidgetIsolation(
  overrides: (_) => [
    appSettingsProvider.overrideWith(NativeWidgetAppSettings.new),
    supportWorkspaceProvider.overrideWith(_FakeWorkspace.new),
    supportConnectionsProvider.overrideWithValue(const []),
  ],
  child: const SupportSettingsPanel(),
);

Future<void> _showControl(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      250,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .last,
      maxScrolls: 20,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(initializeNativeWidgetLocalization);
  testWidgets('settings controls fit the narrow desktop sidebar', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(236, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(home: SizedBox(width: 236, child: _PanelHost())),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('support_connection_selector')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('support_model_selector')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('support_reasoning_selector')),
      findsOneWidget,
    );
    expect(find.text('Temperature'), findsOneWidget);
    await _showControl(tester, 'support_settings_max_tokens');
    expect(find.text('Лимит ответа'), findsOneWidget);
    await _showControl(tester, 'support_application_data_switch');
    expect(find.text('Доступ к данным приложения'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings controls fit a mobile-width panel', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: _PanelHost()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(SupportSettingsPanel), findsOneWidget);
    await _showControl(tester, 'support_settings_dcp');
    expect(
      find.text('Автоматическое управление контекстом (DCP)'),
      findsOneWidget,
    );
    await _showControl(tester, 'support_application_data_switch');
    expect(find.text('Доступ к данным приложения'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _PanelHost extends StatelessWidget {
  const _PanelHost();

  @override
  Widget build(BuildContext context) => Material(child: _panel());
}
