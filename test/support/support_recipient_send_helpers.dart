import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_composer_bar.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_privacy_review_sheet.dart';

import 'helpers/support_model_screen_fixture.dart';

Future<void> recipientUiUntil(
  WidgetTester tester,
  ModelScreenFixture f,
  bool Function() ready,
) async {
  for (var turn = 0; turn < 100 && !ready(); turn++) {
    await tester.pump();
    await f.action(tester, () => Future<void>.delayed(Duration.zero));
  }
  expect(ready(), isTrue, reason: 'Original recipient UI did not settle.');
}

Future<ModalRoute<bool>> openRecipientFromSend(
  WidgetTester tester,
  ModelScreenFixture f, {
  String text = 'Привет, расскажи о себе',
  bool viaEnter = false,
}) async {
  await tester
      .pump(); // Act on the freshly displayed owner after native changes.
  final draft = tester
      .widget<SupportComposerBar>(find.byType(SupportComposerBar))
      .controller;
  await f.action(tester, () async {
    draft.text = text;
    if (viaEnter) {
      await tester.tap(find.byKey(const ValueKey('support_composer_input')));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    } else {
      await tester.tap(find.byKey(const ValueKey('support_composer_send_btn')));
    }
  });
  await recipientUiUntil(
    tester,
    f,
    () => find.byType(SupportPrivacyReviewSheet).evaluate().isNotEmpty,
  );
  final route = ModalRoute.of<bool>(
    tester.element(find.byType(SupportPrivacyReviewSheet)),
  )!;
  await tester.pump();
  await tester.pump(route.transitionDuration + const Duration(microseconds: 1));
  return route;
}

Future<Finder> revealRecipientDecision(
  WidgetTester tester, {
  required bool confirmed,
}) async {
  final button = find.byKey(
    ValueKey(
      confirmed
          ? 'support_privacy_review_confirm'
          : 'support_privacy_review_cancel',
    ),
  );
  final list = find.descendant(
    of: find.byType(SupportPrivacyReviewSheet),
    matching: find.byType(Scrollable),
  );
  if (button.evaluate().isEmpty) {
    await tester.scrollUntilVisible(button, 150, scrollable: list);
  }
  await Scrollable.ensureVisible(tester.element(button), alignment: 0.5);
  await tester.pump();
  expect(button.hitTestable(), findsOneWidget);
  return button;
}

Future<void> decideRecipient(
  WidgetTester tester,
  ModelScreenFixture f,
  ModalRoute<bool> route, {
  required bool confirmed,
}) async {
  final button = await revealRecipientDecision(tester, confirmed: confirmed);
  final popped = await f.signal(
    tester,
    () => route.popped,
    label: 'original recipient decision result',
  );
  await f.action(tester, () => tester.tap(button));
  expect(await f.finish(tester, popped), confirmed);
  await tester.pump(); // Establish the reverse ticker's first frame.
  await tester.pump(
    route.reverseTransitionDuration + const Duration(microseconds: 1),
  );
  await recipientUiUntil(
    tester,
    f,
    () =>
        tester
                .widget<IconButton>(
                  find.byKey(const ValueKey('support_composer_send_btn')),
                )
                .onPressed !=
            null &&
        find.byType(SupportPrivacyReviewSheet).evaluate().isEmpty,
  );
}

Future<SupportModelRunView> recipientModelPhase(
  ModelScreenFixture f,
  bool Function(SupportModelRunView) reached,
) {
  final original = f.bridge;
  if (reached(original.view)) return Future.value(original.view);
  final result = Completer<SupportModelRunView>();
  late final void Function() stop;
  stop = original.listen(() {
    if (reached(original.view) && !result.isCompleted) {
      stop();
      result.complete(original.view);
    }
  });
  addTearDown(stop);
  return result.future;
}
