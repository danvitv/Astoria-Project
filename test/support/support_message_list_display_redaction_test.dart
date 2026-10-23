import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_run_view.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_card_view.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_message_list.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_plain_markdown.dart';

import 'helpers/support_message_list_passivity_fixture.dart';

const _canary = 'SYNTHETIC_REACTIVE_FEED_CANARY';
const _unavailable =
    'Текст сообщения недоступен: не удалось безопасно отобразить.';

final class _Callbacks {
  final calls = <String>[];
  void quick(String id) => calls.add('quick:$id');
  void apply(String id) => calls.add('apply:$id');
  void rollback(String id) => calls.add('rollback:$id');
  void setup(String id) => calls.add('setup:$id');

  SupportMessageList feed(
    List<SupportMessageItem> messages, {
    SupportModelRunView run = const SupportModelRunView(),
  }) => SupportMessageList(
    messages: messages,
    hasConfiguredModel: true,
    onQuickAction: quick,
    onApplyPlan: apply,
    onRollback: rollback,
    onSetupAction: setup,
    run: run,
  );
}

SupportMessageItem _message(
  SupportMessageRole role,
  String body, {
  bool restored = true,
  String id = 'synthetic-display-row',
  String status = 'complete',
  List<SupportCard> cards = const [],
}) => SupportMessageItem(
  id: id,
  sessionId: 'synthetic-display-session',
  role: role,
  body: body,
  createdAt: DateTime.utc(restored ? 2020 : 2026),
  runId: 'synthetic-display-run',
  status: status,
  cards: cards,
);

Finder _body(String text) => find.byWidgetPredicate(
  (widget) => widget is SupportPlainMarkdown && widget.text == text,
  description: 'exact independently expected sanitized feed body',
);

void _paintedBody(WidgetTester tester, String source, String visible) {
  final body = _body(source);
  expect(body, findsOneWidget);
  final selectable = tester.widget<SelectableText>(
    find.descendant(of: body, matching: find.byType(SelectableText)),
  );
  expect(selectable.textSpan!.toPlainText(), visible);
  expect(selectable.contextMenuBuilder, isNull);
  expect(selectable.onTap, isNull);
  expect(selectable.onSelectionChanged, isNull);
  expect(selectable.enableInteractiveSelection, isTrue);
  final editable = tester.widget<EditableText>(
    find.descendant(of: body, matching: find.byType(EditableText)),
  );
  expect(editable.readOnly, isTrue);
  expect(editable.controller.text, visible);
}

void _noPaintedCanary(WidgetTester tester) {
  for (final body in tester.widgetList<SupportPlainMarkdown>(
    find.byType(SupportPlainMarkdown),
  )) {
    expect(body.text, isNot(contains(_canary)));
  }
  for (final text in tester.widgetList<SelectableText>(
    find.byType(SelectableText),
  )) {
    expect(text.textSpan!.toPlainText(), isNot(contains(_canary)));
  }
  for (final editor in tester.widgetList<EditableText>(
    find.byType(EditableText),
  )) {
    expect(editor.controller.text, isNot(contains(_canary)));
  }
  for (final type in [
    Image,
    RawImage,
    AndroidView,
    UiKitView,
    PlatformViewLink,
  ]) {
    expect(find.byType(type), findsNothing);
  }
}

