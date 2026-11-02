import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/embedding_repo.dart';
import 'package:glaze_flutter/core/llm/chat_message_embedding_chunks.dart';
import 'package:glaze_flutter/core/llm/chat_message_embedding_service.dart';
import 'package:glaze_flutter/core/llm/embedding_service.dart';
import 'package:glaze_flutter/core/llm/message_recall_service.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';

class _Embedder extends EmbeddingService {
  Object? error;
  List<List<double>>? overrideVectors;
  int calls = 0;
  List<String> lastTexts = const [];

  @override
  Future<List<EmbeddingChunk>> getEmbeddingsWithChunks(
    List<String> texts,
    EmbeddingConfig config, {
    cancelToken,
    captureContext,
  }) async {
    calls++;
    lastTexts = texts;
    if (error != null) throw error!;
    return [
      for (final (i, text) in texts.indexed)
        EmbeddingChunk(
          text: text,
          vector: overrideVectors?[i % overrideVectors!.length] ?? const [1, 0],
        ),
    ];
  }
}

void main() {
  test(
    'message boundaries and original offsets survive paragraph splitting',
    () {
      final messages = [
        ChatMessage(
          id: 'a',
          role: 'user',
          content: 'First paragraph.\n\n' * 20,
        ),
        ChatMessage(
          id: 'b',
          role: 'assistant',
          content: 'Different reply. ' * 20,
        ),
      ];
      final group = ChatMessageEmbeddingService.formatChunk(messages);
      final parts = ChatMessageEmbeddingChunks.split(messages, 32);
      expect(parts.length, greaterThan(2));
      for (final part in parts) {
        expect(group.substring(part.groupStart, part.groupEnd), part.text);
        expect(part.text.length, lessThanOrEqualTo(128));
        expect(EmbeddingService.splitTextIntoChunks(part.text, 32), [
          part.text,
        ]);
        expect(
          part.text.contains('First') && part.text.contains('Different'),
          isFalse,
        );
      }
    },
  );

  test('hard cuts preserve UTF-16 pairs and obey the embedder size', () {
    final source = 'x😀' * 50;
    final chunks = EmbeddingService.splitTextIntoChunks(source, 2);
    expect(chunks.join(), source);
    for (final chunk in chunks) {
      expect(chunk.length, lessThanOrEqualTo(8));
      expect(
        chunk.codeUnitAt(chunk.length - 1),
        isNot(inInclusiveRange(0xD800, 0xDBFF)),
      );
      expect(chunk.codeUnitAt(0), isNot(inInclusiveRange(0xDC00, 0xDFFF)));
    }
  });

  group('message-aware index and recall', () {
    const config = EmbeddingConfig(endpoint: 'test', maxChunkTokens: 32);
    late AppDatabase db;
    late EmbeddingRepo repo;
    late _Embedder embedder;
    late ChatMessageEmbeddingService indexer;
    late List<ChatMessage> messages;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repo = EmbeddingRepo(db);
      embedder = _Embedder();
      indexer = ChatMessageEmbeddingService(repo, embedder);
      messages = [
        const ChatMessage(id: 'a', role: 'user', content: 'Same sentence.'),
        const ChatMessage(
          id: 'b',
          role: 'assistant',
          content: 'Same sentence.',
        ),
        const ChatMessage(id: 'c', role: 'user', content: 'Another sentence.'),
        const ChatMessage(
          id: 'd',
          role: 'assistant',
          content: 'Fourth sentence.',
        ),
        const ChatMessage(id: 'e', role: 'user', content: 'Fifth sentence.'),
      ];
    });
    tearDown(() => db.close());

    Future<void> index() => indexer.indexSessionMessages(
      sessionId: 's',
      messages: messages,
      config: config,
    );

    test(
      'separately scores each message, even beside visible group members',
      () async {
        await index();
        final row = (await repo.getByEntryId('s_0'))!;
        expect(repo.decodeVectors(row), hasLength(5));
        expect(
          repo.decodeMetadata(row)!['chunkingVersion'],
          ChatMessageEmbeddingChunks.version,
        );
        final result = await MessageRecallService(repo, embedder).recall(
          sessionId: 's',
          currentText: 'query',
          config: config,
          visibleMessageIds: {'b', 'c', 'd', 'e'},
          sourceMessages: {for (final message in messages) message.id: message},
          allowedSourceMessageIds: messages.map((m) => m.id).toSet(),
        );
        expect(result.matches, hasLength(1));
        final match = result.matches.single;
        expect(match.messageIds, ['a']);
        expect(match.sourceSpans.single.role, 'user');
        expect(match.rawText, 'user: Same sentence.');
        expect(result.counters['visibleRejected'], 4);
        embedder.calls = 0;
        await index();
        expect(embedder.calls, 0);
        expect(await repo.getByEntryId('s_0'), row);
      },
    );

    test(
      'repeated excerpts use verified offsets, not guessed source roles',
      () async {
        messages = [
          for (final m in messages)
            m.copyWith(content: 'Repeated phrase. ' * 20),
        ];
        await index();
        final result = await MessageRecallService(repo, embedder).recall(
          sessionId: 's',
          currentText: 'query',
          config: config,
          sourceMessages: {for (final message in messages) message.id: message},
        );
        expect(result.matches.length, greaterThan(5));
        for (final match in result.matches) {
          expect(match.sourceSpans, hasLength(1));
          final span = match.sourceSpans.single;
          final source = messages.singleWhere((m) => m.id == span.messageId);
          expect(match.messageIds, [source.id]);
          expect(span.role, source.role);
          expect(
            match.rawText!.substring(span.excerptStart, span.excerptEnd),
            source.content.substring(span.sourceStart, span.sourceEnd),
          );
        }
      },
    );

    test(
      'old compatible index survives failed upgrade and is replaced on success',
      () async {
        final text = ChatMessageEmbeddingService.formatChunk(messages);
        await repo.putEmbeddingVector(
          entryId: 's_0',
          sourceType: 'chat_message',
          sourceId: 's',
          textHash: computeHash(text),
          vectors: const [
            [1, 0],
          ],
          retrievalMetadata: embeddingMetadataForConfig(
            config,
            const [
              [1, 0],
            ],
            chunks: [
              {'index': 0, 'text': text},
            ],
            extra: {'messageIds': messages.map((m) => m.id).toList()},
          ),
        );
        final old = await repo.getByEntryId('s_0');
        embedder.error = StateError('offline');
        await index();
        expect(await repo.getByEntryId('s_0'), old);
        embedder.error = RateLimitException(1);
        await index();
        expect(await repo.getByEntryId('s_0'), old);
        embedder.error = null;
        for (final invalid in <List<List<double>>>[
          [<double>[]],
          [
            [double.nan, 0],
          ],
          [
            [0, 0],
          ],
          [
            [1, 0],
            [1],
          ],
        ]) {
          embedder.overrideVectors = invalid;
          await index();
          expect(await repo.getByEntryId('s_0'), old);
        }
        embedder.overrideVectors = null;
        await index();
        final updated = (await repo.getByEntryId('s_0'))!;
        expect(repo.decodeVectors(updated), hasLength(5));
        expect(updated.textHash, old!.textHash);
      },
    );

    test(
      'forged or cross-message ranges cannot narrow group provenance',
      () async {
        final text = ChatMessageEmbeddingService.formatChunk(messages);
        for (final malformed in [
          {'groupStart': -1, 'groupEnd': 3},
          {'groupStart': 0, 'groupEnd': 3},
          {'groupStart': 0, 'groupEnd': text.length},
          {'groupStart': '0', 'groupEnd': text.length},
        ]) {
          await repo.putEmbeddingVector(
            entryId: 's_0',
            sourceType: 'chat_message',
            sourceId: 's',
            textHash: computeHash(text),
            vectors: const [
              [1, 0],
            ],
            retrievalMetadata: {
              'messageIds': messages.map((m) => m.id).toList(),
              'chunks': [
                {'index': 0, 'text': text, ...malformed},
              ],
            },
          );
          final result = await MessageRecallService(repo, embedder).recall(
            sessionId: 's',
            currentText: 'query',
            config: config,
            sourceMessages: {
              for (final message in messages) message.id: message,
            },
          );
          expect(result.matches, isEmpty);
          expect(result.counters['invalidText'], 1);
        }
      },
    );
    test(
      'a range crossing only the next role prefix is still rejected',
      () async {
        final text = ChatMessageEmbeddingService.formatChunk(messages);
        final end = text.indexOf('assistant: ') + 'assistant: '.length;
        await repo.putEmbeddingVector(
          entryId: 's_0',
          sourceType: 'chat_message',
          sourceId: 's',
          textHash: computeHash(text),
          vectors: const [
            [1, 0],
          ],
          retrievalMetadata: {
            'messageIds': messages.map((m) => m.id).toList(),
            'chunks': [
              {
                'index': 0,
                'text': text.substring(0, end),
                'groupStart': 0,
                'groupEnd': end,
              },
            ],
          },
        );
        final result = await MessageRecallService(repo, embedder).recall(
          sessionId: 's',
          currentText: 'query',
          config: config,
          sourceMessages: {for (final message in messages) message.id: message},
        );
        expect(result.matches, isEmpty);
        expect(result.counters['invalidText'], 1);
      },
    );
  });
}
