import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/llm/embedding_service.dart';
import 'package:glaze_flutter/core/llm/memory_injection_service.dart';
import 'package:glaze_flutter/core/llm/message_recall_service.dart';
import 'package:glaze_flutter/core/llm/prompt_builder.dart';
import 'package:glaze_flutter/core/llm/prompt_inputs_collector.dart';
import 'package:glaze_flutter/core/llm/prompt_payload_builder.dart';
import 'package:glaze_flutter/core/llm/studio/studio_context.dart';
import 'package:glaze_flutter/core/llm/studio/studio_context_preparer.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/lorebook_embedding_provider.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';
import 'package:glaze_flutter/features/chat/services/saved_message_writer.dart';

class _ContextEmbeddingService extends EmbeddingService {
  List<String> texts = const [];
  bool timeout = false;

  @override
  Future<List<EmbeddingChunk>> getEmbeddingsWithChunks(
    List<String> texts,
    EmbeddingConfig config, {
    cancelToken,
    captureContext,
  }) async {
    this.texts = texts;
    if (timeout) throw TimeoutException('fixture');
    return const [
      EmbeddingChunk(text: 'query', vector: [1, 0]),
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'real context collection retains recall query and outcomes in chat diagnostics',
    () async {
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final embedder = _ContextEmbeddingService();
      final container = ProviderContainer(
        overrides: [
          appDbProvider.overrideWithValue(db),
          embeddingConfigProvider.overrideWithValue(
            const EmbeddingConfig(endpoint: 'fixture'),
          ),
          messageRecallServiceProvider.overrideWith(
            (ref) =>
                MessageRecallService(ref.read(embeddingRepoProvider), embedder),
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(db.close);
      await container
          .read(characterRepoProvider)
          .put(const Character(id: 'c', name: 'Character'));
      await container
          .read(embeddingRepoProvider)
          .putEmbeddingVector(
            entryId: 'old',
            sourceType: 'chat_message',
            sourceId: 's',
            vectors: [
              [1, 0],
            ],
            textHash: computeHash('user: The report was disputed.'),
            retrievalMetadata: {
              'messageIds': ['old'],
              'chunks': [
                {'index': 0, 'text': 'report was disputed.'},
              ],
            },
          );
      // More visible candidates than the old early top-K limit. All must
      // survive retrieval so the consumer can refill from the older evidence.
      for (var i = 0; i < 10; i++) {
        await container
            .read(embeddingRepoProvider)
            .putEmbeddingVector(
              entryId: 'a-visible$i',
              sourceType: 'chat_message',
              sourceId: 's',
              vectors: const [
                [1, 0],
              ],
              textHash: computeHash('user: visible evidence $i'),
              retrievalMetadata: {
                'messageIds': ['visible$i'],
                'chunks': [
                  {'index': 0, 'text': 'visible evidence $i'},
                ],
              },
            );
      }
      final provider = Provider((ref) {
        Future<void> initialize() async {}
        Future<List<ChatMessage>> inject({
          required String sessionId,
          required List<ChatMessage> messages,
        }) async => [
          ...messages,
          const ChatMessage(
            id: 'protocol',
            role: 'system',
            content: 'Not narrative history',
          ),
        ];
        final collector = PromptInputsCollector(
          ref,
          initializeApiConfigs: initialize,
          readActiveApiConfig: () => null,
          injectHistory: inject,
          readRuntimePromptBlocks: (_) => const [],
        );
        return PromptPayloadBuilder(
          ref,
          inputsCollector: collector,
          initializeApiConfigs: initialize,
          readActiveApiConfig: () => null,
          injectHistory: inject,
          readRuntimePromptBlocks: (_) => const [],
        );
      });
      final builder = container.read(provider);
      final session = ChatSession(
        id: 's',
        characterId: 'c',
        sessionIndex: 0,
        messages: [
          for (var i = 0; i < 10; i++)
            ChatMessage(
              id: 'visible$i',
              role: 'user',
              content: 'visible evidence $i',
            ),
          ChatMessage(
            id: 'old',
            role: 'user',
            content: 'The report was disputed.',
          ),
          ChatMessage(
            id: 'correction',
            role: 'user',
            content: '[OOC: No agreement to sign the report.]',
          ),
          ChatMessage(
            id: 'scene',
            role: 'assistant',
            content:
                '<lumiaooc>Everyone will sign tomorrow.</lumiaooc>She leaves the report beside the coffee.',
          ),
          ChatMessage(id: 'latest', role: 'user', content: 'I take a sip.'),
        ],
      );
      for (final (remote, timeout, expected) in [
        (true, false, 'success'),
        (true, true, 'timeout'),
        (false, false, 'remoteDisabled'),
      ]) {
        embedder.timeout = timeout;
        embedder.texts = const [];
        final inputs = await builder.collectGenerationContext(
          charId: 'c',
          session: session,
          apiConfigOverride: const ApiConfig(id: 'api'),
          skipVectorSearch: true,
          allowRemoteRetrieval: remote,
        );
        final diagnostics =
            inputs.memoryCoverage['rawRecall'] as Map<String, dynamic>;
        expect(diagnostics['reason'], expected);
        expect(diagnostics['query'], contains('No agreement to sign'));
        expect(diagnostics['query'], contains('report beside the coffee'));
        expect(diagnostics['query'], isNot(contains('Everyone will sign')));
        expect(diagnostics['query'], isNot(contains('Not narrative history')));
        if (remote) {
          expect(embedder.texts.single, diagnostics['query']);
        } else {
          expect(embedder.texts, isEmpty);
        }
        final payload = await builder.buildOrdinaryFromGenerationContext(
          inputs,
        );
        expect(buildPrompt(payload).memoryCoverage['rawRecall'], diagnostics);
        final studio = const StudioContextPreparer().prepare(
          inputs: inputs,
          visibleMessageIds: {
            'latest',
            for (var i = 0; i < 10; i++) 'visible$i',
          },
        );
        final finalDiagnostics = Map<String, dynamic>.from(
          studio.diagnostics.memoryCoverage['rawRecall'] as Map,
        );
        final packing =
            finalDiagnostics.remove('finalPacking') as Map<String, dynamic>;
        expect(finalDiagnostics, diagnostics);
        expect(packing['budgetTokens'], 5000);
        expect(packing['estimatedTokens'], lessThanOrEqualTo(5000));
        final recalled = studio.join(StudioContextSlot.recalledMessages);
        if (expected == 'success') {
          expect(inputs.recalledMessageChunks, hasLength(11));
          expect(packing['visibleRejected'], 10);
          expect(packing['selected'], hasLength(1));
          expect(recalled, contains('report was disputed.'));
          expect(recalled, contains('Verified raw source: user message=old'));
          expect(recalled, isNot(contains('visible evidence')));
        } else {
          expect(recalled, anyOf(isNull, isEmpty));
        }
        expect(
          SavedMessageWriter.stripEphemeralMemoryCoverage({
            ...studio.diagnostics.memoryCoverage,
            'diagnostics': {'ephemeral': true},
          })['rawRecall'],
          studio.diagnostics.memoryCoverage['rawRecall'],
        );
      }
    },
  );
}
