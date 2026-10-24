import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_composer_bar.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_model_prompt_preview_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_privacy_review_sheet.dart';

import 'support_direct_conversation_fixture.dart';

void main() {
  directConversationTest(
    'actual direct quiet SSE Stop reaches the original CancelToken',
    (tester, f) async {
      await f.action(tester, () {
        f.quiet = true;
        f.response = '';
      });
      final terminal = await f.signal(
        tester,
        () => directTerminal(f),
        label: 'original quiet direct Stop terminal',
      );
      final created = await f.signal(
        tester,
        () => f.adapterCreated.future,
        label: 'original quiet direct adapter',
      );
      await f.action(tester, () async {
        directDraft(tester).text = 'Quiet direct question';
        await tester.tap(find.byKey(directSend));
      });
      final adapter = await f.finish(tester, created);
      final listening = await f.signal(
        tester,
        () => adapter.responseListening,
        label: 'actual quiet response subscription',
      );
      await f.finish(tester, listening);
      await tester.pump();
      final cancelled = await f.signal(
        tester,
        () => adapter.cancelObserved.future,
        label: 'original transport CancelToken',
      );
      await f.action(tester, () => tester.tap(find.byKey(directStop)));
      await f.finish(tester, cancelled);
      final result = await f.finish(tester, terminal);
      expect(result.accepted, isTrue);
      expect(result.saved, isTrue);
      expect(f.adapters, hasLength(1));
      expect(adapter.fetches, 1);
      expect(adapter.closed, isTrue);
    },
  );

  for (final replacement in ['Stop', 'source', 'session', 'settings']) {
    directConversationTest(
      'actual $replacement before wire denies POST without rebinding',
      (tester, f) async {
        final original = await f.action(tester, () => f.bridge);
        final gate = await f.action(tester, f.barrier);
        final entered = await f.signal(
          tester,
          () => gate.entered.future,
          label: 'original final ROOT entered',
        );
        await f.action(tester, () {
          f.sql.afterSelect = (statement, _) async {
            if (statement == 'PRAGMA busy_timeout' && !gate.released) {
              await gate.wait();
            }
          };
        });
        await f.action(tester, () async {
          directDraft(tester).text = 'Original exact direct USER';
          await tester.tap(find.byKey(directSend));
        });
        await f.finish(tester, entered);
        await tester.pump();
        final finished = await f.signal(tester, () {
          final view = original.view;
          expect(view.busy, isTrue);
          // Retained original send; later provider/session reads cannot replace it.
          return tester
                      .widget<SupportComposerBar>(
                        find.byType(SupportComposerBar),
                      )
                      .onStop ==
                  null
              ? throw StateError('Original Stop missing')
              : directRelease(original);
        }, label: 'original final ROOT release');
        ScreenSignal<bool>? mutation;
        switch (replacement) {
          case 'Stop':
            await f.action(tester, () => tester.tap(find.byKey(directStop)));
          case 'source':
            mutation = await f.signal(
              tester,
              () => f.workspace.deleteMessage('old'),
              label: 'original source deletion',
            );
          case 'session':
            await f.action(
              tester,
              () => f.workspace.selectSession(ModelScreenFixture.other),
            );
          case 'settings':
            mutation = await f.signal(
              tester,
              () => f.workspace.selectModel('replacement-model'),
              label: 'original settings replacement',
            );
        }
        await f.action(tester, () {
          gate.release();
          f.sql.afterSelect = null;
        });
        await f.finish(tester, finished);
        if (mutation != null) await f.finish(tester, mutation);
        final refresh = await f.signal(
          tester,
          f.workspace.refresh,
          label: 'replacement workspace refresh',
        );
        await f.finish(tester, refresh);
        await tester.pumpAndSettle();
        expect(f.adapters.fold<int>(0, (n, a) => n + a.fetches), 0);
        expect(find.byType(SupportPrivacyReviewSheet), findsNothing);
        expect(find.byType(SupportModelPromptPreviewSheet), findsNothing);
        final durable = await f.signal(
          tester,
          () => f.repo.getMessagesForSession(ModelScreenFixture.session),
          label: 'original durable accepted USER',
        );
        expect(
          (await f.finish(tester, durable)).where(
            (m) => m.role == 'user' && m.body == 'Original exact direct USER',
          ),
          hasLength(1),
        );
        if (replacement == 'session') {
          expect(f.state.activeMessages, hasLength(1));
        }
      },
    );
  }
}
