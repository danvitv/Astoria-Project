import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_message_display_projection.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_run_view.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_message_list.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_model_tool_activity_view.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_plain_markdown.dart';

import 'helpers/support_message_list_passivity_fixture.dart';

const _session = 'synthetic-tool-session';
const _runId = 'synthetic-tool-run';
const _canary = 'SYNTHETIC_TOOL_SOURCE_CANARY';
const _source = 'Документация: example.invalid — $_canary';
const _completed = SupportModelToolActivity(
  sequence: 1,
  action: 'astoria_sources_list',
  stage: SupportModelToolStage.completed,
);
const _executing = SupportModelToolActivity(
  sequence: 2,
  action: 'astoria_source_read',
  stage: SupportModelToolStage.executing,
  sourceLabel: 'Документация: example.invalid',
);

SupportMessageItem _message({
  SupportMessageRole role = SupportMessageRole.assistant,
  String session = _session,
  String? runId = _runId,
  bool locked = false,
  String status = 'running',
  String body = '',
}) => SupportMessageItem(
  id: 'synthetic-tool-message',
  sessionId: session,
  role: role,
  body: body,
  createdAt: DateTime.utc(2026),
  runId: runId,
  isLocked: locked,
  status: status,
);

SupportModelRunView _run({
  List<SupportModelToolActivity> activities = const [_completed, _executing],
  bool busy = true,
  PrivateTextStatus? status,
}) => SupportModelRunView(
  phase: busy ? SupportModelPhase.waiting : SupportModelPhase.settled,
  busy: busy,
  accepted: true,
  saved: !busy,
  status: status,
  transportReason: status == PrivateTextStatus.error
      ? PrivateTextReason.providerError
      : PrivateTextReason.none,
  runId: _runId,
  sessionId: _session,
  toolActivities: activities,
);

SupportMessageList _feed(SupportMessageItem message, SupportModelRunView run) =>
    SupportMessageList(
      messages: [message],
      hasConfiguredModel: true,
      onQuickAction: (_) => fail('No quick action during passive progress'),
      onApplyPlan: (_) => fail('No apply during passive progress'),
      onRollback: (_) => fail('No rollback during passive progress'),
      run: run,
    );

Finder _step(int sequence) =>
    find.byKey(ValueKey('support_tool_activity_$sequence'));

