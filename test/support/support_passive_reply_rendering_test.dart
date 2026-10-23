import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_plain_markdown.dart';

typedef _Run = ({String text, int emphasis});

const _canary = 'SYNTHETIC_PASSIVE_REPLY_CANARY_🧪';
const _passive =
    '[link](https://example.invalid/$_canary)\n'
    '![$_canary](https://example.invalid/image.png)\n'
    '<img src="https://example.invalid/$_canary">\n'
    '<script>executeCommand("$_canary")</script>\n'
    '`glaze.executeCommand("$_canary")`\n'
    'https://example.invalid/$_canary\n'
    'javascript:executeCommand("$_canary")\n'
    'file:///synthetic/$_canary\n'
    '{"type":"mutation_plan","applied":true,"target":"$_canary"}\n'
    '{"type":"quick_actions","actions":[{"id":"theme_setup"}]}';

void main() {
  group('bounded passive emphasis spans', () {
    final cases = <String, List<_Run>>{
      '': [(text: '', emphasis: 0)],
      '  plain\t\r\nМир 👩🏽‍💻 e\u0301\u2028 ': [
        (text: '  plain\t\r\nМир 👩🏽‍💻 e\u0301\u2028 ', emphasis: 0),
      ],
      '**bold** and *italic*': [
        (text: 'bold', emphasis: 2),
        (text: ' and ', emphasis: 0),
        (text: 'italic', emphasis: 1),
      ],
      '**outer *inner* tail**': [
        (text: 'outer ', emphasis: 2),
        (text: 'inner', emphasis: 3),
        (text: ' tail', emphasis: 2),
      ],
      '*outer **inner** tail*': [
        (text: 'outer ', emphasis: 1),
        (text: 'inner', emphasis: 3),
        (text: ' tail', emphasis: 1),
      ],
      '***both***': [(text: 'both', emphasis: 3)],
      '**bold *both***': [
        (text: 'bold ', emphasis: 2),
        (text: 'both', emphasis: 3),
      ],
      '*italic **both***': [
        (text: 'italic ', emphasis: 1),
        (text: 'both', emphasis: 3),
      ],
      '*unmatched **bold**': [
        (text: '*unmatched ', emphasis: 0),
        (text: 'bold', emphasis: 2),
      ],
      '**unmatched *italic*': [
        (text: '**unmatched ', emphasis: 0),
        (text: 'italic', emphasis: 1),
      ],
      '*a **b* c**': [(text: '*a ', emphasis: 0), (text: 'b* c', emphasis: 2)],
      '*outer *inner* tail*': [
        (text: 'outer *inner', emphasis: 1),
        (text: ' tail*', emphasis: 0),
      ],
      '*a ***b*** c*': [(text: 'a ***b*** c', emphasis: 1)],
      '***x**': [(text: '***x**', emphasis: 0)],
      '***x*': [(text: '**', emphasis: 0), (text: 'x', emphasis: 1)],
      '****x****': [(text: '****x****', emphasis: 0)],
      r'\*x*': [(text: r'\*x*', emphasis: 0)],
      r'\**x**': [(text: r'\**x**', emphasis: 0)],
      r'\\*x*': [(text: r'\\', emphasis: 0), (text: 'x', emphasis: 1)],
      '** x**': [(text: '** x**', emphasis: 0)],
      '**x **': [(text: '**x **', emphasis: 0)],
      '*\u00a0x*': [(text: '*\u00a0x*', emphasis: 0)],
      '**Мир\r\n👩🏽‍💻 e\u0301**': [
        (text: 'Мир\r\n👩🏽‍💻 e\u0301', emphasis: 2),
      ],
      '`*literal* **literal**` *italic*': [
        (text: '`*literal* **literal**` ', emphasis: 0),
        (text: 'italic', emphasis: 1),
      ],
      '``a`*literal*`` **bold**': [
        (text: '``a`*literal*`` ', emphasis: 0),
        (text: 'bold', emphasis: 2),
      ],
      '`unclosed *literal*': [(text: '`unclosed *literal*', emphasis: 0)],
      '```dart\r\n**literal**\r\n``` *italic*': [
        (text: '```dart\r\n**literal**\r\n``` ', emphasis: 0),
        (text: 'italic', emphasis: 1),
      ],
      '## heading\n- list\n> quote\n~~strike~~ __bold__': [
        (text: '## heading\n- list\n> quote\n~~strike~~ __bold__', emphasis: 0),
      ],
      '[**label**](https://example.invalid/path)': [
        (text: '[', emphasis: 0),
        (text: 'label', emphasis: 2),
        (text: '](https://example.invalid/path)', emphasis: 0),
      ],
      _passive: [(text: _passive, emphasis: 0)],
    };
    var index = 0;
    for (final entry in cases.entries) {
      test('literal/nested/escaped fixture ${index++}', () {
        final span = SupportPlainMarkdown(text: entry.key).toTextSpan();
        expect(_runs(span), entry.value);
        expect(span.toPlainText(), entry.value.map((run) => run.text).join());
        _expectTextOnly(span);
      });
    }

    test('root style is retained without erasing emphasis inheritance', () {
      const style = TextStyle(fontSize: 17, height: 1.6, letterSpacing: 0.5);
      const widget = SupportPlainMarkdown(text: 'a **b** *c*', style: style);
      final span = widget.toTextSpan();
      expect(identical(span.style, style), isTrue);
      expect(widget.text, 'a **b** *c*');
      expect(widget.style, style);
      expect(span.children, hasLength(4));
      expect(
        () => span.children!.add(const TextSpan(text: 'rewrite')),
        throwsUnsupportedError,
      );
      expect(span.children![1].style!.fontSize, isNull);
      expect(span.children![1].style!.inherit, isTrue);
    });

    test('no character other than a matched asterisk can disappear', () {
      const source =
          '👩🏽‍💻 **$_canary**\n[*a*](https://x.invalid)\\ **unclosed';
      final displayed = const SupportPlainMarkdown(
        text: source,
      ).toTextSpan().toPlainText();
      expect(displayed, contains(_canary));
      expect(displayed, contains('**unclosed'));
      expect(displayed.replaceAll('*', ''), source.replaceAll('*', ''));
    });

    test('exact 65536-unit plain/Unicode inputs are admitted', () {
      for (final unit in ['x', '🧪']) {
        final source = _repeat(unit, 65536 ~/ unit.length);
        expect(source.length, SupportPlainMarkdown.maxTextLength);
        final span = SupportPlainMarkdown(text: source).toTextSpan();
        expect(span.toPlainText(), source);
        expect(span.children, hasLength(1));
      }
    });

    test('oversize refusal is explicit, fixed and cannot echo the input', () {
      final source = '$_canary${_repeat('x', 65536)}';
      try {
        SupportPlainMarkdown(text: source).toTextSpan();
        fail('Oversize input must be refused, not clipped.');
      } on ArgumentError catch (error) {
        expect(error.message, 'Support text exceeds 65536 UTF-16 code units.');
        expect(error.toString(), isNot(contains(_canary)));
        expect(error.invalidValue, isNull);
      }
    });

    test('large pathological runs remain bounded flat literal text', () {
      // No flaky stopwatch assertion: scanner has no search-from-each-offset,
      // recursive descent or regex. These exercise the full admitted input size.
      for (final source in [
        _repeat('*', 65536),
        _repeat('*a ', 21845),
        _repeat(r'\***a ', 10922),
        '`${_repeat('*', 65535)}',
        _repeat('`', 65536),
      ]) {
        expect(source.length, lessThanOrEqualTo(65536));
        final span = SupportPlainMarkdown(text: source).toTextSpan();
        expect(span.toPlainText(), source);
        expect(span.children, hasLength(1));
        _expectTextOnly(span);
      }
    });

    test(
      'many valid nested pairs produce linear-sized deterministic spans',
      () {
        final source = _repeat('**a *b* c**\n', 5461);
        final widget = SupportPlainMarkdown(text: source);
        final span = widget.toTextSpan();
        expect(source.length, 65532);
        expect(span.toPlainText(), _repeat('a b c\n', 5461));
        expect(span.children, hasLength(4 * 5461));
        expect(widget.toTextSpan().toPlainText(), span.toPlainText());
        _expectTextOnly(span);
      },
    );
  });

  for (final width in [220.0, 360.0, 680.0, 1024.0]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets('passive selectable layout at width $width scale $scale', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(Size(width, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await _withTripwires(tester, () async {
          await tester.pumpWidget(_host('**bold** *italic*\n$_passive', scale));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final selectable = tester.widget<SelectableText>(
            find.byType(SelectableText),
          );
          expect(selectable.contextMenuBuilder, isNull);
          expect(selectable.onTap, isNull);
          expect(selectable.onSelectionChanged, isNull);
          expect(selectable.enableInteractiveSelection, isTrue);
          expect(selectable.textSpan!.toPlainText(), 'bold italic\n$_passive');
          _expectTextOnly(selectable.textSpan!);
          final editor = tester.widget<EditableText>(find.byType(EditableText));
          expect(editor.readOnly, isTrue);
          expect(editor.controller.text, 'bold italic\n$_passive');
          expect(
            tester
                .state<EditableTextState>(find.byType(EditableText))
                .renderEditable
                .textScaler
                .scale(14),
            closeTo(14 * scale, 0.001),
          );
          _expectNoActiveContent();
          // A tap on model-looking content can focus/select native text, never
          // navigate, execute a command, load an image or copy automatically.
          await tester.tapAt(
            tester.getTopLeft(find.byType(EditableText)) +
                Offset(8, 14 * 1.4 * scale + 8),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          _expectNoActiveContent();
        });
      });
    }
  }

  testWidgets('URL-like text supports native word selection without actions', (
    tester,
  ) async {
    await _withTripwires(tester, () async {
      await tester.pumpWidget(_host('https://example.invalid/$_canary', 1));
      await tester.pumpAndSettle();
      final point =
          tester.getTopLeft(find.byType(EditableText)) + const Offset(8, 8);
      await tester.longPressAt(point);
      await tester.pumpAndSettle();
      final editor = tester.widget<EditableText>(find.byType(EditableText));
      expect(editor.controller.selection.isValid, isTrue);
      expect(editor.controller.selection.isCollapsed, isFalse);
      expect(editor.controller.text, 'https://example.invalid/$_canary');
      expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
      expect(tester.takeException(), isNull);
      _expectNoActiveContent();
    });
  });
}

List<_Run> _runs(TextSpan span) => span.children!.map((child) {
  final text = child as TextSpan;
  return (
    text: text.text!,
    emphasis:
        (text.style?.fontStyle == FontStyle.italic ? 1 : 0) |
        (text.style?.fontWeight == FontWeight.w700 ? 2 : 0),
  );
}).toList();

void _expectTextOnly(TextSpan span) {
  expect(span.recognizer, isNull);
  for (final child in span.children!) {
    expect(child, isA<TextSpan>());
    final leaf = child as TextSpan;
    expect(leaf.children, isNull);
    expect(leaf.recognizer, isNull);
    expect(leaf.onEnter, isNull);
    expect(leaf.onExit, isNull);
  }
}

String _repeat(String unit, int count) => List.filled(count, unit).join();

Widget _host(String text, double scale) => MaterialApp(
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: Material(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: SupportPlainMarkdown(
            text: text,
            style: const TextStyle(fontSize: 14, height: 1.4),
          ),
        ),
      ),
    ),
  ),
);

