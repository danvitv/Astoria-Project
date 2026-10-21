import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_settings_panel.dart';

class _FakeWorkspace extends SupportWorkspaceNotifier {
  @override
  SupportWorkspaceState build() => const SupportWorkspaceState(
    settings: SupportAssistantSettings(),
  );
}

Widget _panel() => ProviderScope(
  overrides: [
    supportWorkspaceProvider.overrideWith(_FakeWorkspace.new),
    supportConnectionsProvider.overrideWithValue(const []),
  ],
  child: const SupportSettingsPanel(),
);

void main() {
  testWidgets('settings controls fit the narrow desktop sidebar', (tester) async {
    await tester.binding.setSurfaceSize(const Size(236, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(width: 236, child: _PanelHost()),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('support_connection_selector')), findsOneWidget);
    expect(find.byKey(const ValueKey('support_model_selector')), findsOneWidget);
    expect(find.byKey(const ValueKey('support_reasoning_selector')), findsOneWidget);
    expect(find.text('Temperature'), findsOneWidget);
    expect(find.text('Max Tokens'), findsOneWidget);
  });

  testWidgets('settings controls fit a mobile-width panel', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: _PanelHost()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(SupportSettingsPanel), findsOneWidget);
    expect(find.text('Предпочтение сжатия контекста (DCP)'), findsOneWidget);
  });
}

class _PanelHost extends StatelessWidget {
  const _PanelHost();

  @override
  Widget build(BuildContext context) => Material(child: _panel());
}
