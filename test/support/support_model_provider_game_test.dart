import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/session_deletion_repo.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_dependencies.dart';

import 'helpers/support_model_provider_fixture.dart';
import 'helpers/support_model_provider_fixture_game.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final target in ['message', 'session']) {
    test(
      'native invalidation port recognizes selected game $target before queued neutral deletion',
      () async {
        await ModelProviderFixture().run((f) async {
          await f.seedSelectedGame();
          final send = f.send();
          final preview = await f.preview(send);
          expect(preview.gameMessages, 1);
          expect(
            preview.messages.map((m) => m.text).join('\n'),
            contains('Selected game text'),
          );
          expect(
            preview.messages.map((m) => m.text).join('\n'),
            isNot(contains(ModelProviderFixture.excluded)),
          );
          final writes = f.container.read(supportModelDurableWritesProvider);
          final barrier = f.barrier();
          final hold = writes.enqueue(barrier.wait);
          await barrier.entered.future;
          if (target == 'message') {
            writes.invalidateMessage(
              modelProviderGameSession,
              modelProviderGameMessage,
            );
          } else {
            writes.invalidateSession(modelProviderGameSession);
          }
          expect(
            preview.isCurrent,
            isFalse,
            reason: 'Game references must invalidate BEFORE queue entry.',
          );
          expect(send.approve(preview), isNull);
          final deletion = writes.enqueue(() async {
            final neutral = SessionDeletionRepo(f.db);
            if (target == 'message') {
              await neutral.clearSession(
                sessionId: modelProviderGameSession,
                replacementMessages: [],
              );
            } else {
              await neutral.deleteSession(modelProviderGameSession);
            }
          });
          barrier.release();
          await hold;
          await deletion;
          final result = await send.finished;
          expect(result.accepted, isTrue);
          expect(
            result.saved,
            isTrue,
            reason: 'Original support reply custody remains valid.',
          );
          expect(f.adapters, isEmpty);
          expect(
            (await f.repo.getMessageById(preview.replyMessageId))!.status,
            'stopped',
          );
        });
      },
    );
  }
}
