import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:glaze_flutter/core/constants/support_assistant_availability.dart';
import 'package:glaze_flutter/features/character_list/character_list_screen.dart';
import 'package:glaze_flutter/features/character_list/widgets/character_folders_section.dart';
import 'package:glaze_flutter/features/support_assistant/support_assistant_screen.dart';
import 'package:glaze_flutter/shared/shell/desktop/desktop_shell.dart';
import 'package:glaze_flutter/shared/widgets/glaze_scaffold.dart';

import 'helpers/entry_route_test_harness.dart';
import 'helpers/support_native_widget_fixture.dart';

void main() {
  setUpAll(initializeNativeWidgetLocalization);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final location in [
    '/support',
    '/support?topic=provider_setup',
    '/support?topic=',
  ]) {
    testWidgets(
      'production default redirects $location without support startup',
      (tester) async {
        final prefs = await SharedPreferences.getInstance();
        final harness = EntryRouteTestHarness(prefs: prefs, location: location);
        await harness.runOffline(tester, () async {
          tester.view.physicalSize = const Size(600, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(harness.scope());
          await tester.pumpAndSettle();
          expect(supportAssistantWorkspaceEnabled, isFalse);
          expect(
            harness.router.routeInformationProvider.value.uri.path,
            '/characters',
          );
          expect(find.byType(CharacterListScreen), findsOneWidget);
          expect(
            tester
                .widget<CharacterListScreen>(find.byType(CharacterListScreen))
                .supportAssistantAvailable,
            isFalse,
          );
          expect(find.byType(SupportAssistantScreen), findsNothing);
          expect(find.byType(AstoriaAssistantEntryButton), findsNothing);
          expect(harness.supportStarts, 0);
        });
      },
    );
  }

  final topics = <String, String?>{
    '/support': null,
    '/support?topic=': '',
    '/support?topic=provider_setup': 'provider_setup',
    '/support?topic=hello%20world%2B%D0%90%D1%81%D1%82%D0%BE%D1%80%D0%B8%D1%8F':
        'hello world+Астория',
  };
  for (final topic in topics.entries) {
    testWidgets(
      'actual enabled route forwards ${topic.key} and explicit back exits',
      (tester) async {
        final harness = EntryRouteTestHarness(
          prefs: await SharedPreferences.getInstance(),
          available: true,
          location: topic.key,
        );
        await harness.runOffline(tester, () async {
          // Narrow actual DesktopShell avoids duplicating the shell layout lane.
          tester.view.physicalSize = const Size(600, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(harness.scope());
          await tester.pumpAndSettle();
          expect(find.byType(DesktopShell), findsOneWidget);
          expect(find.byType(SupportAssistantScreen), findsOneWidget);
          final screen = tester.widget<SupportAssistantScreen>(
            find.byType(SupportAssistantScreen),
          );
          expect(screen.initialTopic, topic.value);
          expect(
            harness.workspace.topics,
            topic.value == null || topic.value!.isEmpty
                ? isEmpty
                : [topic.value],
          );
          expect(harness.supportStarts, 1);
          final scaffold = tester.widget<GlazeScaffold>(
            find.byType(GlazeScaffold),
          );
          expect(scaffold.showBack, isTrue);
          expect(scaffold.onBack, isNotNull);
          // Activate the rendered explicit back control, not just its callback.
          await tester.tap(
            find.widgetWithIcon(IconButton, Icons.arrow_back_ios_new_rounded),
          );
          await tester.pumpAndSettle();
          expect(
            harness.router.routeInformationProvider.value.uri.path,
            '/characters',
          );
          expect(find.byType(SupportAssistantScreen), findsNothing);
          expect(
            tester
                .widget<CharacterListScreen>(find.byType(CharacterListScreen))
                .supportAssistantAvailable,
            isTrue,
          );
          expect(
            find.byKey(CharacterFoldersSection.astoriaLauncherKey),
            findsOneWidget,
          );
        });
      },
    );
  }
}