Finder _outerScrollable(WidgetTester tester) {
  final list = find.descendant(
    of: find.byType(SupportMessageList),
    matching: find.byType(ListView),
  );
  expect(list, findsOneWidget);
  final listElement = tester.element(list);
  final outer = find.descendant(
    of: list,
    matching: find.byElementPredicate((element) {
      if (element.widget is! Scrollable ||
          axisDirectionToAxis((element.widget as Scrollable).axisDirection) !=
              Axis.vertical) {
        return false;
      }
      var ownsList = false;
      element.visitAncestorElements((ancestor) {
        if (identical(ancestor, listElement)) {
          ownsList = true;
          return false;
        }
        return ancestor.widget is! Scrollable;
      });
      return ownsList;
    }, description: 'actual feed outer vertical Scrollable'),
  );
  expect(outer, findsOneWidget);
  return outer;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final role in SupportMessageRole.values) {
    for (final restored in [true, false]) {
      testWidgets(
        '${role.name} ${restored ? 'restored' : 'settled'} body reprojects without parent rebuild',
        (tester) async {
          final fixture = SupportMessageListPassivityFixture();
          await fixture.run(tester, () async {
            final callbacks = _Callbacks();
            const raw = '**before** $_canary *after*';
            const safe = '**before** [REDACTED] *after*';
            final message = _message(role, raw, restored: restored);
            final messages = [message];
            final feed = callbacks.feed(messages);
            await tester.pumpWidget(fixture.host(feed));
            await tester.pumpAndSettle();
            _paintedBody(tester, raw, 'before $_canary after');
            final previous = fixture.container.read(secretRedactorProvider);

            fixture.redaction.registerSecret(_canary);
            final newest = fixture.container.read(secretRedactorProvider);
            expect(identical(previous, newest), isFalse);
            expect(identical(newest, fixture.redaction.redactor), isTrue);
            expect(newest.redactText(_canary), '[REDACTED]');
            // No pumpWidget, producer update, reload or native action here.
            await tester.pumpAndSettle();

            _paintedBody(tester, safe, 'before [REDACTED] after');
            expect(_body(raw), findsNothing);
            _noPaintedCanary(tester);
            expect(
              tester.widget<SupportMessageList>(
                find.byType(SupportMessageList),
              ),
              same(feed),
            );
            expect(feed.messages, same(messages));
            expect(feed.messages.single, same(message));
            expect(message.body, raw);
            expect(message.status, 'complete');
            expect(message.runId, 'synthetic-display-run');
            expect(message.createdAt, DateTime.utc(restored ? 2020 : 2026));
            expect(previous.redactText(_canary), _canary);
            expect(callbacks.calls, isEmpty);
            expect(fixture.localAssetLoads, isEmpty);
          });
        },
      );
    }
  }

  testWidgets('known current policy covers all roles on first passive paint', (
    tester,
  ) async {
    final fixture = SupportMessageListPassivityFixture(
      redactor: SecretRedactor(knownSecrets: [_canary]),
    );
    await fixture.run(tester, () async {
      final callbacks = _Callbacks();
      final messages = [
        for (final role in SupportMessageRole.values)
          _message(role, '${role.name}: $_canary', id: role.name),
      ];
      await tester.pumpWidget(fixture.host(callbacks.feed(messages)));
      await tester.pumpAndSettle();
      for (final role in SupportMessageRole.values) {
        _paintedBody(
          tester,
          '${role.name}: [REDACTED]',
          '${role.name}: [REDACTED]',
        );
      }
      _noPaintedCanary(tester);
      expect(messages.map((m) => m.body), [
        'user: $_canary',
        'assistant: $_canary',
        'system: $_canary',
      ]);
      expect(callbacks.calls, isEmpty);
    });
  });

  for (final initiallyClosed in [true, false]) {
    testWidgets(
      '${initiallyClosed ? 'closed initial' : 'reactively exhausted'} policy refuses all role bodies whole',
      (tester) async {
        final fixture = SupportMessageListPassivityFixture(
          redactor: SecretRedactor(
            knownSecrets: List.generate(
              initiallyClosed ? 257 : 256,
              (index) => 'SYNTHETIC_POLICY_VALUE_$index',
            ),
          ),
        );
        await fixture.run(tester, () async {
          final callbacks = _Callbacks();
          final messages = [
            for (final role in SupportMessageRole.values)
              _message(role, '${role.name} $_canary', id: role.name),
          ];
          await tester.pumpWidget(fixture.host(callbacks.feed(messages)));
          await tester.pumpAndSettle();
          if (!initiallyClosed) {
            for (final role in SupportMessageRole.values) {
              _paintedBody(
                tester,
                '${role.name} $_canary',
                '${role.name} $_canary',
              );
            }
            fixture.redaction.registerSecret('SYNTHETIC_OVER_BUDGET_VALUE');
            await tester.pumpAndSettle();
          }
          expect(_body(_unavailable), findsNWidgets(3));
          for (final editor in tester.widgetList<EditableText>(
            find.byType(EditableText),
          )) {
            expect(editor.controller.text, _unavailable);
            expect(editor.readOnly, isTrue);
          }
          for (final text in tester.widgetList<SelectableText>(
            find.byType(SelectableText),
          )) {
            expect(text.textSpan!.toPlainText(), _unavailable);
          }
          _noPaintedCanary(tester);
          expect(messages.every((m) => m.body.contains(_canary)), isTrue);
          expect(callbacks.calls, isEmpty);
        });
      },
    );
  }

  testWidgets(
    'sanitation expansion refuses every role before passive construction',
    (tester) async {
      final fixture = SupportMessageListPassivityFixture(
        redactor: SecretRedactor(knownSecrets: ['x']),
      );
      await fixture.run(tester, () async {
        final callbacks = _Callbacks();
        final raw = 'x' * 6554;
        final messages = [
          for (final role in SupportMessageRole.values)
            _message(role, raw, id: role.name),
        ];
        await tester.pumpWidget(fixture.host(callbacks.feed(messages)));
        await tester.pumpAndSettle();
        expect(_body(_unavailable), findsNWidgets(3));
        expect(_body(raw), findsNothing);
        expect(_body(SecretRedactor.limited), findsNothing);
        for (final editor in tester.widgetList<EditableText>(
          find.byType(EditableText),
        )) {
          expect(editor.controller.text, _unavailable);
        }
        expect(messages.every((m) => m.body == raw), isTrue);
        expect(callbacks.calls, isEmpty);
      });
    },
  );

  testWidgets('lazy not-yet-painted restored rows use the newest policy', (
    tester,
  ) async {
    final fixture = SupportMessageListPassivityFixture();
    await fixture.run(tester, () async {
      final callbacks = _Callbacks();
      final messages = [
        for (var index = 0; index < 18; index++)
          _message(
            SupportMessageRole.values[index % 3],
            'row $index $_canary\n${'ordinary text\n' * 12}',
            id: 'lazy-$index',
          ),
      ];
      await tester.pumpWidget(fixture.host(callbacks.feed(messages)));
      await tester.pumpAndSettle();
      expect(_body(messages.last.body), findsNothing);
      fixture.redaction.registerSecret(_canary);
      await tester.pumpAndSettle();
      _noPaintedCanary(tester);
      final safe = 'row 17 [REDACTED]\n${'ordinary text\n' * 12}';
      await tester.scrollUntilVisible(
        _body(safe),
        300,
        scrollable: _outerScrollable(tester),
        maxScrolls: 100,
      );
      await tester.ensureVisible(_body(safe));
      await tester.pumpAndSettle();
      _paintedBody(tester, safe, safe);
      _noPaintedCanary(tester);
      expect(messages.every((m) => m.body.contains(_canary)), isTrue);
      expect(callbacks.calls, isEmpty);
    });
  });

  testWidgets(
    'reactive projection preserves status and native card identities',
    (tester) async {
      final fixture = SupportMessageListPassivityFixture();
      await fixture.run(tester, () async {
        final callbacks = _Callbacks();
        const card = QuickActionChipsCard(
          title: 'Trusted card',
          subtitle: 'Explicit callback only',
          actions: [
            QuickActionItem(
              id: 'theme_setup',
              label: 'Settings',
              subtitle: 'Native',
            ),
          ],
        );
        const run = SupportModelRunView(
          phase: SupportModelPhase.activity,
          busy: true,
          runId: 'synthetic-display-run',
          sessionId: 'synthetic-display-session',
        );
        final message = _message(
          SupportMessageRole.assistant,
          _canary,
          restored: false,
          status: 'running',
          cards: [card],
        );
        final feed = callbacks.feed([message], run: run);
        await tester.pumpWidget(fixture.host(feed));
        await tester.pumpAndSettle();
        expect(find.text('Получение ответа модели…'), findsOneWidget);
        fixture.redaction.registerSecret(_canary);
        await tester.pumpAndSettle();
        _paintedBody(tester, '[REDACTED]', '[REDACTED]');
        _noPaintedCanary(tester);
        expect(find.text('Получение ответа модели…'), findsOneWidget);
        final native = tester.widget<SupportCardView>(
          find.byType(SupportCardView),
        );
        expect(native.card, same(card));
        expect(native.onQuickAction, feed.onQuickAction);
        expect(native.onApplyPlan, feed.onApplyPlan);
        expect(native.onRollback, feed.onRollback);
        expect(native.onSetupAction, feed.onSetupAction);
        expect(feed.run, same(run));
        expect(message.status, 'running');
        expect(message.cards.single, same(card));
        expect(message.body, _canary);
        expect(callbacks.calls, isEmpty);
      });
    },
  );
}
