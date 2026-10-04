import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/chat/widgets/chat_input_bar.dart';
import 'package:glaze_flutter/shared/widgets/glass_surface.dart';

import '../helpers/pump_localized.dart';

const _enabled = bool.fromEnvironment('CHAT_SYNTHETIC_PERF');

/// Counts work in the real composer, with synthetic IME notifications. Test
/// pumps have no native keyboard / GPU / WebView, so report counts, not FPS.
void main() {
  testWidgets('composer work per synthetic input scenario', (tester) async {
    const composerKey = ValueKey('synthetic-composer');
    final drafts = <String>[];
    await pumpLocalized(
      tester,
      Align(
        alignment: Alignment.bottomCenter,
        child: ChatInputBar(
          key: composerKey,
          isGenerating: false,
          onSend: (_) async => true,
          onDraftChanged: drafts.add,
          onMagicDrawer: () {},
        ),
      ),
    );
    await tester.showKeyboard(find.byType(TextField));
    await tester.pumpAndSettle();
    final controller = tester
        .widget<TextField>(find.byType(TextField))
        .controller!;
    final composer = tester.element(find.byKey(composerKey));
    final counts = <String, int>{};
    final previousHook = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previousHook?.call(element, builtOnce);
      var belongs = element == composer;
      if (!belongs) {
        element.visitAncestorElements((ancestor) {
          belongs = ancestor == composer;
          return !belongs;
        });
      }
      if (!belongs) return;
      final widget = element.widget;
      final kind = widget is ChatInputBar
          ? 'ChatInputBar'
          : widget is GlassSurface
          ? 'GlassSurface'
          : widget is TextField
          ? 'TextField'
          : 'other';
      counts.update(kind, (count) => count + 1, ifAbsent: () => 1);
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previousHook);

    Future<void> scenario(
      String name,
      int events,
      TextEditingValue Function(int index, TextEditingValue value)? edit,
    ) async {
      counts.clear();
      final beforeDrafts = drafts.length;
      for (var index = 0; index < events; index++) {
        if (edit != null) {
          tester.testTextInput.updateEditingValue(
            edit(index, controller.value),
          );
        }
        await tester.pump(const Duration(milliseconds: 16));
      }
      final eventBuilds = Map<String, int>.from(counts);
      final duringDrafts = drafts.length - beforeDrafts;
      // Flush the composer debounce after the synthetic user stops editing.
      await tester.pump(const Duration(milliseconds: 550));
      // ignore: avoid_print
      print(
        'CHAT_SYNTHETIC ${jsonEncode({'scenario': name, 'events': events, 'composerSubtreeBuildsDuringEvents': eventBuilds, 'draftCallbacksDuringEvents': duringDrafts, 'draftCallbacksAfterPause': drafts.length - beforeDrafts - duringDrafts, 'draftTextChars': controller.text.length})}',
      );
      expect(tester.takeException(), isNull);
    }

    await scenario('type', 80, (index, value) {
      final text = '${value.text}${index % 10 == 0 ? '\n' : 'а'}';
      return TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    });
    expect(controller.text.length, 80);
    await scenario('backspace', 40, (_, value) {
      final text = value.text.substring(0, value.text.length - 1);
      return TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    });
    final unchanged = controller.text;
    await scenario('cursor-only', 40, (index, value) {
      return value.copyWith(selection: TextSelection.collapsed(offset: index));
    });
    expect(controller.text, unchanged);
    await scenario('composing-only', 40, (index, value) {
      return value.copyWith(
        composing: TextRange(start: index % 20, end: index % 20 + 1),
      );
    });
    expect(controller.text, unchanged);
    await scenario('idle', 80, null);
    // Dispose the composer so no debounce / cursor timer escapes the harness.
    debugOnRebuildDirtyWidget = previousHook;
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !_enabled);
}
