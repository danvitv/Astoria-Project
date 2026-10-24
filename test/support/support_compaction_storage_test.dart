import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_text_context_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';

import 'helpers/support_native_input_fixture.dart';

void main() {
  test(
    'restart reader verifies >2000 compacted sources without decrypting old bodies, then reads ALL suffix',
    () async {
      final f = NativeInputFixture();
      addTearDown(f.db.close);
      await f.seed();
      for (var i = 0; i < 2002; i++) {
        await f.repo.appendMessage(
          SupportMessage(
            id: 'mature-$i',
            sessionId: NativeInputFixture.sessionId,
            role: i.isEven ? 'user' : 'assistant',
            body: 'old production-shaped body $i',
            createdAt: 100 + i,
          ),
        );
      }
      final source = await f.repo.captureCompactionSource(
        sessionId: NativeInputFixture.sessionId,
        endMessageId: 'mature-2001',
        isCurrent: () => true,
      );
      expect(source, isNotNull);
      final installed = await f.repo.installCompactionCheckpoint(
        expected: source!,
        summary: 'Synthetic storage checkpoint (not a model-generation claim)',
        lineageJson: '{}',
        createdAt: 2200,
        isCurrent: () => true,
      );
      expect(installed, isNotNull);
      for (var i = 0; i < 2; i++) {
        await f.repo.appendMessage(
          SupportMessage(
            id: 'retained-$i',
            sessionId: NativeInputFixture.sessionId,
            role: i == 0 ? 'user' : 'assistant',
            body: 'retained $i',
            createdAt: 2300 + i,
          ),
        );
      }
      final user = await f.append(
        NativeInputFixture.input.copyWith(createdAt: 2400),
      );
      expect(user, isNotNull);
      final restored = await SupportRepo(f.db, f.cipher)
          .readCompactionCheckpoint(
            sessionId: NativeInputFixture.sessionId,
            isCurrent: () => true,
          );
      expect(restored?.source.digest, source.digest);
      f.primitive.decryptAads.clear();
      final history = SupportTextContextRepo(
        db: f.db,
        cipher: f.cipher,
        currentRedactor: () => SecretRedactor(),
      );
      final boundary = await history.captureSupportSessionBoundary(
        sessionId: NativeInputFixture.sessionId,
        userMessageId: user!.id,
        runId: user.runId!,
      );
      final suffix = await history.loadCurrentConversation(
        sessionId: NativeInputFixture.sessionId,
        currentInput: boundary,
        compaction: restored,
      );
      expect(suffix.messageIds, ['retained-0', 'retained-1']);
      expect(suffix.messages.map((m) => m.text), ['retained 0', 'retained 1']);
      expect(
        f.primitive.decryptAads.any((aad) => aad.contains('mature-')),
        isFalse,
      );
      expect(await history.revalidate(suffix), isTrue);
      expect(
        await f.repo.getMessagesForSession(NativeInputFixture.sessionId),
        hasLength(2006),
      );
      await f.repo.mutateMessage(
        messageId: 'mature-0',
        mutate: (m) => m.copyWith(body: 'edited prefix'),
      );
      expect(await history.revalidate(suffix), isFalse);
      await expectLater(
        SupportRepo(f.db, f.cipher).readCompactionCheckpoint(
          sessionId: NativeInputFixture.sessionId,
          isCurrent: () => true,
        ),
        throwsStateError,
      );
    },
  );
}
