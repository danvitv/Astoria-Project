import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/llm/chat_message_embedding_service.dart';
import 'package:glaze_flutter/core/llm/embedding_service.dart';
import 'package:glaze_flutter/core/llm/memory_injection_service.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/chat_source_mutation_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/lorebook_embedding_provider.dart';
import 'package:glaze_flutter/features/chat/abort_handler.dart';
import 'package:glaze_flutter/features/chat/chat_message_service.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/services/stages/chat_embed_stage.dart';
import 'package:glaze_flutter/features/chat/services/stages/stage_context.dart';

final _messageServiceProvider = Provider(ChatMessageService.new);
const _config = EmbeddingConfig(endpoint: 'test');

final _stageProvider = Provider((ref) {
  const state = AsyncData(ChatState());
  final abort = AbortHandler(
    ref: ref,
    charId: 'c1',
    setState: (_) {},
    getState: () => state,
    mutateSession: (_, _) async => null,
    loadSession: (_) async => null,
  );
  return (
    stage: ChatEmbedStage(
      StageContext(
        ref: ref,
        charId: 'c1',
        abortHandler: abort,
        setState: (_) {},
        getState: () => state,
      ),
    ),
    genId: abort.nextGenId(),
  );
});

class _EmbeddingService extends EmbeddingService {
  int calls = 0;
  Completer<void>? entered;
  Completer<List<EmbeddingChunk>>? pending;

