import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_model_prompt_preview_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_plain_markdown.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';
import 'package:glaze_flutter/shared/widgets/sheet_view.dart';

import 'helpers/support_prompt_preview_fixture.dart';

const _cancel = 'support_prompt_preview_cancel';
const _confirm = 'support_prompt_preview_confirm';
const _canary = 'SYNTHETIC-PREVIEW-ONLY';

SupportPromptPreviewValues _values({
  String origin = 'preview.example.invalid:18443',
  String operation = 'Text generation',
  String model = 'synthetic-model-distinct-tail',
  int gameCount = 2,
  int supportCount = 3,
  List<SupportPromptPreviewSection>? sections,
}) => SupportPromptPreviewValues(
  originLabel: origin,
  operationLabel: operation,
  modelLabel: model,
  gameMessageCount: gameCount,
  supportMessageCount: supportCount,
  sections:
      sections ??
      [
        for (final role in SupportPromptPreviewRole.values)
          SupportPromptPreviewSection(role: role, text: '$role $_canary'),
      ],
);

GlazeActionButton _button(WidgetTester tester, String key) =>
    tester.widget<GlazeActionButton>(find.byKey(ValueKey(key)));

List<SupportPromptPreviewSection> _shortSections(int count) => List.generate(
  count,
  (index) => SupportPromptPreviewSection(
    role: SupportPromptPreviewRole.values[index % 3],
    text: 'section-$index $_canary',
  ),
);

Future<List<bool?>> _open(
  WidgetTester tester,
  SupportPromptPreviewFixture fixture, {
  required List<bool> decisions,
  required bool Function() isCurrent,
  SupportPromptPreviewValues? values,
  double scale = 1,
  bool closeOnDecision = true,
  ValueChanged<bool>? onDecisionObserved,
}) async {
  final results = <bool?>[];
  final capturedValues = values ?? _values();
  await tester.pumpWidget(
    fixture.host(
      Builder(
        builder: (context) => Center(
          child: TextButton(
            key: const ValueKey('open_preview'),
            onPressed: () {
              showModalBottomSheet<bool>(
                context: context,
                useRootNavigator: true,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (sheetContext) => SupportModelPromptPreviewSheet(
                  values: capturedValues,
                  isCurrent: isCurrent,
                  onDecision: (decision) {
                    decisions.add(decision);
                    onDecisionObserved?.call(decision);
                    if (closeOnDecision) {
                      Navigator.of(sheetContext).pop(decision);
                    }
                  },
                ),
              ).then(results.add);
            },
            child: const Text('Open synthetic preview'),
          ),
        ),
      ),
      scale: scale,
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('open_preview')));
  await tester.pumpAndSettle();
  expect(find.byType(BackdropFilter), findsNothing);
  expect(find.byType(Image), findsNothing);
  expect(find.byType(RawImage), findsNothing);
  expect(tester.takeException(), isNull);
  return results;
}

Finder _bodyScrollable(WidgetTester tester) {
  final body = find.byKey(const ValueKey('support_prompt_preview_scroll'));
  expect(body, findsOneWidget);
  final bodyElement = tester.element(body);
  expect(bodyElement.widget, isA<ListView>());

  // Selection editors can also scroll vertically. Only the body's own
  // Scrollable reaches this exact ListView without another Scrollable ancestor.
  final scrollable = find.descendant(
    of: body,
    matching: find.byElementPredicate((element) {
      final widget = element.widget;
      if (widget is! Scrollable ||
          axisDirectionToAxis(widget.axisDirection) != Axis.vertical) {
        return false;
      }
      var ownsBody = false;
      element.visitAncestorElements((ancestor) {
        if (identical(ancestor, bodyElement)) {
          ownsBody = true;
          return false;
        }
        return ancestor.widget is! Scrollable;
      });
      return ownsBody;
    }, description: 'outer vertical prompt-preview body Scrollable'),
  );
  expect(
    scrollable,
    findsOneWidget,
    reason: 'The keyed body must own exactly one outer vertical Scrollable.',
  );
  return scrollable;
}

