import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/manual_rewrite_apply_repo.dart';
import 'package:glaze_flutter/core/db/repositories/manual_rewrite_job_repo.dart';
import 'package:glaze_flutter/core/llm/session_lorebook_embedding_worker.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/lorebook_embedding_provider.dart';
import 'package:glaze_flutter/core/state/session_mutation_gate.dart';
import 'package:glaze_flutter/features/card_rewrite/rewrite_review_provider.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/chat_session_service.dart';
import 'package:glaze_flutter/features/chat/state/chat_native_owner_registry.dart';
import 'package:glaze_flutter/features/chat/state/chat_session_write_queue.dart';

const _session = ChatSession(
  id: 's',
  characterId: 'c',
  sessionIndex: 0,
  messages: [ChatMessage(id: 'a', role: 'assistant', content: 'Hi')],
);
final _snapshot = ManualRewriteJobSnapshot(
  job: RewriteJobRow(
    id: 'job',
    chatSessionId: 's',
    characterId: 'c',
    status: 'pending',
    requestJson: '{}',
    basisRevision: 1,
    basisRevisionHash: 'basis',
    canonStamp: 'canon',
    version: 1,
    appliedCharacterRevision: 0,
    appliedCharacterRevisionHash: '',
    createdAt: 1,
    updatedAt: 1,
  ),
  operations: const [],
);

class _Review extends RewriteReviewController {
  _Review(super.jobId);
  @override
  Future<String?> computeFreshCanonIdentity({
    required String sessionId,
    required Character character,
    bool stableStamp = false,
  }) async => 'canon';
}

class _Apply implements ManualRewriteApplyRepo {
  final entered = Completer<void>();
  final release = Completer<void>();
  bool fail = false;
  Future<void> Function()? commit;
  @override
  Future<ManualRewriteApplyOutcome> applyApproved({
    required String jobId,
    required String expectedCanonStamp,
    required int expectedJobVersion,
  }) async {
    entered.complete();
    await release.future;
    if (fail) throw StateError('synthetic apply failure');
    if (commit != null) {
      await commit!();
      return const ManualRewriteApplyOutcome.applied();
    }
    return const ManualRewriteApplyOutcome.blocked('synthetic');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Embeddings implements SessionLorebookEmbeddingWorker {
  @override
  Future<void> drain() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _PreparationBarrier implements ChatNativeMaintenanceBarrier {
  final entered = Completer<void>();
  final release = Completer<void>();
  bool armed = true;

  @override
  Future<void>? beforeLiveOwner() {
    if (!armed) return null;
    armed = false;
    entered.complete();
    return release.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late ProviderContainer container;
  late _Apply apply;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    apply = _Apply();
    container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        manualRewriteApplyRepoProvider.overrideWithValue(apply),
        sessionLorebookEmbeddingWorkerProvider.overrideWithValue(_Embeddings()),
        rewriteReviewUiProvider.overrideWith2(_Review.new),
      ],
    );
    await container
        .read(characterRepoProvider)
        .put(const Character(id: 'c', name: 'Card'));
    await container.read(chatRepoProvider).put(_session);
    await container.read(chatProvider('c').future);
  });
  tearDown(() async {
    if (!apply.release.isCompleted) apply.release.complete();
    container.dispose();
    ChatSessionService.clearCache();
    await db.close();
  });

  test(
    'command rejects apply while same-session foreground owns preparation',
    () async {
      final foreground = container
          .read(sessionMutationGateProvider)
          .tryForeground('s')!;
      final outcome = await container
          .read(rewriteReviewUiProvider('job').notifier)
          .apply(_snapshot);
      expect(outcome.reason, 'sessionBusy');
      expect(apply.entered.isCompleted, isFalse);
      expect(
        (await container.read(chatRepoProvider).getById('s'))!.characterId,
        'c',
      );
      foreground.release();
      final pending = container
          .read(rewriteReviewUiProvider('job').notifier)
          .apply(_snapshot);
      await apply.entered.future;
      apply.release.complete();
      expect((await pending).reason, 'synthetic');
    },
  );

  test(
    'apply blocks Send and mutations before optimistic paint; failure releases claim',
    () async {
      final controller = container.read(
        rewriteReviewUiProvider('job').notifier,
      );
      final pending = controller.apply(_snapshot);
      await apply.entered.future;
      final chat = container.read(chatProvider('c').notifier);
      expect(await chat.trySendMessage('Do not append'), isFalse);
      await chat.deleteMessages({0});
      await chat.regenerateLastAssistant();
      await chat.continueMessage();
      expect(
        (await container.read(chatRepoProvider).getById('s'))!.messages,
        _session.messages,
      );
      expect(
        container.read(chatProvider('c')).requireValue.isSendPending,
        isFalse,
      );
      apply.fail = true;
      final failed = expectLater(pending, throwsStateError);
      apply.release.complete();
      await failed;
      final claim = container
          .read(sessionMutationGateProvider)
          .tryForeground('s');
      expect(claim, isNotNull);
      claim!.release();
    },
  );