  @override
  Future<List<EmbeddingChunk>> getEmbeddingsWithChunks(
    List<String> texts,
    EmbeddingConfig config, {
    cancelToken,
    captureContext,
  }) async {
    calls++;
    entered?.complete();
    if (pending != null) return pending!.future;
    return [
      for (final text in texts)
        EmbeddingChunk(text: text, vector: const [1, 0]),
    ];
  }
}

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late ChatSession session;
  late _EmbeddingService embedder;
  late ChatMessageEmbeddingService indexer;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    session = ChatSession(
      id: 's1',
      characterId: 'c1',
      sessionIndex: 0,
      messages: [
        for (var i = 0; i < 15; i++)
          ChatMessage(
            id: 'm$i',
            role: i.isEven ? 'user' : 'assistant',
            content: 'message $i',
          ),
      ],
    );
    await container.read(chatRepoProvider).put(session);
    embedder = _EmbeddingService();
    indexer = ChatMessageEmbeddingService(
      container.read(embeddingRepoProvider),
      embedder,
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> index(List<ChatMessage> messages) =>
      indexer.indexSessionMessages(
        sessionId: session.id,
        messages: messages,
        config: _config,
      );

  test(
    'suffix deletion keeps untouched historical rows byte-for-byte',
    () async {
      await index(session.messages);
      final repo = container.read(embeddingRepoProvider);
      final original = await repo.getByEntryId('s1_0');
      final updated = await container
          .read(_messageServiceProvider)
          .deleteMessages(session, {for (var i = 9; i < 15; i++) i});

      expect(updated.messages.length, 9);
      expect(await repo.getByEntryId('s1_0'), original);
      expect(await repo.getByEntryId('s1_1'), isNull);
      expect(await repo.getByEntryId('s1_2'), isNull);
      // Recall has a usable source immediately, before a new answer/reindex.
      expect((await repo.getBySource('chat_message', 's1')).length, 1);
      embedder.calls = 0;
      await index(updated.messages);
      expect(embedder.calls, 0);
      expect(await repo.getByEntryId('s1_0'), original);
    },
  );

  test(
    'removing a failed tail before retry does not clear any history',
    () async {
      await index(session.messages);
      final repo = container.read(embeddingRepoProvider);
      final before = await repo.getBySource('chat_message', 's1');
      final failed = session.copyWith(
        messages: [
          ...session.messages,
          const ChatMessage(
            id: 'failed',
            role: 'assistant',
            content: 'HandshakeException',
            isError: true,
          ),
        ],
      );
      await container.read(chatRepoProvider).put(failed);
      await container.read(_messageServiceProvider).deleteMessage(failed, 15);

      expect(await repo.getBySource('chat_message', 's1'), before);
    },
  );

  test(
    'delayed background admission uses durable history, not a deleted snapshot',
    () async {
      await index(session.messages);
      final repo = container.read(embeddingRepoProvider);
      final before = await repo.getByEntryId('s1_0');
      final oldMessages = session.messages;
      await container.read(_messageServiceProvider).deleteMessages(session, {
        for (var i = 9; i < 15; i++) i,
      });
      final stageContainer = ProviderContainer(
        overrides: [
          appDbProvider.overrideWithValue(db),
          chatMessageEmbeddingServiceProvider.overrideWithValue(indexer),
          embeddingConfigProvider.overrideWithValue(_config),
        ],
      );
      addTearDown(stageContainer.dispose);
      final harness = stageContainer.read(_stageProvider);
      embedder.calls = 0;
      await harness.stage.run(
        sessionId: 's1',
        messages: oldMessages,
        genId: harness.genId,
      );

      expect(embedder.calls, 0);
      expect(await repo.getByEntryId('s1_0'), before);
      expect(await repo.getByEntryId('s1_1'), isNull);
      expect(await repo.getByEntryId('s1_2'), isNull);
    },
  );

  for (final blue in [false, true]) {
    test(
      '${blue ? 'blue' : 'green'} variant deletion invalidates only its group',
      () async {
        final active = ChatMessage(
          id: 'm9',
          role: 'assistant',
          content: 'removed variant',
          swipes: const ['removed variant', 'remaining variant'],
          agentSwipes: blue
              ? const [
                  AgentSwipe(content: 'removed variant'),
                  AgentSwipe(content: 'remaining variant'),
                ]
              : const [],
        );
        session = session.copyWith(
          messages: List<ChatMessage>.of(session.messages)..[9] = active,
        );
        await container.read(chatRepoProvider).put(session);
        await index(session.messages);
        final repo = container.read(embeddingRepoProvider);
        final first = await repo.getByEntryId('s1_0');
        final third = await repo.getByEntryId('s1_2');
        final service = container.read(_messageServiceProvider);
        final updated = blue
            ? await service.deleteActiveAgentSwipe(session, 9)
            : await service.deleteActiveSwipe(session, 9);

        expect(updated.messages[9].content, 'remaining variant');
        expect(await repo.getByEntryId('s1_0'), first);
        expect(await repo.getByEntryId('s1_1'), isNull);
        expect(await repo.getByEntryId('s1_2'), third);
        embedder.calls = 0;
        await index(updated.messages);
        expect(embedder.calls, 1);
        expect(await repo.getByEntryId('s1_0'), first);
        expect(await repo.getByEntryId('s1_2'), third);
      },
    );
  }

  test('late embedding response cannot undo a source mutation', () async {
    final mutations = container.read(chatSourceMutationRegistryProvider);
    await index(session.messages);
    final changed = session.copyWith(
      messages: List<ChatMessage>.of(session.messages)
        ..[14] = session.messages[14].copyWith(content: 'changed last message'),
    );
    await container.read(chatRepoProvider).put(changed);
    embedder.entered = Completer<void>();
    embedder.pending = Completer<List<EmbeddingChunk>>();
    final checkpoint = mutations.sessionCheckpoint('s1');
    final future = indexer.indexSessionMessages(
      sessionId: 's1',
      messages: changed.messages,
      config: _config,
      shouldAbort: () =>
          mutations.isSessionPending('s1') ||
          mutations.sessionCheckpoint('s1') != checkpoint,
    );
    await embedder.entered!.future;
    await container.read(_messageServiceProvider).deleteMessage(changed, 14);
    embedder.pending!.complete([
      const EmbeddingChunk(text: 'obsolete result', vector: [1, 0]),
    ]);
    await future;

    final repo = container.read(embeddingRepoProvider);
    expect(await repo.getByEntryId('s1_2'), isNull);
    expect(await repo.getByEntryId('s1_0'), isNotNull);
    expect(await repo.getByEntryId('s1_1'), isNotNull);
  });

  for (final fail in [false, true]) {
    test(
      'newer indexing wins over a late ${fail ? 'error' : 'success'}',
      () async {
        final pending = _EmbeddingService()
          ..entered = Completer<void>()
          ..pending = Completer<List<EmbeddingChunk>>();
        final old = ChatMessageEmbeddingService(
          container.read(embeddingRepoProvider),
          pending,
        );
        var current = true;
        final oldRun = old.indexSessionMessages(
          sessionId: 's1',
          messages: session.messages,
          config: _config,
          shouldAbort: () => !current,
        );
        await pending.entered!.future;
        current = false;
        final newer = session.messages
            .map(
              (message) =>
                  message.copyWith(content: '${message.content} newer'),
            )
            .toList();
        await index(newer);
        final repo = container.read(embeddingRepoProvider);
        final before = await repo.getBySource('chat_message', 's1');
        if (fail) {
          pending.pending!.completeError(StateError('old transport failed'));
        } else {
          pending.pending!.complete([
            const EmbeddingChunk(text: 'old result', vector: [0, 1]),
          ]);
        }
        await oldRun;
        expect(await repo.getBySource('chat_message', 's1'), before);
      },
    );
  }

  test('retired indexing does not even load or clean up rows', () async {
    await index(session.messages);
    final repo = container.read(embeddingRepoProvider);
    final before = await repo.getBySource('chat_message', 's1');
    await indexer.indexSessionMessages(
      sessionId: 's1',
      messages: const [],
      config: _config,
      shouldAbort: () => true,
    );
    expect(await repo.getBySource('chat_message', 's1'), before);
  });
}