Future<void> _show(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    350,
    scrollable: _bodyScrollable(tester),
    maxScrolls: 200,
  );
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Offset _visibleGlyphPoint(WidgetTester tester, Finder editorFinder) {
  expect(editorFinder, findsOneWidget);
  final editor = tester.state<EditableTextState>(editorFinder);
  final RenderEditable render = editor.renderEditable;
  final viewport = find.descendant(
    of: _bodyScrollable(tester),
    matching: find.byType(Viewport),
  );
  expect(viewport, findsOneWidget);
  final sheet = find.ancestor(
    of: editorFinder,
    matching: find.byType(SheetView),
  );
  expect(sheet, findsOneWidget);
  final header = find.ancestor(
    of: find.byKey(const ValueKey('support_prompt_preview_header')),
    matching: find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString() == '_SheetViewHeader',
    ),
  );
  expect(header, findsOneWidget);
  final sheetRect = tester.getRect(sheet);
  final viewportRect = tester.getRect(viewport);
  final editorRect = tester.getRect(editorFinder);
  final renderRect = Rect.fromPoints(
    render.localToGlobal(Offset.zero),
    render.localToGlobal(render.size.bottomRight(Offset.zero)),
  );
  final unobscuredSheet = Rect.fromLTRB(
    sheetRect.left,
    tester.getRect(header).bottom,
    sheetRect.right,
    sheetRect.bottom,
  );
  final visible = editorRect
      .intersect(renderRect)
      .intersect(viewportRect)
      .intersect(unobscuredSheet);
  expect(
    visible.isEmpty,
    false,
    reason: 'The editor must have visible text area.',
  );

  // Pick the earliest rendered ASCII letter with visible glyph area, not an
  // editor corner: ensureVisible can align tall editors behind the sheet header.
  final letters = RegExp('[A-Za-z]').allMatches(editor.widget.controller.text);
  for (final letter in letters) {
    for (final box in render.getBoxesForSelection(
      TextSelection(baseOffset: letter.start, extentOffset: letter.end),
    )) {
      // These bounds include the editor's paint/scroll offset.
      final localGlyph = box.toRect();
      final glyph = Rect.fromPoints(
        render.localToGlobal(localGlyph.topLeft),
        render.localToGlobal(localGlyph.bottomRight),
      );
      final clippedGlyph = glyph.intersect(visible);
      if (clippedGlyph.isEmpty) continue;
      final point = clippedGlyph.center;
      expect(glyph.contains(point), true);
      expect(editorRect.contains(point), true);
      expect(renderRect.contains(point), true);
      expect(viewportRect.contains(point), true);
      expect(unobscuredSheet.contains(point), true);
      expect(
        tester
            .hitTestOnBinding(point)
            .path
            .any((hit) => identical(hit.target, render)),
        true,
        reason:
            'The visible glyph must hit this exact editor, not chrome or another section.',
      );
      return point;
    }
  }
  fail(
    'No rendered letter intersects the editor and unobscured sheet viewport.',
  );
}

