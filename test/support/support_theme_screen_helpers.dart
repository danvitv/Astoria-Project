import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_theme_controls.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_theme_screen_controller.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_theme_sheet.dart';
import 'package:glaze_flutter/shared/widgets/sheet_view.dart';

import 'support_theme_screen_fixture.dart';

export 'support_theme_screen_fixture.dart';

SupportThemeScreenController themeUi(WidgetTester tester) =>
    tester.widget<SupportThemeSheet>(find.byType(SupportThemeSheet)).controller;

Future<void> uiReached(
  SupportThemeScreenController original,
  bool Function() ready,
) {
  if (ready()) return Future.value();
  final reached = Completer<void>();
  late final VoidCallback listener;
  listener = () {
    if (!reached.isCompleted && ready()) {
      original.removeListener(listener);
      reached.complete();
    }
  };
  original.addListener(listener);
  addTearDown(() => original.removeListener(listener));
  return reached.future;
}

Future<void> runtimeReached(ThemeScreenFixture f, bool Function() ready) {
  final original = f.runtime;
  if (ready()) return Future.value();
  final reached = Completer<void>();
  late final VoidCallback stop;
  stop = original.listen(() {
    if (!reached.isCompleted && ready()) {
      stop();
      reached.complete();
    }
  });
  addTearDown(stop);
  return reached.future;
}

/// A nested tab strip is not the Scrollable built by this exact ListView.
Finder _outerScrollable(WidgetTester tester, Finder list) {
  expect(list, findsOneWidget);
  final original = tester.element(list);
  final scrollable = find.descendant(
    of: list,
    matching: find.byElementPredicate((element) {
      if (element.widget is! Scrollable) return false;
      var owns = false;
      element.visitAncestorElements((ancestor) {
        if (identical(ancestor, original)) {
          owns = true;
          return false;
        }
        return ancestor.widget is! Scrollable && ancestor.widget is! ListView;
      });
      return owns;
    }),
  );
  expect(scrollable, findsOneWidget);
  return scrollable;
}

Rect _visible(WidgetTester tester, Finder list, Finder scrollable) {
  final sheet = find.ancestor(of: list, matching: find.byType(SheetView));
  expect(sheet, findsOneWidget);
  final widget = tester.widget<SheetView>(sheet);
  final title = find.descendant(of: sheet, matching: find.text(widget.title!));
  expect(title, findsOneWidget);
  final header = find.descendant(
    of: sheet,
    matching: find.ancestor(
      of: title,
      matching: find.byWidgetPredicate(
        (w) =>
            w is Positioned &&
            w.top == 0 &&
            w.left == 0 &&
            w.right == 0 &&
            w.bottom == null,
      ),
    ),
  );
  expect(header, findsOneWidget);
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
  expect(visible.height, greaterThan(0));
  return visible;
}

/// Whole control, whole positioned header, and root-clipped exact viewport.
({Rect control, Rect visible, Finder scrollable}) bounds(
  WidgetTester tester,
  Finder control,
  Finder list,
) {
  expect(control, findsOneWidget);
  final owner = find.ancestor(of: control, matching: find.byType(ListView));
  expect(owner, findsOneWidget);
  expect(tester.element(owner), same(tester.element(list)));
  final scrollable = _outerScrollable(tester, list);
  final original = tester.state<ScrollableState>(scrollable);
  expect(Scrollable.of(tester.element(control)), same(original));
  expect(original.position.hasContentDimensions, isTrue);
  return (
    control: tester.getRect(control),
    visible: _visible(tester, list, scrollable),
    scrollable: scrollable,
  );
}

void fullControl(WidgetTester tester, Finder control, Finder list) {
  expect(control, findsOneWidget);
  if (find
      .ancestor(of: control, matching: find.byType(ListView))
      .evaluate()
      .isEmpty) {
    _fixedControl(tester, control);
    return;
  }
  final b = bounds(tester, control, list);
  expect(b.control.top, greaterThanOrEqualTo(b.visible.top));
  expect(b.control.bottom, lessThanOrEqualTo(b.visible.bottom));
  expect(b.control.left, greaterThanOrEqualTo(b.visible.left));
  expect(b.control.right, lessThanOrEqualTo(b.visible.right));
  expect(control.hitTestable(), findsOneWidget);
}

