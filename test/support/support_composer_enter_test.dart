import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_composer_bar.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';
import 'package:glaze_flutter/shared/widgets/glaze_text_field.dart';

class _KeyboardSettings extends AsyncNotifier<AppSettings>
    implements AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings(
    batterySaver: true,
    hapticFeedback: false,
    messageVibration: false,
    allowMessageScripts: false,
    showOurPicks: false,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected settings command');
}

class _KeyboardTheme extends StateNotifier<ThemeSettings>
    implements ThemeNotifier {
  _KeyboardTheme()
    : super(
        const ThemeSettings(
          activePreset: ThemePreset(
            id: 'keyboard-test',
            name: 'Synthetic',
            elementOpacity: 1,
            elementBlur: 0,
            noiseOpacity: 0,
            bgBlur: 0,
            bgDim: 0,
            bgNoiseOpacity: 0,
            uiFontMode: 'system',
            chatFontMode: 'system',
          ),
          presets: [],
          ignoreCustomFont: true,
        ),
      );
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected theme command');
}

Widget _host(
  TextEditingController controller,
  Object owner,
  Future<bool> Function(SupportComposerDraft) send, {
  bool enterToSend = true,
  String session = 'synthetic',
}) => ProviderScope(
  overrides: [
    appSettingsProvider.overrideWith(_KeyboardSettings.new),
    themeProvider.overrideWith((_) => _KeyboardTheme()),
  ],
  child: MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: SupportComposerBar(
          controller: controller,
          sessionId: session,
          nativeOwner: owner,
          onNativeSend: send,
          onSend: (_) =>
              Future<bool>.error(StateError('Unexpected legacy send')),
          enterToSend: enterToSend,
        ),
      ),
    ),
  ),
);

Future<void> _type(WidgetTester tester, String text) async {
  await tester.tap(find.byType(TextField));
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
}

Focus _handler(WidgetTester tester) => tester.widget<Focus>(
  find.byWidgetPredicate(
    (w) => w is Focus && w.onKeyEvent != null && w.child is GlazeTextField,
  ),
);

void _keyboardTest(String name, WidgetTesterCallback body) {
  testWidgets(name, (tester) async {
    final original = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = original;
    }
  });
}

void main() {
  for (final key in [
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
  ]) {
    _keyboardTest(
      '${key.keyLabel} uses the native submit and clears only accepted current draft',
      (tester) async {
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        final sent = <String>[];
        await tester.pumpWidget(
          _host(controller, Object(), (draft) async {
            expect(draft.isCurrent(), isTrue);
            sent.add(draft.text);
            return true;
          }),
        );
        await _type(tester, 'hello');
        // Flutter's legacy Windows simulator has no numpad-Enter keyCode.
        // The Android packet still delivers the real, platform-neutral KeyEvent.
        await tester.sendKeyEvent(
          key,
          platform: key == LogicalKeyboardKey.numpadEnter ? 'android' : null,
        );
        await tester.pump();
        expect(sent, ['hello']);
        expect(controller.text, isEmpty);
      },
    );
  }

  _keyboardTest('setting OFF and Shift+Enter keep newline without native send', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final owner = Object();
    var calls = 0;
    Future<bool> send(SupportComposerDraft _) async {
      calls++;
      return true;
    }

    await tester.pumpWidget(_host(controller, owner, send, enterToSend: false));
    await _type(tester, 'a');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(calls, 0);
    expect(
      tester.widget<TextField>(find.byType(TextField)).textInputAction,
      TextInputAction.newline,
    );
    // Native text input supplies the newline when Flutter leaves Enter unhandled.
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'a\n',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();
    expect(controller.text, 'a\n');
    await tester.pumpWidget(_host(controller, owner, send));
    await _type(tester, 'b');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(calls, 0);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'b\n',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();
    expect(controller.text, 'b\n');
  });

  _keyboardTest(
    'Enter shares silent busy latch with button and retains rejected draft',
    (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final result = Completer<bool>();
      addTearDown(() {
        if (!result.isCompleted) result.complete(false);
      });
      var calls = 0;
      await tester.pumpWidget(
        _host(controller, Object(), (draft) {
          calls++;
          return result.future;
        }),
      );
      await _type(tester, 'kept');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(calls, 1);
      result.complete(false);
      await tester.pump();
      expect(controller.text, 'kept');
    },
  );

  _keyboardTest(
    'IME composition, repeat and mobile soft-keyboard Enter never trigger native send',
    (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      var calls = 0;
      final owner = Object();
      Future<bool> send(SupportComposerDraft _) async {
        calls++;
        return true;
      }

      await tester.pumpWidget(_host(controller, owner, send));
      await _type(tester, 'compose');
      controller.value = const TextEditingValue(
        text: 'compose',
        selection: TextSelection.collapsed(offset: 7),
        composing: TextRange(start: 0, end: 7),
      );
      final focus = _handler(tester);
      final node = Focus.of(tester.element(find.byType(TextField)));
      expect(
        focus.onKeyEvent!(
          node,
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.enter,
            logicalKey: LogicalKeyboardKey.enter,
            timeStamp: Duration.zero,
          ),
        ),
        KeyEventResult.ignored,
      );
      controller.value = const TextEditingValue(
        text: 'compose',
        selection: TextSelection.collapsed(offset: 7),
      );
      expect(
        focus.onKeyEvent!(
          node,
          const KeyRepeatEvent(
            physicalKey: PhysicalKeyboardKey.enter,
            logicalKey: LogicalKeyboardKey.enter,
            timeStamp: Duration.zero,
          ),
        ),
        KeyEventResult.ignored,
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(_host(controller, owner, send));
      final mobile = _handler(tester);
      expect(
        mobile.onKeyEvent!(
          node,
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.enter,
            logicalKey: LogicalKeyboardKey.enter,
            timeStamp: Duration.zero,
          ),
        ),
        KeyEventResult.ignored,
      );
      expect(calls, 0);
    },
  );

  _keyboardTest(
    'retained handler cannot send after setting/session replacement or disposal',
    (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final owner = Object();
      var calls = 0;
      Future<bool> send(SupportComposerDraft _) async {
        calls++;
        return true;
      }

      await tester.pumpWidget(_host(controller, owner, send));
      await _type(tester, 'current');
      final original = _handler(tester).onKeyEvent!;
      final node = Focus.of(tester.element(find.byType(TextField)));
      const event = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.enter,
        logicalKey: LogicalKeyboardKey.enter,
        timeStamp: Duration.zero,
      );
      await tester.pumpWidget(
        _host(controller, owner, send, enterToSend: false),
      );
      expect(original(node, event), KeyEventResult.ignored);
      await tester.pumpWidget(_host(controller, owner, send, session: 'other'));
      expect(original(node, event), KeyEventResult.ignored);
      await tester.pumpWidget(const SizedBox());
      expect(original(node, event), KeyEventResult.ignored);
      expect(calls, 0);
    },
  );
}
