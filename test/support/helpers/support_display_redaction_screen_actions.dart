import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_composer_bar.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_model_prompt_preview_sheet.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';
import 'package:glaze_flutter/shared/widgets/sheet_view.dart';

import 'support_model_screen_fixture.dart';

const displayScreenSendKey = ValueKey('support_composer_send_btn');
const _confirm = ValueKey('support_prompt_preview_confirm');
const _cancel = ValueKey('support_prompt_preview_cancel');

TextEditingController displayScreenDraft(WidgetTester tester) => tester
    .widget<SupportComposerBar>(find.byType(SupportComposerBar))
    .controller;

/// Original bridge observation only; never completes a send/run/result.
Future<SupportModelRunView> displayScreenPhase(
  SupportModelUiBridge original,
  bool Function(SupportModelRunView) predicate,
) {
  if (predicate(original.view)) return Future.value(original.view);
  final reached = Completer<SupportModelRunView>();
  late final void Function() stop;
  stop = original.listen(() {
    if (!reached.isCompleted && predicate(original.view)) {
      stop();
      reached.complete(original.view);
    }
  });
  addTearDown(stop);
  return reached.future;
}

bool displayScreenTerminal(SupportModelRunView view) =>
    view.phase == SupportModelPhase.settled && !view.busy;

/// Only public fixture signal/action/finish drive actual async work. Pumps stay
/// in the widget zone, including the original route's exact animation duration.
Future<SupportModelPreview> displayScreenOpenPreview(
  WidgetTester tester,
  ModelScreenFixture fixture,
  String text,
) async {
  final emitted = tester
      .widget<IconButton>(find.byKey(displayScreenSendKey))
      .onPressed!;
  final original = await fixture.action(tester, () => fixture.bridge);
  final preview = await fixture.signal(
    tester,
    () => displayScreenPhase(original, (view) => view.preview != null),
    label: 'F1 original emitted Send preview',
  );
  final count = fixture.adapters.length;
  final draft = displayScreenDraft(tester);
  await fixture.action(tester, () {
    draft.text = text;
    emitted();
    emitted(); // The same emitted callback cannot append/submit twice.
  });
  final view = await fixture.finish(tester, preview);
  expect(draft.text, isEmpty);
  expect(fixture.adapters, hasLength(count));
  expect(fixture.state.isBusy, isFalse);
  await tester.pump();
  final sheet = find.byType(SupportModelPromptPreviewSheet);
  expect(sheet, findsOneWidget);
  final route = ModalRoute.of<bool>(tester.element(sheet))!;
  expect(route, isA<ModalBottomSheetRoute<bool>>());
  await tester.pump(route.transitionDuration);
  await tester.pump(const Duration(microseconds: 1));
  expect(route.animation!.status, AnimationStatus.completed);
  expect(route.isCurrent, isTrue);
  _expectWholeControl(tester, find.byKey(_cancel));
  _expectWholeControl(tester, find.byKey(_confirm));
  return view.preview!;
}

/// A full-rect check against this SheetView's actual uncovered Scrollable, not
/// merely title geometry/center visibility. No scrolling or callback shortcut.
void _expectWholeControl(WidgetTester tester, Finder control) {
  final list = find.byKey(const ValueKey('support_prompt_preview_scroll'));
  expect(control, findsOneWidget);
  expect(list, findsOneWidget);
  final owningList = find.ancestor(
    of: control,
    matching: find.byType(ListView),
  );
  expect(owningList, findsOneWidget);
  expect(tester.element(owningList), same(tester.element(list)));
  final sheet = find.ancestor(of: list, matching: find.byType(SheetView));
  expect(sheet, findsOneWidget);
  final widget = tester.widget<SheetView>(sheet);
  final title = find.descendant(
    of: sheet,
    matching: widget.titleWidget != null
        ? find.byWidget(widget.titleWidget!)
        : find.text(widget.title!),
  );
  expect(title, findsOneWidget);
  final header = find.descendant(
    of: sheet,
    matching: find.ancestor(
      of: title,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Positioned &&
            widget.top == 0 &&
            widget.left == 0 &&
            widget.right == 0 &&
            widget.bottom == null,
      ),
    ),
  );
  expect(header, findsOneWidget);
  final original = Scrollable.of(tester.element(control));
  final scrollable = find.descendant(
    of: list,
    matching: find.byElementPredicate(
      (element) => identical(element, original.context),
    ),
  );
  expect(scrollable, findsOneWidget);
  expect(original.position.hasContentDimensions, isTrue);
  final viewport = tester
      .getRect(scrollable)
      .intersect(
        Offset.zero & (tester.view.physicalSize / tester.view.devicePixelRatio),
      );
  final headerRect = tester.getRect(header);
  expect(headerRect.height, greaterThan(0));
  final visible = Rect.fromLTRB(
    viewport.left,
    headerRect.bottom > viewport.top ? headerRect.bottom : viewport.top,
    viewport.right,
    viewport.bottom,
  );
  final rect = tester.getRect(control);
  expect(visible.height, greaterThan(0));
  expect(rect.top, greaterThanOrEqualTo(visible.top));
  expect(rect.bottom, lessThanOrEqualTo(visible.bottom));
  expect(rect.left, greaterThanOrEqualTo(visible.left));
  expect(rect.right, lessThanOrEqualTo(visible.right));
  expect(control.hitTestable(), findsOneWidget);
}

Future<void> displayScreenConfirm(
  WidgetTester tester,
  ModelScreenFixture fixture,
) async {
  final sheet = find.byType(SupportModelPromptPreviewSheet);
  final route = ModalRoute.of<bool>(tester.element(sheet))!;
  final popped = await fixture.signal(
    tester,
    () => route.popped,
    label: 'F1 original keyed native Confirm gesture route result',
  );
  await fixture.action(tester, () {
    expect(route.isCurrent, isTrue);
    _expectWholeControl(tester, find.byKey(_cancel));
    _expectWholeControl(tester, find.byKey(_confirm));
    expect(
      tester.widget<GlazeActionButton>(find.byKey(_confirm)).onTap,
      isNotNull,
    );
    return tester.tap(find.byKey(_confirm));
  });
  expect(await fixture.finish(tester, popped), isTrue);
}
