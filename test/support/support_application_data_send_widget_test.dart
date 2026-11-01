import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_data_consent_admission.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_application_data_consent.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_composer_bar.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';

import 'helpers/support_model_screen_fixture.dart';

Future<void> _drive(
  WidgetTester tester,
  ModelScreenFixture fixture,
  bool Function() done,
) async {
  for (var i = 0; i < 160 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
    await fixture.action(tester, () => Future<void>.delayed(Duration.zero));
  }
  expect(done(), true);
}

Future<void> _send(
  WidgetTester tester,
  ModelScreenFixture fixture,
  String text,
) async {
  final controller = tester
      .widget<SupportComposerBar>(find.byType(SupportComposerBar))
      .controller;
  await fixture.action(tester, () => controller.text = text);
  await tester.pump();
  final callback = tester
      .widget<IconButton>(
        find.byKey(const ValueKey('support_composer_send_btn')),
      )
      .onPressed;
  expect(callback, isNotNull);
  // This starts a user interaction awaiting the consent sheet. Do not join the
  // returned async Send before the test has a chance to answer that sheet.
  await fixture.action(tester, () {
    callback!();
  });
}

Future<void> _decide(
  WidgetTester tester,
  ModelScreenFixture fixture,
  bool accept,
) async {
  await _drive(
    tester,
    fixture,
    () => find.byType(SupportApplicationDataConsentSheet).evaluate().isNotEmpty,
  );
  // Send deliberately remains busy while awaiting this sheet. Let its entrance
  // finish, but do not wait for the composer's progress animation to stop before
  // the user has answered. Keep the exact sheet/callback and completion checks.
  await tester.pump(const Duration(milliseconds: 400));
  final key = ValueKey(
    accept
        ? 'support_application_data_consent_accept'
        : 'support_application_data_consent_decline',
  );
  await tester.ensureVisible(find.byKey(key));
  final callback = tester.widget<GlazeActionButton>(find.byKey(key)).onTap;
  expect(callback, isNotNull);
  await fixture.action(tester, callback!);
  await _drive(
    tester,
    fixture,
    () => fixture.adapters.isNotEmpty && !fixture.bridge.view.busy,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('consent never sends a draft changed while the sheet is open', (
    tester,
  ) async {
    final fixture = ModelScreenFixture(confirm: false);
    fixture.isolation.extraAllowed.add(supportDataConsentAdmissionProvider);
    await fixture.run(tester, () async {
      await _send(tester, fixture, 'сравни последние две сессии');
      await _drive(
        tester,
        fixture,
        () => find
            .byType(SupportApplicationDataConsentSheet)
            .evaluate()
            .isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 400));
      final controller = tester
          .widget<SupportComposerBar>(find.byType(SupportComposerBar))
          .controller;
      await fixture.action(tester, () => controller.text = 'Новый черновик');
      final callback = tester
          .widget<GlazeActionButton>(
            find.byKey(
              const ValueKey('support_application_data_consent_accept'),
            ),
          )
          .onTap;
      expect(callback, isNotNull);
      await fixture.action(tester, callback!);
      await _drive(
        tester,
        fixture,
        () =>
            find
                .byType(SupportApplicationDataConsentSheet)
                .evaluate()
                .isEmpty &&
            fixture.container
                    .read(supportNativeRuntimeProvider)
                    .snapshot
                    .preferences
                    ?.allows(SupportPermission.readApplicationData) ==
                true,
      );
      await tester.pumpAndSettle();
      expect(controller.text, 'Новый черновик');
      expect(fixture.adapters, isEmpty);
    });
  });
  for (final accept in [true, false]) {
    testWidgets(
      'first Send ${accept ? 'grants once' : 'declines once'}; later sends and another chat have no read dialogs',
      (tester) async {
        final fixture = ModelScreenFixture(confirm: false);
        fixture.isolation.extraAllowed.add(supportDataConsentAdmissionProvider);
        await fixture.run(tester, () async {
          expect(find.byType(SupportApplicationDataConsentSheet), findsNothing);
          await _send(tester, fixture, 'сравни последние две сессии');
          await _decide(tester, fixture, accept);
          final runtime = fixture.container.read(supportNativeRuntimeProvider);
          expect(
            runtime.snapshot.preferences?.allows(
              SupportPermission.readApplicationData,
            ),
            accept,
          );
          expect(find.byType(SupportApplicationDataConsentSheet), findsNothing);
          expect(
            tester
                .widget<SupportComposerBar>(find.byType(SupportComposerBar))
                .controller
                .text,
            isEmpty,
          );
          final count = fixture.adapters.length;
          await _send(
            tester,
            fixture,
            'посмотри последнюю сессию и сохранённый Studio preset',
          );
          await _drive(
            tester,
            fixture,
            () => fixture.adapters.length > count && !fixture.bridge.view.busy,
          );
          expect(find.byType(SupportApplicationDataConsentSheet), findsNothing);
          await fixture.action(
            tester,
            () => fixture.workspace.selectSession(ModelScreenFixture.other),
          );
          await _drive(
            tester,
            fixture,
            () =>
                fixture.state.activeSessionId == ModelScreenFixture.other &&
                !fixture.state.isLoading,
          );
          await tester.pumpAndSettle();
          // The shared model profile and read decision survive assistant-chat selection.
          final secondCount = fixture.adapters.length;
          await _send(tester, fixture, 'помоги сравнить сессии');
          await _drive(
            tester,
            fixture,
            () =>
                fixture.adapters.length > secondCount &&
                !fixture.bridge.view.busy,
          );
          expect(find.byType(SupportApplicationDataConsentSheet), findsNothing);
        });
      },
    );
  }
}
