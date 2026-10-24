import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_composer_bar.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';

import 'support_compaction_fixture.dart';

void main() {
  compactionTest(
    'ALL three old pairs once before compact; persisted prefix summary and ALL suffix on next Send',
    (tester, f) async {
      compactDraft(tester).text = 'CURRENT_QUESTION_BEFORE_COMPACT';
      f.response = compactResponse(
        'FIRST_NATIVE_REPLY',
        input: 123,
        output: 17,
        total: 140,
      );
      final first = await compactTap(tester, f, compactSend);
      expect(first.saved, isTrue);
      final before = compactWire(f, 0);
      for (var i = 0; i < 3; i++) {
        for (final role in ['user', 'assistant']) {
          expect(
            before.where((m) => m['content'] == 'SYNTHETIC_${i}_$role'),
            hasLength(1),
          );
        }
      }
      expect(before.last['content'], 'CURRENT_QUESTION_BEFORE_COMPACT');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('support_request_token_usage')),
        findsOneWidget,
      );
      final usage = tester
          .widget<SupportComposerBar>(find.byType(SupportComposerBar))
          .usage;
      expect(usage?.inputTokens, 123);
      expect(usage?.outputTokens, 17);
      expect(usage?.totalTokens, 140);

      final history = await f.action(
        tester,
        () => f.repo.getMessagesForSession(ModelScreenFixture.session),
      );
      compactDraft(tester).text = 'UNSENT_DRAFT_IS_NOT_A_COMPACT_QUESTION';
      f.response = compactResponse(
        compactSummary,
        input: 88,
        output: 12,
        total: 100,
      );
      final compact = await compactTap(tester, f, compactButton);
      expect(compact.compacted, isTrue);
      expect(compact.isCompaction, isTrue);
      final checkpoint = await f.action(tester, () => compactBlock(f));
      expect(checkpoint?.summary, compactSummary);
      expect(checkpoint?.isLocked, isFalse);
      expect(
        await f.action(
          tester,
          () => f.repo.getMessagesForSession(ModelScreenFixture.session),
        ),
        history,
      );
      expect(
        compactDraft(tester).text,
        'UNSENT_DRAFT_IS_NOT_A_COMPACT_QUESTION',
      );
      expect(
        compactWire(f, 1).map((m) => m['content']).join('\n'),
        isNot(contains('UNSENT_DRAFT')),
      );

      // Reconstruct the actual model issuer as after restart; no in-memory checkpoint or usage survives.
      final original = f.bridge;
      await f.action(tester, () async {
        f.container.invalidate(supportModelUiBridgeProvider);
        expect(identical(original, f.bridge), isFalse);
        await f.workspace.refresh();
      });
      await tester.pumpAndSettle();
      compactDraft(tester).text = 'CURRENT_QUESTION_AFTER_COMPACT';
      f.response = compactResponse('AFTER_NATIVE_REPLY');
      final next = await compactTap(tester, f, compactSend);
      expect(next.saved, isTrue);
      final wire = compactWire(
        f,
        2,
      ).map((m) => m['content'] as String).toList();
      expect(wire.where((text) => text.contains(compactSummary)), hasLength(1));
      expect(wire, isNot(contains('SYNTHETIC_0_user')));
      expect(wire, isNot(contains('SYNTHETIC_0_assistant')));
      expect(wire, contains('SYNTHETIC_1_assistant'));
      expect(wire, contains('SYNTHETIC_2_user'));
      expect(wire, contains('SYNTHETIC_2_assistant'));
      expect(wire, contains('CURRENT_QUESTION_BEFORE_COMPACT'));
      expect(wire, contains('FIRST_NATIVE_REPLY'));
      expect(wire.last, 'CURRENT_QUESTION_AFTER_COMPACT');
      await tester.pumpAndSettle();
      final composer = tester.widget<SupportComposerBar>(
        find.byType(SupportComposerBar),
      );
      expect(composer.usage, isNull);
      expect(find.textContaining('вход: нет данных'), findsOneWidget);
    },
  );

  for (final enabled in [true, false]) {
    compactionTest(
      'measured near-limit input triggers auto compact iff DCP $enabled',
      (tester, f) async {
        await f.action(tester, () async {
          await f.store.changeSettings(
            ModelScreenFixture.session,
            (s) => s.copyWith(dcpCompressionEnabled: enabled),
          );
          await f.workspace.refresh();
        });
        await tester.pumpAndSettle();
        f.response = compactResponse(
          'PRESSURE_REPLY',
          input: 30000,
          output: 4,
          total: 30004,
        );
        compactDraft(tester).text = 'PRESSURE_FIRST_QUESTION';
        expect((await compactTap(tester, f, compactSend)).saved, isTrue);
        await tester.pumpAndSettle();
        f.response = compactResponse(compactSummary);
        f.onFinalAdapter = (_) {
          if (enabled && f.adapters.length == 2) {
            f.response = compactResponse('FINAL_AFTER_AUTO');
          }
        };
        compactDraft(tester).text = 'PRESSURE_SECOND_QUESTION';
        expect((await compactTap(tester, f, compactSend)).saved, isTrue);
        expect(f.adapters, hasLength(enabled ? 3 : 2));
        expect(
          await f.action(tester, () => compactBlock(f)),
          enabled ? isNotNull : isNull,
        );
        if (enabled) {
          expect(
            compactWire(f, 2).map((m) => m['content']).join('\n'),
            contains(compactSummary),
          );
        } else {
          expect(
            compactWire(f, 1).map((m) => m['content']),
            contains('SYNTHETIC_0_user'),
          );
        }
      },
    );
  }

  compactionTest(
    'Stop during quiet manual compact installs no checkpoint and retains original messages',
    (tester, f) async {
      f.quiet = true;
      final original = await compactReadyButton(tester, f, compactButton);
      final completed = await f.signal(
        tester,
        () => compactionTerminal(f, original: original),
        label: 'stopped compact settlement',
      );
      final adapter = await f.signal(
        tester,
        () => f.adapterCreated.future,
        label: 'compact final HTTP',
      );
      await compactGesture(tester, f, compactButton, original: original);
      final native = await f.finish(tester, adapter);
      final listening = await f.signal(
        tester,
        () => native.responseListening,
        label: 'original compact response stream subscribed',
      );
      await f.finish(tester, listening);
      final cancelled = await f.signal(
        tester,
        () => native.cancelObserved.future,
        label: 'original compact HTTP cancellation',
      );
      await tester.pump();
      await compactGesture(tester, f, compactStop);
      final result = await f.finish(tester, completed);
      await f.finish(tester, cancelled);
      expect(result.compacted, isFalse);
      expect(await f.action(tester, () => compactBlock(f)), isNull);
      expect(
        await f.action(
          tester,
          () => f.repo.getMessagesForSession(ModelScreenFixture.session),
        ),
        hasLength(7),
      );
    },
  );

  compactionTest(
    'source replacement during checkpoint AEAD never installs candidate or paints old usage',
    (tester, f) async {
      final original = await compactReadyButton(tester, f, compactButton);
      final barrier = await f.action(tester, f.barrier);
      final entered = await f.signal(
        tester,
        () => barrier.entered.future,
        label: 'checkpoint encrypt entered',
      );
      final released = await f.signal(
        tester,
        () => compactionReleased(original),
        label: 'original compact claim release',
      );
      await f.action(tester, () {
        f.response = compactResponse(
          compactSummary,
          input: 333,
          output: 22,
          total: 355,
        );
        f.primitive.afterEncrypt = (aad) async {
          if (aad.contains('support.compaction:') && !barrier.released) {
            await barrier.wait();
          }
        };
      });
      await compactGesture(tester, f, compactButton, original: original);
      await f.finish(tester, entered);
      await f.action(tester, () {
        f.workspace.selectSession(ModelScreenFixture.other);
        barrier.release();
        f.primitive.afterEncrypt = null;
      });
      await f.finish(tester, released);
      await f.action(tester, f.workspace.refresh);
      await tester.pumpAndSettle();
      expect(await f.action(tester, () => compactBlock(f)), isNull);
      expect(
        tester
            .widget<SupportComposerBar>(find.byType(SupportComposerBar))
            .usage,
        isNull,
      );
      expect(f.state.activeSessionId, ModelScreenFixture.other);
    },
  );

  compactionTest(
    'cancelled replacement compact preserves the prior valid encrypted checkpoint',
    (tester, f) async {
      f.response = compactResponse(compactSummary);
      expect((await compactTap(tester, f, compactButton)).compacted, isTrue);
      final original = await f.action(tester, () => compactBlock(f));
      await tester.pumpAndSettle();
      f.quiet = true;
      final bridge = await compactReadyButton(tester, f, compactButton);
      final complete = await f.signal(
        tester,
        () => compactionTerminal(f, original: bridge),
        label: 'cancelled replacement compact',
      );
      final entered = await f.action(tester, f.barrier);
      f.onFinalAdapter = (adapter) {
        unawaited(
          adapter.responseListening.then((_) {
            if (!entered.entered.isCompleted) entered.entered.complete();
          }),
        );
      };
      final adapter = await f.signal(
        tester,
        () => entered.entered.future,
        label: 'second compact native adapter',
      );
      await compactGesture(tester, f, compactButton, original: bridge);
      await f.finish(tester, adapter);
      await tester.pump();
      await compactGesture(tester, f, compactStop);
      expect((await f.finish(tester, complete)).compacted, isFalse);
      expect(await f.action(tester, () => compactBlock(f)), original);
    },
  );
}