  test(
    'queued session write rejects apply instead of waiting in a transaction',
    () async {
      final queue = ChatSessionWriteQueue();
      final release = Completer<void>();
      final unregister = container
          .read(chatNativeOwnerRegistryProvider)
          .register(
            ChatNativeOwner(
              characterId: 'synthetic',
              sessionId: () => 's',
              isIdle: () => true,
              queue: queue,
              refresh: (_, _, _) async => true,
            ),
          );
      final pending = queue.run(() => release.future);
      final outcome = await container
          .read(rewriteReviewUiProvider('job').notifier)
          .apply(_snapshot);
      expect(outcome.reason, 'sessionBusy');
      expect(apply.entered.isCompleted, isFalse);
      release.complete();
      await pending;
      expect(queue.isIdle, isTrue);
      unregister();
    },
  );

  test(
    'successful rebind retires loaded source before releasing Apply',
    () async {
      final repo = container.read(chatRepoProvider);
      await container
          .read(characterRepoProvider)
          .put(const Character(id: 'fork', name: 'Fork'));
      apply.commit = () async {
        await repo.put(_session.copyWith(characterId: 'fork'));
      };
      final pending = container
          .read(rewriteReviewUiProvider('job').notifier)
          .apply(_snapshot);
      await apply.entered.future;
      apply.release.complete();
      expect((await pending).isApplied, isTrue);
      final fork = await container.read(chatProvider('fork').future);
      expect(fork.session!.id, 's');
      expect(fork.session!.characterId, 'fork');
      expect(fork.isGenerating || fork.isPostGenRunning, isFalse);
      final claim = container
          .read(sessionMutationGateProvider)
          .tryForeground('s');
      expect(claim, isNotNull);
      claim!.release();
    },
  );

  test('Send paused on A cannot adopt B while Apply owns B', () async {
    const second = ChatSession(
      id: 'b',
      characterId: 'c',
      sessionIndex: 1,
      messages: [ChatMessage(id: 'b-a', role: 'assistant', content: 'B')],
    );
    await container.read(chatRepoProvider).put(second);
    final barrier = _PreparationBarrier();
    final unregister = container
        .read(chatNativeOwnerRegistryProvider)
        .registerMaintenance(barrier);
    final chat = container.read(chatProvider('c').notifier);
    final sent = chat.trySendMessage('Must not leak into B');
    await barrier.entered.future;
    await chat.switchSession(1);
    expect(container.read(chatProvider('c')).requireValue.session!.id, 'b');
    final snap = ManualRewriteJobSnapshot(
      job: _snapshot.job.copyWith(chatSessionId: 'b'),
      operations: const [],
    );
    final pending = container
        .read(rewriteReviewUiProvider('job').notifier)
        .apply(snap);
    await apply.entered.future;
    barrier.release.complete();
    expect(await sent, isFalse);
    expect(
      (await container.read(chatRepoProvider).getById('b'))!.messages,
      second.messages,
    );
    expect(
      container.read(chatProvider('c')).requireValue.isGenerating,
      isFalse,
    );
    apply.release.complete();
    await pending;
    unregister();
  });

  test(
    'selection fences Apply before resolving its target, and vice versa',
    () async {
      await container
          .read(chatRepoProvider)
          .put(const ChatSession(id: 'b', characterId: 'c', sessionIndex: 1));
      final chat = container.read(chatProvider('c').notifier);
      final gate = container.read(sessionMutationGateProvider);
      final applyLease = gate.tryApply('b', characterId: 'c')!;
      await chat.switchSession(1);
      expect(container.read(chatProvider('c')).requireValue.session!.id, 's');
      applyLease.release();

      final barrier = _PreparationBarrier();
      final unregister = container
          .read(chatNativeOwnerRegistryProvider)
          .registerMaintenance(barrier);
      final switching = chat.switchSession(1);
      await barrier.entered.future;
      final snap = ManualRewriteJobSnapshot(
        job: _snapshot.job.copyWith(chatSessionId: 'b'),
        operations: const [],
      );
      final outcome = await container
          .read(rewriteReviewUiProvider('job').notifier)
          .apply(snap);
      expect(outcome.reason, 'sessionBusy');
      expect(apply.entered.isCompleted, isFalse);
      barrier.release.complete();
      await switching;
      expect(container.read(chatProvider('c')).requireValue.session!.id, 'b');
      unregister();
    },
  );
}
