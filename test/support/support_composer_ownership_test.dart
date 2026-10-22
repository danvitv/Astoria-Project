import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_composer_bar.dart';

class _Settings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings();
}

Widget _scope(Widget child) => ProviderScope(
  overrides: [appSettingsProvider.overrideWith(_Settings.new)],
  child: child,
);

Future<void> _show(
  WidgetTester tester,
  TextEditingController controller,
  String sessionId,
  Future<bool> Function(String) onSend,
) => tester.pumpWidget(
  _scope(
    MaterialApp(
      home: Scaffold(
        body: SupportComposerBar(
          controller: controller,
          sessionId: sessionId,
          onSend: onSend,
        ),
      ),
    ),
  ),
);

// Synthetic widget with injected kit settings: no storage, router, or app startup.
void main() {
  for (final throws in [false, true]) {
    testWidgets(
      'late ${throws ? 'throw' : 'false'} after session switch cannot paint failure',
      (tester) async {
        final controller = TextEditingController(text: 'Synthetic A draft');
        addTearDown(controller.dispose);
        final pending = Completer<bool>();
        Future<void> show(String session) => tester.pumpWidget(
          _scope(
            MaterialApp(
              home: Scaffold(
                body: SupportComposerBar(
                  controller: controller,
                  sessionId: session,
                  onSend: (_) => pending.future,
                ),
              ),
            ),
          ),
        );
        await show('a');
        await tester.tap(
          find.byKey(const ValueKey('support_composer_send_btn')),
        );
        await tester.pump();
        await show('b');
        if (throws) {
          pending.completeError(StateError('synthetic-secret-canary'));
        } else {
          pending.complete(false);
        }
        await tester.pumpAndSettle();
        expect(find.textContaining('Черновик'), findsNothing);
        expect(controller.text, 'Synthetic A draft');
        expect(find.textContaining('synthetic-secret-canary'), findsNothing);
      },
    );
  }

  for (final throws in [false, true]) {
    for (final change in ['controller', 'draft', 'session-away-and-back']) {
      testWidgets(
        'late ${throws ? 'throw' : 'false'} cannot own changed $change',
        (tester) async {
          final first = TextEditingController(text: 'Synthetic first');
          final second = TextEditingController(text: 'Synthetic second');
          addTearDown(first.dispose);
          addTearDown(second.dispose);
          final pending = Completer<bool>();
          await _show(tester, first, 'a', (_) => pending.future);
          await tester.tap(
            find.byKey(const ValueKey('support_composer_send_btn')),
          );
          await tester.pump();
          if (change == 'controller') {
            await _show(tester, second, 'a', (_) => pending.future);
          } else if (change == 'draft') {
            first.text = 'Synthetic newer draft';
          } else {
            await _show(tester, first, 'b', (_) => pending.future);
            await _show(tester, first, 'a', (_) => pending.future);
          }
          if (throws) {
            pending.completeError(StateError('synthetic-secret-canary'));
          } else {
            pending.complete(false);
          }
          await tester.pumpAndSettle();
          expect(find.textContaining('Черновик'), findsNothing);
          expect(
            first.text,
            change == 'draft' ? 'Synthetic newer draft' : 'Synthetic first',
          );
          expect(second.text, 'Synthetic second');
        },
      );
    }
  }

  testWidgets('visible thrown failure clears on controller change', (
    tester,
  ) async {
    final first = TextEditingController(text: 'Synthetic first');
    final second = TextEditingController(text: 'Synthetic second');
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    Future<bool> send(String _) async =>
        throw StateError('synthetic-secret-canary');
    await _show(tester, first, 'a', send);
    await tester.tap(find.byKey(const ValueKey('support_composer_send_btn')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Черновик'), findsOneWidget);
    expect(find.textContaining('synthetic-secret-canary'), findsNothing);
    await _show(tester, second, 'a', send);
    expect(find.textContaining('Черновик'), findsNothing);
    expect(first.text, 'Synthetic first');
    expect(second.text, 'Synthetic second');
  });

  testWidgets(
    'unchanged durable success clears once and same-turn duplicate is blocked',
    (tester) async {
      final controller = TextEditingController(text: 'Synthetic accepted');
      addTearDown(controller.dispose);
      final pending = Completer<bool>();
      var sends = 0;
      await _show(tester, controller, 'a', (_) {
        sends++;
        return pending.future;
      });
      final callback = tester
          .widget<IconButton>(
            find.byKey(const ValueKey('support_composer_send_btn')),
          )
          .onPressed!;
      callback();
      callback();
      expect(sends, 1);
      pending.complete(true);
      await tester.pumpAndSettle();
      expect(controller.text, isEmpty);
      expect(find.textContaining('Черновик'), findsNothing);
    },
  );

  for (final change in ['session', 'controller']) {
    testWidgets('durable success never clears changed $change draft', (
      tester,
    ) async {
      final first = TextEditingController(text: 'Synthetic first');
      final second = TextEditingController(text: 'Synthetic second');
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      final pending = Completer<bool>();
      await _show(tester, first, 'a', (_) => pending.future);
      await tester.tap(find.byKey(const ValueKey('support_composer_send_btn')));
      await tester.pump();
      await _show(
        tester,
        change == 'controller' ? second : first,
        change == 'session' ? 'b' : 'a',
        (_) => pending.future,
      );
      pending.complete(true);
      await tester.pumpAndSettle();
      expect(first.text, 'Synthetic first');
      expect(second.text, 'Synthetic second');
    });
  }

  testWidgets('visible failure clears on session switch', (tester) async {
    final controller = TextEditingController(text: 'Synthetic draft');
    addTearDown(controller.dispose);
    Future<void> show(String session) => tester.pumpWidget(
      _scope(
        MaterialApp(
          home: Scaffold(
            body: SupportComposerBar(
              controller: controller,
              sessionId: session,
              onSend: (_) async => false,
            ),
          ),
        ),
      ),
    );
    await show('a');
    await tester.tap(find.byKey(const ValueKey('support_composer_send_btn')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Черновик'), findsOneWidget);
    await show('b');
    expect(find.textContaining('Черновик'), findsNothing);
    expect(controller.text, 'Synthetic draft');
  });
}
