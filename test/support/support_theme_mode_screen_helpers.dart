import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_theme_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_theme_screen_controller.dart';

import 'support_theme_screen_helpers.dart';

export 'support_theme_screen_helpers.dart';

Future<void> reviewMode(
  WidgetTester tester,
  ThemeScreenFixture fixture,
  SupportThemeScreenController controller, [
  String mode = 'light',
]) async {
  final ready = await fixture.signal(
    tester,
    () => uiReached(
      controller,
      () => !controller.busy && controller.review != null,
    ),
    label: 'original native mode review',
  );
  await tapSheet(tester, fixture, 'support_theme_mode_choice_$mode');
  await fixture.finish(tester, ready);
  await tester.pumpAndSettle();
  final preview = controller.intent!.preview(controller.review!)!;
  expect(preview.operation, SupportThemeOperation.mode);
  expect(preview.before.id, preview.after.id);
  expect(preview.after.mode, mode);
  expect(controller.originalJob, isNull);
}

Future<SupportThemeActionResult> confirmMode(
  WidgetTester tester,
  ThemeScreenFixture fixture,
  SupportThemeScreenController controller,
) async {
  await tapSheet(tester, fixture, 'support_theme_confirm');
  final fact = await fixture.finish(
    tester,
    await fixture.signal(
      tester,
      () => controller.originalJob!,
      label: 'original native mode fact',
    ),
  );
  await tester.pumpAndSettle();
  return fact;
}