void _fixedControl(WidgetTester tester, Finder control) {
  expect(control.hitTestable(), findsOneWidget);
  final owner = find.ancestor(of: control, matching: find.byType(SheetView));
  expect(owner, findsOneWidget);
  final rect = tester.getRect(control), sheet = tester.getRect(owner);
  expect(rect.top, greaterThanOrEqualTo(sheet.top));
  expect(
    rect.bottom,
    lessThanOrEqualTo(
      sheet.bottom -
          tester.view.viewInsets.bottom / tester.view.devicePixelRatio,
    ),
  );
  expect(rect.left, greaterThanOrEqualTo(sheet.left));
  expect(rect.right, lessThanOrEqualTo(sheet.right));
}

Future<void> _scrollBy(
  WidgetTester tester,
  ThemeScreenFixture fixture,
  Finder scrollable,
  Rect visible,
  double distance,
) async {
  final original = tester.state<ScrollableState>(scrollable);
  expect(original.widget.axisDirection, AxisDirection.down);
  final before = original.position.pixels;
  // Flutter dragFrom consumes its first kDragSlopDefault move when the native
  // recognizer uses DragStartBehavior.start. Keep BOTH moves inside the viewport.
  final room = visible.height / 2 - kDragSlopDefault;
  expect(room, greaterThan(0));
  final travel = distance.clamp(-room, room).toDouble();
  expect(travel.abs(), greaterThan(0));
  await fixture.gesture(tester, () {
    expect(
      tester
          .hitTestOnBinding(visible.center)
          .path
          .any(
            (entry) => identical(entry.target, tester.renderObject(scrollable)),
          ),
      isTrue,
      reason: 'Gesture must hit original Scrollable.',
    );
    return tester.dragFrom(
      visible.center,
      Offset(0, travel + travel.sign * kDragSlopDefault),
    );
  });
  await tester
      .pumpAndSettle(); // Fake frames follow the original gesture guard.
  expect(tester.state<ScrollableState>(scrollable), same(original));
  expect(
    (before - original.position.pixels) * travel.sign,
    greaterThan(0),
    reason: 'Original Scrollable must make measured directional progress.',
  );
}

Future<void> reveal(
  WidgetTester tester,
  ThemeScreenFixture fixture,
  Finder control,
  Finder list,
) async {
  if (control.evaluate().isNotEmpty &&
      find
          .ancestor(of: control, matching: find.byType(ListView))
          .evaluate()
          .isEmpty) {
    // Only a MOUNTED control without a list owner can be fixed chrome. An
    // absent lazy row still needs the original finite ListView traversal.
    _fixedControl(tester, control);
    return;
  }
  final scrollable = _outerScrollable(tester, list);
  final original = tester.state<ScrollableState>(scrollable);
  final row = find.descendant(of: list, matching: control);
  // These product ListViews have finite original child delegates. Search at
  // most one backward and one forward traversal, bounded by their REAL extents.
  expect(
    tester.widget<ListView>(list).childrenDelegate.estimatedChildCount,
    isNotNull,
  );
  for (final towardStart in [true, false]) {
    while (row.evaluate().isEmpty) {
      expect(original.position.hasContentDimensions, isTrue);
      final edge = towardStart
          ? original.position.minScrollExtent
          : original.position.maxScrollExtent;
      expect(edge.isFinite, isTrue);
      final distance = original.position.pixels - edge;
      if (distance == 0) break;
      await _scrollBy(
        tester,
        fixture,
        scrollable,
        _visible(tester, list, scrollable),
        distance,
      );
    }
  }
  expect(row, findsOneWidget);
  int? remaining;
  double? previousGap;
  do {
    final b = bounds(tester, row, list);
    expect(tester.state<ScrollableState>(b.scrollable), same(original));
    if (b.control.top >= b.visible.top &&
        b.control.bottom <= b.visible.bottom) {
      fullControl(tester, row, list);
      return;
    }
    expect(b.control.height, lessThanOrEqualTo(b.visible.height));
    expect(b.control.left, greaterThanOrEqualTo(b.visible.left));
    expect(b.control.right, lessThanOrEqualTo(b.visible.right));
    final position = original.position;
    final low = position.pixels + b.control.bottom - b.visible.bottom;
    final high = position.pixels + b.control.top - b.visible.top;
    expect(
      low,
      lessThanOrEqualTo(position.maxScrollExtent),
      reason: 'Product scroll extent must expose the WHOLE control bottom.',
    );
    expect(
      high,
      greaterThanOrEqualTo(position.minScrollExtent),
      reason: 'Product scroll extent must expose the WHOLE control top.',
    );
    final target = ((low + high) / 2)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    final gap = b.control.top < b.visible.top
        ? b.visible.top - b.control.top
        : b.control.bottom - b.visible.bottom;
    if (previousGap != null) expect(gap, lessThan(previousGap));
    previousGap = gap;
    final room = b.visible.height / 2 - kDragSlopDefault;
    expect(room, greaterThan(0));
    remaining ??= ((position.pixels - target).abs() / room).ceil() + 1;
    await _scrollBy(
      tester,
      fixture,
      scrollable,
      b.visible,
      position.pixels - target,
    );
    remaining--;
  } while (remaining > 0);
  fullControl(tester, row, list);
}

