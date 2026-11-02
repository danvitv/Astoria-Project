import 'package:flutter_test/flutter_test.dart';
import 'package:tiktoken/tiktoken.dart';

import 'package:glaze_flutter/core/llm/chat_message_embedding_service.dart';
import 'package:glaze_flutter/core/llm/generation_context_inputs.dart';
import 'package:glaze_flutter/core/llm/prompt_worker_codec.dart';
import 'package:glaze_flutter/core/llm/prompt_builder.dart';
import 'package:glaze_flutter/core/llm/studio/studio_context.dart';
import 'package:glaze_flutter/core/llm/studio/studio_context_preparer.dart';
import 'package:glaze_flutter/core/llm/studio_brief_deduper.dart';
import 'package:glaze_flutter/core/llm/studio_brief_parser.dart';
import 'package:glaze_flutter/core/llm/studio_message_builder.dart';
import 'package:glaze_flutter/core/llm/studio_prompt_text.dart';
import 'package:glaze_flutter/core/llm/tokenizer.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/studio_regex.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';

void main() {
  const finalAgent = StudioAgent(id: 'final', controllerId: 'final');
  const thinkAgent = StudioAgent(id: 'think', controllerId: 'think');
  const preset = StudioPreset(
    id: 'fixture',
    blocks: [
      StudioPresetBlock(
        id: 'recalled_messages',
        type: StudioBlockType.context,
        contextSlot: StudioContextSlot.recalledMessages,
        injectionPoint: 'final',
      ),
    ],
  );
  // Built-in vocabulary: no download/preload or provider request in this test.
  final referenceEncoder = getEncoding('cl100k_base');
  int referenceTokens(String text) => referenceEncoder.encode(text).length;

  for (final replacement in ['\u2007', '\u2800', '\u3164']) {
    test('Think/Main pack before outbound space replacement $replacement', () {
      final source = ChatMessage(
        id: 'old',
        role: 'assistant',
        content: 'word ' * 3000,
      );
      final sourceHash = computeHash(
        ChatMessageEmbeddingService.formatChunk([source]),
      );
      final inputs = GenerationContextInputs(
        character: const Character(id: 'c', name: 'Character'),
        history: [
          source,
          const ChatMessage(id: 'current', role: 'user', content: 'Continue.'),
        ],
        apiConfig: const ApiConfig(id: 'api'),
        recalledMessageChunks: [
          const RecalledMessageChunk(
            entryId: 'visible',
            text: 'Do not inject visible evidence.',
            messageIds: ['current'],
            score: 1,
          ),
          RecalledMessageChunk(
            entryId: 'old',
            text: source.content,
            rawText: source.content,
            messageIds: ['old'],
            score: .9,
          ),
        ],
      );
      final context = const StudioContextPreparer().prepare(
        inputs: inputs,
        visibleMessageIds: const {'current'},
      );
      final original = context.join(StudioContextSlot.recalledMessages);
      final packing =
          (context.diagnostics.memoryCoverage['rawRecall']
                  as Map<String, dynamic>)['finalPacking']
              as Map<String, dynamic>;
      expect(packing['budgetTokens'], 5000);
      expect(packing['estimatedTokens'], estimateTokens(original));
      expect(packing['estimatedTokens'], lessThanOrEqualTo(5000));
      expect(packing['budgetBasis'], 'source_before_prompt_transforms');
      expect(packing['visibleRejected'], 1);
      expect(packing['selected'], hasLength(1));
      expect(original, isNot(contains('visible evidence')));
      final builder = StudioMessageBuilder(
        const StudioPromptText(),
        StudioBriefDeduper(StudioBriefParser((_) {})),
        readStudioRegexes: () => [
          StudioRegex(
            script: PresetRegex(
              id: 'spaces',
              name: 'Space replacement',
              regex: '/ /g',
              replacement: replacement,
              placement: const [1, 2],
              promptOnly: true,
            ),
            stages: const {'final'},
          ),
        ],
      );
      final expected = original.replaceAll(' ', replacement);
      final main = builder.buildAgentMessages(
        agent: finalAgent,
        context: context,
        config: const StudioConfig(sessionId: 's'),
        studioPreset: preset,
        priorBriefs: const [],
        isFinalResponse: true,
      );
      final think = builder.buildThinkControllerMessages(
        agent: thinkAgent,
        finalAgent: finalAgent,
        context: context,
        config: const StudioConfig(sessionId: 's'),
        studioPreset: preset,
        finalContextOverride: 0,
        reasoningHistoryCount: 0,
        excludeReasoningFromContextBudget: false,
      );
      for (final messages in [main, think]) {
        expect(
          messages.where((message) => message['content'] == expected),
          hasLength(1),
        );
      }
      expect(referenceTokens(original), lessThan(5000));
      expect(referenceTokens(expected), greaterThan(5000));
      // Outbound inflation is allowed; it must not retroactively change source
      // selection, the packing estimate, stored evidence, or its source hash.
      expect(context.join(StudioContextSlot.recalledMessages), original);
      expect(inputs.recalledMessageChunks.last.text, source.content);
      expect(
        computeHash(ChatMessageEmbeddingService.formatChunk([source])),
        sourceHash,
      );
    });
  }

  test('ordinary prompt worker round-trip preserves candidate ranking', () {
    const payload = PromptPayload(
      character: Character(id: 'c', name: 'Character'),
      history: [],
      apiConfig: ApiConfig(id: 'api'),
      recalledMessageChunks: [
        RecalledMessageChunk(
          entryId: 'g',
          chunkIndex: 4,
          score: .8,
          text: '[Source]\nraw evidence',
          rawText: 'raw evidence',
          messageIds: ['old'],
        ),
      ],
    );
    final restored = deserializePayload(serializePayload(payload));
    expect(
      restored.recalledMessageChunks.single.toJson(),
      payload.recalledMessageChunks.single.toJson(),
    );
  });
}