void main() {
  testWidgets('numbered native calls follow sequence without mutating input', (
    tester,
  ) async {
    final fixture = SupportMessageListPassivityFixture();
    await fixture.run(tester, () async {
      const activities = [_executing, _completed];
      await tester.pumpWidget(
        fixture.host(_feed(_message(), _run(activities: activities))),
      );
      await tester.pump();

      expect(find.text('Ход работы'), findsOneWidget);
      expect(find.text('1.'), findsOneWidget);
      expect(find.text('2.'), findsOneWidget);
      expect(find.text('Поиск доступных источников'), findsOneWidget);
      expect(find.text('Чтение источника'), findsOneWidget);
      expect(find.text('Завершено'), findsOneWidget);
      expect(find.text('Выполнение…'), findsOneWidget);
      expect(find.text('Документация: example.invalid'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline_rounded), findsOneWidget);
      expect(find.byIcon(Icons.play_circle_outline_rounded), findsOneWidget);
      expect(
        tester.getTopLeft(_step(1)).dy,
        lessThan(tester.getTopLeft(_step(2)).dy),
      );
      expect(activities.map((activity) => activity.sequence), [2, 1]);
      expect(find.byType(SupportPlainMarkdown), findsOneWidget);
      expect(find.text('Ожидание ответа модели…'), findsNothing);
      expect(
        find.text('Ожидание ответа модели после вызовов инструментов…'),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(fixture.localAssetLoads, isEmpty);
    });
  });

  testWidgets('current calls survive failure and success, answer renders once', (
    tester,
  ) async {
    final fixture = SupportMessageListPassivityFixture();
    await fixture.run(tester, () async {
      await tester.pumpWidget(fixture.host(_feed(_message(), _run())));
      await tester.pump();
      expect(find.text('Выполнение…'), findsOneWidget);

      const failed = SupportModelToolActivity(
        sequence: 2,
        action: 'astoria_source_read',
        stage: SupportModelToolStage.failed,
        sourceLabel: 'Документация: example.invalid',
        detail: 'Источник недоступен в выбранной области.',
      );
      await tester.pumpWidget(
        fixture.host(
          _feed(
            _message(status: 'error'),
            _run(
              busy: false,
              status: PrivateTextStatus.error,
              activities: const [_completed, failed],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(_step(1), findsOneWidget);
      expect(_step(2), findsOneWidget);
      expect(find.text('Не выполнено'), findsOneWidget);
      expect(find.text('Выполнение…'), findsNothing);
      expect(find.text(failed.detail!), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
      expect(
        tester
            .widget<SupportPlainMarkdown>(find.byType(SupportPlainMarkdown))
            .text,
        'Сервис модели вернул ошибку или неполный ответ. Можно попробовать ещё раз.',
      );

      const readCompleted = SupportModelToolActivity(
        sequence: 2,
        action: 'astoria_source_read',
        stage: SupportModelToolStage.completed,
        sourceLabel: 'Документация: example.invalid',
      );
      await tester.pumpWidget(
        fixture.host(
          _feed(
            _message(status: 'complete', body: 'Безопасный ответ'),
            _run(
              busy: false,
              status: PrivateTextStatus.complete,
              activities: const [_completed, readCompleted],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(SupportModelToolActivityView), findsOneWidget);
      expect(find.text('Завершено'), findsNWidgets(2));
      expect(find.text('Выполнение…'), findsNothing);
      expect(find.text('Не выполнено'), findsNothing);
      expect(find.byType(SupportPlainMarkdown), findsOneWidget);
      expect(
        tester
            .widget<SupportPlainMarkdown>(find.byType(SupportPlainMarkdown))
            .text,
        'Безопасный ответ',
      );
      // A new attempt removes old in-memory progress rather than attaching it
      // to the same durable message from the previous attempt.
      await tester.pumpWidget(
        fixture.host(
          _feed(
            _message(status: 'complete', body: 'Безопасный ответ'),
            const SupportModelRunView(
              busy: true,
              runId: 'synthetic-next-tool-run',
              sessionId: _session,
              toolActivities: [_completed],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(SupportModelToolActivityView), findsNothing);
    });
  });

  testWidgets('locked, foreign and non-assistant rows never receive progress', (
    tester,
  ) async {
    final fixture = SupportMessageListPassivityFixture();
    await fixture.run(tester, () async {
      final cases = [
        _message(locked: true),
        _message(runId: 'synthetic-foreign-tool-run'),
        _message(session: 'synthetic-foreign-tool-session'),
        _message(runId: null),
        _message(role: SupportMessageRole.user),
        _message(role: SupportMessageRole.system),
      ];
      for (final message in cases) {
        await tester.pumpWidget(fixture.host(_feed(message, _run())));
        await tester.pump();
        expect(find.byType(SupportModelToolActivityView), findsNothing);
        expect(find.text('Ход работы'), findsNothing);
      }
      await tester.pumpWidget(
        fixture.host(_feed(_message(), _run(activities: const []))),
      );
      await tester.pump();
      expect(find.byType(SupportModelToolActivityView), findsNothing);
    });
  });

  testWidgets('late secret registration reprojects source without run update', (
    tester,
  ) async {
    final fixture = SupportMessageListPassivityFixture();
    await fixture.run(tester, () async {
      const activity = SupportModelToolActivity(
        sequence: 1,
        action: 'astoria_source_read',
        stage: SupportModelToolStage.completed,
        sourceLabel: _source,
      );
      final feed = _feed(_message(), _run(activities: const [activity]));
      await tester.pumpWidget(fixture.host(feed));
      await tester.pump();
      expect(find.text(_source), findsOneWidget);

      fixture.redaction.registerSecret(_canary);
      await tester.pump();
      await tester.pump();

      expect(find.text(_source), findsNothing);
      expect(
        find.text('Документация: example.invalid — [REDACTED]'),
        findsOneWidget,
      );
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        expect(
          text.data ?? text.textSpan?.toPlainText(),
          isNot(contains(_canary)),
        );
      }
      expect(
        tester.widget<SupportMessageList>(find.byType(SupportMessageList)),
        same(feed),
      );
      expect(activity.sourceLabel, _source);
      expect(fixture.localAssetLoads, isEmpty);
    });
  });

  testWidgets('all factual states and long source wrap at 390px mobile width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = SupportMessageListPassivityFixture();
    await fixture.run(tester, () async {
      final source = 'Документация: ${'source-' * 25}example.invalid';
      final activities = [
        for (final stage in SupportModelToolStage.values)
          SupportModelToolActivity(
            sequence: stage.index + 1,
            action: 'astoria_source_read',
            stage: stage,
            sourceLabel: stage == SupportModelToolStage.executing
                ? source
                : null,
          ),
      ];
      await tester.pumpWidget(
        fixture.host(
          SingleChildScrollView(
            padding: const EdgeInsets.all(30),
            child: SupportModelToolActivityView(
              activities: activities,
              display: SupportMessageDisplayProjection(
                redactor: fixture.redaction.redactor,
              ),
            ),
          ),
          scale: 1.6,
        ),
      );
      await tester.pump();
      for (final label in [
        'Подготовка вызова…',
        'Ожидание твоего согласия',
        'Выполнение…',
        'Завершено',
        'Не выполнено',
        'Остановлено',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      final sourceText = find.text(source);
      expect(sourceText, findsOneWidget);
      expect(tester.getSize(sourceText).height, greaterThan(40));
      final paragraph = tester.renderObject<RenderParagraph>(sourceText);
      expect(paragraph.didExceedMaxLines, isFalse);
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: source.length),
      );
      expect(boxes, isNotEmpty);
      // Selection rectangles include invisible trailing whitespace beyond a
      // wrapped line. Check every actual glyph, not that whitespace rectangle.
      for (var i = 0; i < source.length; i++) {
        if (source[i].trim().isEmpty) continue;
        final glyphs = paragraph.getBoxesForSelection(
          TextSelection(baseOffset: i, extentOffset: i + 1),
        );
        expect(glyphs, isNotEmpty);
        for (final box in glyphs) {
          expect(box.left, greaterThanOrEqualTo(-1));
          expect(box.right, lessThanOrEqualTo(paragraph.size.width + 1));
        }
      }
      expect(tester.takeException(), isNull);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });
}