void _textOnly(TextSpan span) {
  expect(span.recognizer, isNull);
  expect(span.onEnter, isNull);
  expect(span.onExit, isNull);
  for (final child in span.children ?? const <InlineSpan>[]) {
    expect(child, isA<TextSpan>());
    _textOnly(child as TextSpan);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'values are exact, immutable, bounded and independent of source mutation',
    () {
      const text = '  $_canary\r\n🙂 **literal source**\t';
      final sections = [
        SupportPromptPreviewSection(
          role: SupportPromptPreviewRole.user,
          text: text,
        ),
      ];
      final values = _values(sections: sections);
      sections.clear();
      expect(values.sections.single.text, text);
      expect(values.textLength, text.length);
      expect(() => values.sections.clear(), throwsUnsupportedError);
      expect(values.originLabel, 'preview.example.invalid:18443');
      final maximum = SupportPromptPreviewSection(
        role: SupportPromptPreviewRole.system,
        text: 'x' * SupportPlainMarkdown.maxTextLength,
      );
      expect(_values(sections: [maximum]).textLength, 65536);
      expect(
        () => _values(sections: List.filled(4, maximum)),
        throwsArgumentError,
      );
      expect(
        () => _values(sections: List.filled(5, maximum)),
        throwsArgumentError,
      );
      expect(_values(sections: _shortSections(33)).sections.length, 33);
      expect(
        () => SupportPromptPreviewSection(
          role: SupportPromptPreviewRole.system,
          text: 'x' * (SupportPlainMarkdown.maxTextLength + 1),
        ),
        throwsArgumentError,
      );
      expect(_values(sections: []).sections, isEmpty);
      expect(_values(gameCount: 0, supportCount: 512).supportMessageCount, 512);
      expect(_values(gameCount: 512, supportCount: 0).gameMessageCount, 512);
      for (final invalid in [-1, 513]) {
        expect(() => _values(gameCount: invalid), throwsArgumentError);
        expect(() => _values(supportCount: invalid), throwsArgumentError);
      }
    },
  );

  test(
    '514 exact short sections are admitted; 515 are refused without truncation',
    () {
      final sections = _shortSections(514);
      final values = _values(sections: sections);
      expect(SupportPromptPreviewValues.maxSections, 514);
      expect(values.sections.length, 514);
      expect(values.textLength, lessThan(65536));
      expect(
        values.sections.map((section) => section.text),
        orderedEquals(sections.map((section) => section.text)),
      );
      expect(
        values.sections.map((section) => section.role),
        orderedEquals(sections.map((section) => section.role)),
      );
      sections.clear();
      expect(values.sections.length, 514);
      expect(values.sections.last.text, 'section-513 $_canary');
      expect(() => values.sections.clear(), throwsUnsupportedError);
      final oversized = _shortSections(515);
      expect(
        oversized.fold<int>(0, (sum, section) => sum + section.text.length),
        lessThan(65536),
      );
      expect(() => _values(sections: oversized), throwsArgumentError);
    },
  );

  test('65536 UTF-16 body is admitted; 65537 aggregate input is refused', () {
    expect(SupportPromptPreviewValues.maxTotalTextLength, 65536);
    expect(SupportPromptPreviewValues.maxMessageCount, 512);
    final exactBody = '🙂' * 32768;
    expect(exactBody.length, 65536);
    final section = SupportPromptPreviewSection(
      role: SupportPromptPreviewRole.user,
      text: exactBody,
    );
    final values = _values(
      sections: [section],
      gameCount: 512,
      supportCount: 512,
    );
    expect(values.textLength, 65536);
    expect(values.sections.single.text, exactBody);
    final extra = SupportPromptPreviewSection(
      role: SupportPromptPreviewRole.assistant,
      text: 'x',
    );
    expect(section.text.length + extra.text.length, 65537);
    expect(() => _values(sections: [section, extra]), throwsArgumentError);
    expect(
      () => SupportPromptPreviewSection(
        role: SupportPromptPreviewRole.user,
        text: '${exactBody}x',
      ),
      throwsArgumentError,
    );
  });

  test('safe-label admission never truncates or leaks rejected inputs', () {
    final long = 'x' * SupportPromptPreviewValues.maxLabelLength;
    expect(_values(origin: long, model: long).originLabel, long);
    for (final invalid in [
      '',
      ' $_canary',
      '$_canary ',
      '$_canary\n',
      '$_canary\u0000',
      '$_canary\u202e',
      '$_canary\u200b',
      '$long$_canary',
    ]) {
      for (final make in [
        () => _values(origin: invalid),
        () => _values(operation: invalid),
        () => _values(model: invalid),
      ]) {
        expect(
          make,
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.toString(),
              'fixed non-input error',
              isNot(contains(_canary)),
            ),
          ),
        );
      }
    }
  });

  testWidgets(
    'Confirm emits one explicit decision after a synchronous current check',
    (tester) async {
      final fixture = SupportPromptPreviewFixture();
      await fixture.run(tester, () async {
        final events = <String>[];
        final decisions = <bool>[];
        final results = await _open(
          tester,
          fixture,
          decisions: decisions,
          isCurrent: () {
            events.add('check');
            return true;
          },
          onDecisionObserved: (_) => events.add('decision'),
        );
        final retained = _button(tester, _confirm).onTap!;
        events.clear();
        await tester.tap(find.byKey(const ValueKey(_confirm)));
        expect(events, ['check', 'decision']);
        expect(decisions, [true]);
        retained();
        await tester.pumpAndSettle();
        retained();
        expect(decisions, [true]);
        expect(results, [true]);
      });
    },
  );

  for (final exit in ['Cancel', 'header Back']) {
    testWidgets(
      '$exit explicitly declines; retained confirmation cannot escape',
      (tester) async {
        final fixture = SupportPromptPreviewFixture();
        await fixture.run(tester, () async {
          final decisions = <bool>[];
          final results = await _open(
            tester,
            fixture,
            decisions: decisions,
            isCurrent: () => true,
          );
          final retained = _button(tester, _confirm).onTap!;
          switch (exit) {
            case 'Cancel':
              await tester.tap(find.byKey(const ValueKey(_cancel)));
            case 'header Back':
              await tester.tap(find.byIcon(Icons.arrow_back));
          }
          retained();
          await tester.pumpAndSettle();
          expect(decisions, [false]);
          expect(results, [false]);
        });
      },
    );
  }

  for (final exit in ['external pop', 'barrier', 'system Back', 'dispose']) {
    testWidgets('$exit emits no decision, including retained taps', (
      tester,
    ) async {
      final fixture = SupportPromptPreviewFixture();
      await fixture.run(tester, () async {
        await tester.binding.setSurfaceSize(const Size(360, 800));
        final decisions = <bool>[];
        final results = await _open(
          tester,
          fixture,
          decisions: decisions,
          isCurrent: () => true,
        );
        final retained = _button(tester, _confirm).onTap!;
        switch (exit) {
          case 'external pop':
            fixture.navigatorKey.currentState!.pop();
          case 'barrier':
            await tester.tapAt(const Offset(8, 8));
          case 'system Back':
            await tester.binding.handlePopRoute();
          case 'dispose':
            await tester.pumpWidget(const SizedBox.shrink());
        }
        retained();
        await tester.pumpAndSettle();
        retained();
        expect(decisions, isEmpty);
        if (exit != 'dispose') expect(results, [null]);
      });
      await tester.binding.setSurfaceSize(null);
    });
  }

  testWidgets(
    'staleness after build is checked at tap and permanently disables Confirm',
    (tester) async {
      final fixture = SupportPromptPreviewFixture();
      await fixture.run(tester, () async {
        var current = true;
        final decisions = <bool>[];
        await _open(
          tester,
          fixture,
          decisions: decisions,
          isCurrent: () => current,
        );
        final retained = _button(tester, _confirm).onTap!;
        current =
            false; // No rebuild; the enabled closure must still check now.
        retained();
        await tester.pumpAndSettle();
        expect(decisions, isEmpty);
        expect(_button(tester, _confirm).onTap, isNull);
        current = true;
        retained();
        expect(decisions, isEmpty);
        await tester.tap(find.byKey(const ValueKey(_cancel)));
        expect(decisions, [false]);
      });
    },
  );

  testWidgets(
    'duplicate and reentrant decisions are once-only even without caller pop',
    (tester) async {
      final fixture = SupportPromptPreviewFixture();
      await fixture.run(tester, () async {
        final decisions = <bool>[];
        late VoidCallback retained;
        await _open(
          tester,
          fixture,
          decisions: decisions,
          isCurrent: () => true,
          closeOnDecision: false,
          onDecisionObserved: (_) => retained(),
        );
        retained = _button(tester, _confirm).onTap!;
        retained();
        retained();
        await tester.pumpAndSettle();
        expect(decisions, [true]);
        expect(_button(tester, _confirm).onTap, isNull);
        expect(_button(tester, _cancel).onTap, isNull);
      });
    },
  );

  testWidgets(
    'predicate reentry or route closure cannot emit a late confirmation',
    (tester) async {
      final fixture = SupportPromptPreviewFixture();
      await fixture.run(tester, () async {
        final decisions = <bool>[];
        late VoidCallback retained;
        var onFinalCheck = false;
        await _open(
          tester,
          fixture,
          decisions: decisions,
          isCurrent: () {
            if (onFinalCheck) {
              retained(); // Guarded while the synchronous predicate is running.
              fixture.navigatorKey.currentState!.pop();
            }
            return true;
          },
        );
        retained = _button(tester, _confirm).onTap!;
        onFinalCheck = true;
        retained();
        await tester.pumpAndSettle();
        retained();
        expect(decisions, isEmpty);
      });
    },
  );

  testWidgets(
    'initially stale preview has Cancel and Back but no enabled Confirm',
    (tester) async {
      final fixture = SupportPromptPreviewFixture();
      await fixture.run(tester, () async {
        final decisions = <bool>[];
        await _open(
          tester,
          fixture,
          decisions: decisions,
          isCurrent: () => false,
        );
        expect(_button(tester, _confirm).onTap, isNull);
        expect(_button(tester, _cancel).onTap, isNotNull);
        expect(find.byIcon(Icons.arrow_back).hitTestable(), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey(_cancel)));
        await tester.pumpAndSettle();
        expect(decisions, [false]);
      });
    },
  );

  testWidgets(
    'a failed predicate denies confirmation without exposing exception data',
    (tester) async {
      final fixture = SupportPromptPreviewFixture();
      await fixture.run(tester, () async {
        var fail = false;
        final decisions = <bool>[];
        await _open(
          tester,
          fixture,
          decisions: decisions,
          isCurrent: () {
            if (fail) throw StateError(_canary);
            return true;
          },
        );
        final retained = _button(tester, _confirm).onTap!;
        fail = true;
        retained();
        await tester.pumpAndSettle();
        expect(decisions, isEmpty);
        expect(_button(tester, _confirm).onTap, isNull);
        expect(find.textContaining('StateError'), findsNothing);
      });
    },
  );

  testWidgets(
    'reusing State with new values/callbacks cannot rebind captured review',
    (tester) async {
      final fixture = SupportPromptPreviewFixture();
      await fixture.run(tester, () async {
        final original = _values(model: 'original-model');
        final oldDecisions = <bool>[];
        final newDecisions = <bool>[];
        bool current() => true;
        await tester.pumpWidget(
          fixture.host(
            SupportModelPromptPreviewSheet(
              values: original,
              isCurrent: current,
              onDecision: oldDecisions.add,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final retained = _button(tester, _confirm).onTap!;
        await tester.pumpWidget(
          fixture.host(
            SupportModelPromptPreviewSheet(
              values: _values(model: 'replacement-model'),
              isCurrent: current,
              onDecision: newDecisions.add,
            ),
          ),
        );
        await tester.pumpAndSettle();
        retained();
        expect(oldDecisions, isEmpty);
        expect(newDecisions, isEmpty);
        expect(_button(tester, _confirm).onTap, isNull);
        await _show(tester, find.text('original-model'));
        expect(find.text('replacement-model'), findsNothing);
      });
    },
  );

  for (final width in [236.0, 360.0, 767.0, 1200.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'measured modal header inset and exact long target/text at $width × $scale',
        (tester) async {
          final fixture = SupportPromptPreviewFixture();
          await tester.binding.setSurfaceSize(Size(width, 900));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await fixture.run(tester, () async {
            final host = '${'meaningful-host-' * 10}example.invalid:18443';
            final model = '${'meaningful-model-' * 12}distinct-final-model';
            final text =
                '${'Exact payload $_canary\n' * 160}FINAL-PAYLOAD-TAIL';
            final decisions = <bool>[];
            await _open(
              tester,
              fixture,
              decisions: decisions,
              isCurrent: () => true,
              scale: scale,
              values: _values(
                origin: host,
                model: model,
                sections: [
                  SupportPromptPreviewSection(
                    role: SupportPromptPreviewRole.user,
                    text: text,
                  ),
                ],
              ),
            );
            final header = find.ancestor(
              of: find.byKey(const ValueKey('support_prompt_preview_header')),
              matching: find.byWidgetPredicate(
                (widget) => widget.runtimeType.toString() == '_SheetViewHeader',
              ),
            );
            expect(header, findsOneWidget);
            final headerBottom = tester.getRect(header).bottom;
            final firstControl = find.byKey(const ValueKey(_cancel));
            expect(
              tester.getRect(firstControl).top,
              greaterThanOrEqualTo(headerBottom + 11),
            );
            expect(firstControl.hitTestable(), findsOneWidget);
            expect(
              find.byKey(const ValueKey(_confirm)).hitTestable(),
              findsOneWidget,
            );
            final sheetSize = tester.getSize(find.byType(SheetView));
            expect(sheetSize.height.isFinite && sheetSize.width.isFinite, true);
            await _show(tester, find.text(host));
            final originText = tester.widget<Text>(find.text(host));
            expect(originText.data, host);
            expect(originText.maxLines, isNull);
            expect(originText.overflow, isNull);
            await _show(tester, find.text(model));
            expect(tester.widget<Text>(find.text(model)).data, model);
            await _show(
              tester,
              find.byKey(const ValueKey('support_prompt_preview_section_0')),
            );
            final renderer = tester.widget<SupportPlainMarkdown>(
              find.byType(SupportPlainMarkdown),
            );
            expect(renderer.text, text);
            expect(renderer.toTextSpan().toPlainText(), text);
            expect(
              renderer.toTextSpan().toPlainText().endsWith(
                'FINAL-PAYLOAD-TAIL',
              ),
              true,
            );
            final scroll = tester.state<ScrollableState>(
              _bodyScrollable(tester),
            );
            expect(scroll.position.maxScrollExtent, greaterThan(0));
            scroll.position.jumpTo(scroll.position.maxScrollExtent);
            await tester.pumpAndSettle();
            expect(scroll.position.pixels, scroll.position.maxScrollExtent);
            final exact = find.descendant(
              of: find.byType(SupportPlainMarkdown),
              matching: find.byType(SelectableText),
            );
            final exactBottom = tester.getRect(exact).bottom;
            expect(
              exactBottom,
              lessThanOrEqualTo(tester.getRect(find.byType(SheetView)).bottom),
            );
            expect(
              exactBottom,
              greaterThan(tester.getRect(find.byType(SheetView)).top),
            );
            expect(decisions, isEmpty);
          });
        },
      );
    }
  }

  testWidgets(
    'roles/counts and exact emphasis source remain passive selectable text',
    (tester) async {
      final fixture = SupportPromptPreviewFixture();
      await tester.binding.setSurfaceSize(const Size(360, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await fixture.run(tester, () async {
        const hostile =
            '**emphasis**\n==IMG:https://example.invalid/image==\n'
            '<script>glaze.executeCommand("delete")</script>\n'
            '[link](https://example.invalid/target) ![image](https://example.invalid/image)\n'
            'https://example.invalid/plain tool_call: {"name":"undo"}';
        final decisions = <bool>[];
        await _open(
          tester,
          fixture,
          decisions: decisions,
          isCurrent: () => true,
          values: _values(
            sections: [
              for (final role in SupportPromptPreviewRole.values)
                SupportPromptPreviewSection(role: role, text: hostile),
            ],
          ),
        );
        await _show(tester, find.textContaining('Selected game messages: 2'));
        expect(
          find.textContaining('Selected assistant-chat messages: 3'),
          findsOneWidget,
        );
        expect(find.textContaining('Only text generation.'), findsOneWidget);
        for (var index = 0; index < 3; index++) {
          final section = find.byKey(
            ValueKey('support_prompt_preview_section_$index'),
          );
          await _show(tester, section);
          final renderer = tester.widget<SupportPlainMarkdown>(section);
          expect(renderer.text, hostile);
          _textOnly(renderer.toTextSpan());
          final exact = find.byKey(
            ValueKey('support_prompt_preview_exact_$index'),
          );
          await _show(tester, exact);
          final exactWidget = tester.widget<SelectableText>(exact);
          expect(exactWidget.data, hostile);
          expect(exactWidget.maxLines, isNull);
          expect(exactWidget.contextMenuBuilder, isNull);
          final editorFinder = find.descendant(
            of: exact,
            matching: find.byType(EditableText),
          );
          await tester.longPressAt(_visibleGlyphPoint(tester, editorFinder));
          await tester.pumpAndSettle();
          final editor = tester.widget<EditableText>(editorFinder);
          expect(editor.controller.selection.isValid, true);
          expect(editor.controller.selection.isCollapsed, false);
          expect(editor.controller.text, hostile);
          expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
        }
        for (final type in [
          Image,
          RawImage,
          AndroidView,
          UiKitView,
          PlatformViewLink,
          HtmlElementView,
        ]) {
          expect(find.byType(type), findsNothing);
        }
        expect(decisions, isEmpty);
      });
    },
  );
}
