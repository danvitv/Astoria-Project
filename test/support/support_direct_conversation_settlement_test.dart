import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';

import 'support_direct_conversation_fixture.dart';

void main() {
  directConversationTest(
    'late ORIGINAL durable success never paints replacement session',
    (tester, f) async {
      final original = await f.action(tester, () => f.bridge);
      final gate = await f.action(tester, f.barrier);
      final entered = await f.signal(
        tester,
        () => gate.entered.future,
        label: 'original final settlement encrypt entered',
      );
      final released = await f.signal(
        tester,
        () => directRelease(original),
        label: 'original direct claim release',
      );
      await f.action(tester, () {
        f.primitive.afterEncrypt = (aad) async {
          if (aad.contains('support_messages') &&
              original.view.phase == SupportModelPhase.settling &&
              !gate.released) {
            await gate.wait();
          }
        };
      });
      await f.action(tester, () async {
        directDraft(tester).text = 'Original accepted USER';
        await tester.tap(find.byKey(directSend));
      });
      await f.finish(tester, entered);
      expect(f.adapters, hasLength(1));
      directWire(f, 0);
      await f.action(tester, () {
        f.workspace.selectSession(ModelScreenFixture.other);
        gate.release();
        f.primitive.afterEncrypt = null;
      });
      await f.finish(tester, released);
      // The active original bridge is not assumed to publish a terminal label
      // into a replacement. Join the owning FIFO and read original durable rows.
      final refresh = await f.signal(
        tester,
        f.workspace.refresh,
        label: 'late original settlement and replacement refresh',
      );
      await f.finish(tester, refresh);
      await tester.pumpAndSettle();
      final rows = await f.signal(
        tester,
        () => f.repo.getMessagesForSession(ModelScreenFixture.session),
        label: 'original durable terminal rows',
      );
      final durable = await f.finish(tester, rows);
      expect(
        durable.where(
          (m) => m.role == 'user' && m.body == 'Original accepted USER',
        ),
        hasLength(1),
      );
      expect(
        durable.where(
          (m) =>
              m.role == 'assistant' &&
              m.body == 'Safe actual screen answer' &&
              m.status == 'complete',
        ),
        hasLength(1),
      );
      expect(f.state.activeSessionId, ModelScreenFixture.other);
      expect(
        f.state.activeMessages.any(
          (m) =>
              m.body == 'Safe actual screen answer' ||
              m.body == 'Original accepted USER',
        ),
        isFalse,
      );
      expect(f.adapters, hasLength(1));
    },
  );
}