void _expectNoActiveContent() {
  for (final type in [
    Image,
    RawImage,
    AndroidView,
    UiKitView,
    PlatformViewLink,
    InkWell,
    TextButton,
    IconButton,
  ]) {
    expect(find.byType(type), findsNothing);
  }
}

Future<void> _withTripwires(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  final attempts = <String>[];
  Never block(String boundary) {
    attempts.add(boundary);
    throw StateError('Synthetic passive rendering boundary was crossed.');
  }

  final messenger = tester.binding.defaultBinaryMessenger;
  const channels = [
    'com.pichillilorenzo/flutter_headless_inappwebview',
    'com.pichillilorenzo/flutter_inappwebview',
    'com.pichillilorenzo/flutter_inappwebview_cookiemanager',
    'com.pichillilorenzo/flutter_inappwebview_environment',
    'flutter/platform_views',
    'plugins.flutter.io/url_launcher',
    'plugins.flutter.io/path_provider',
    'plugins.it_nomads.com/flutter_secure_storage',
    'plugins.flutter.io/shared_preferences',
    'plugins.flutter.io/google_sign_in',
  ];
  for (final channel in channels) {
    messenger.setMockMessageHandler(channel, (_) => block(channel));
  }
  const platform = SystemChannels.platform;
  messenger.setMockMethodCallHandler(platform, (call) async {
    if (call.method == 'Clipboard.setData' ||
        call.method == 'SystemNavigator.pop') {
      block(call.method);
    }
    // Selection may query clipboard availability or request selection haptics;
    // these are mocked, never delegated. Any actual clipboard write is denied.
    return null;
  });
  try {
    await HttpOverrides.runZoned(() async {
      try {
        await body();
      } finally {
        // Keep all tripwires active through native selection disposal as well.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    }, createHttpClient: (_) => block('HttpClient creation'));
  } finally {
    for (final channel in channels) {
      messenger.setMockMessageHandler(channel, null);
    }
    messenger.setMockMethodCallHandler(platform, null);
    expect(
      attempts,
      isEmpty,
      reason: 'No swallowed startup/action/I/O attempts',
    );
  }
}