Future<void> tapSheet(
  WidgetTester tester,
  ThemeScreenFixture fixture,
  String id, {
  String list = 'support_theme_scroll',
}) async {
  final control = find.byKey(ValueKey(id));
  final owner = find.byKey(ValueKey(list));
  await reveal(tester, fixture, control, owner);
  await fixture.gesture(tester, () {
    fullControl(tester, control, owner);
    return tester.tap(control);
  });
}

Future<void> routeEndpoint(WidgetTester tester, Finder sheet) async {
  await tester.pump(); // FIRST ticker frame, then OWN actual duration.
  final route = ModalRoute.of(tester.element(sheet))!;
  await tester.pump(route.transitionDuration);
  await tester.pump(const Duration(microseconds: 1));
  expect(route.animation!.status, AnimationStatus.completed);
  expect(route.isCurrent, isTrue);
}

Future<SupportThemeScreenController> openThemes(
  WidgetTester tester,
  ThemeScreenFixture f,
) async {
  final toggle = find.byKey(const ValueKey('support_drawer_toggle'));
  if (toggle.evaluate().isNotEmpty &&
      !tester.widget<IconButton>(toggle).isSelected!) {
    await f.gesture(tester, () => tester.tap(toggle));
    await tester.pumpAndSettle();
  }
  final entry = find.byKey(const ValueKey('support_theme_open'));
  expect(entry.hitTestable(), findsOneWidget);
  final rect = tester.getRect(entry);
  expect(rect.isEmpty, isFalse);
  await f.gesture(tester, () => tester.tap(entry));
  await routeEndpoint(tester, find.byType(SupportThemeSheet));
  return themeUi(tester);
}

Future<void> readThemes(
  WidgetTester tester,
  ThemeScreenFixture f,
  SupportThemeScreenController c,
) async {
  final reached = await f.signal(
    tester,
    () => uiReached(c, () => !c.busy && c.observation != null),
    label: 'original installed observation',
  );
  await tapSheet(tester, f, 'support_theme_refresh');
  await f.finish(tester, reached);
  await tester.pumpAndSettle();
}

Future<void> reviewTheme(
  WidgetTester tester,
  ThemeScreenFixture f,
  SupportThemeScreenController c, {
  String id = 'b',
}) async {
  final reached = await f.signal(
    tester,
    () => uiReached(c, () => !c.busy && c.review != null),
    label: 'original opaque exact review',
  );
  await tapSheet(tester, f, 'support_theme_choice_$id');
  await f.finish(tester, reached);
  await tester.pumpAndSettle();
  final list = find.byKey(const ValueKey('support_theme_scroll'));
  final confirm = find.byKey(const ValueKey('support_theme_confirm'));
  await reveal(tester, f, confirm, list);
  expect(tester.widget<SupportThemeButton>(confirm).onTap, isNotNull);
}
