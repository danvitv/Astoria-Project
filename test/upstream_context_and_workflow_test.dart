import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/context_budget_guard.dart';
import 'package:glaze_flutter/core/llm/context_calculator.dart';
import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/models/block_context_item.dart';
import 'package:glaze_flutter/features/extensions/models/info_block.dart';
import 'package:glaze_flutter/features/extensions/models/block_run_status.dart';
import 'package:glaze_flutter/features/extensions/services/blocks/context_item_builder.dart';
import 'package:glaze_flutter/features/catalog/services/janitor_lore_budget.dart';
import 'package:glaze_flutter/features/image_gen/services/comfyui_prompt_injector.dart';

void main() {
  test(
    'output cap preserves unlimited semantics; budget requires newest source',
    () {
      expect(clampMaxOutputTokens(6000, 4000), 4000);
      expect(clampMaxOutputTokens(-1, 4000), -1);
      expect(clampMaxOutputTokens(6000, 0), 6000);
      final breakdown = ContextCalculator(contextSize: 1000, maxTokens: 200)
          .calculate(
            staticBlocks: const [],
            historyMessages: const [
              PromptMessage(
                role: 'user',
                content: 'hello',
                sourceMessageId: 'last',
                isHistory: true,
              ),
            ],
          );
      const config = ApiConfig(id: 'api', contextSize: 1000, maxTokens: 200);
      expect(
        promptFitsContext(config, breakdown, requiredMessageId: 'last'),
        isTrue,
      );
      expect(
        promptFitsContext(config, breakdown, requiredMessageId: 'missing'),
        isFalse,
      );
      expect(
        promptFitsContext(config.copyWith(maxTokens: 1000), breakdown),
        isFalse,
      );
    },
  );
  final history = [
    const ChatMessage(id: 'a', role: 'user', content: 'first', timestamp: 1),
    const ChatMessage(
      id: 'b',
      role: 'assistant',
      content: 'second',
      timestamp: 2,
      agentSwipeId: 1,
    ),
    const ChatMessage(id: 'c', role: 'user', content: 'last', timestamp: 3),
    const ChatMessage(
      id: 'future',
      role: 'assistant',
      content: 'DO NOT SEND',
      timestamp: 4,
    ),
  ];
  List<Map<String, dynamic>> build(
    List<BlockContextItem> items, {
    Map<String, List<InfoBlock>> blocks = const {},
  }) => buildContextItemMessages(
    blockConfig: BlockConfig(id: 'block', name: 'block', context: items),
    messages: history,
    anchorMessageId: 'c',
    character: null,
    persona: const Persona(
      id: 'p',
      name: 'Reader',
      prompt: 'persona description',
    ),
    blocksByMessageId: blocks,
  );
  test(
    'ordered context merges roles, expands persona description, respects anchor and negative count',
    () {
      final out = build(const [
        BlockContextItem(
          id: '1',
          role: ContextItemRole.system,
          text: '{{user}}: {{persona}}',
        ),
        BlockContextItem(id: '2', role: ContextItemRole.system, text: 'more'),
        BlockContextItem(
          id: '3',
          type: ContextItemType.lastMessages,
          messagesCount: -2,
        ),
      ]);
      expect(out, [
        {'role': 'system', 'content': 'Reader: persona description\nmore'},
        {'role': 'user', 'content': 'first\n\nsecond'},
      ]);
      expect(
        build(const [
          BlockContextItem(
            id: '1',
            type: ContextItemType.lastMessages,
            messagesCount: 2,
            messagesOffset: 99,
          ),
        ]),
        isEmpty,
      );
    },
  );
  test('previous blocks reject inactive swipes and nonterminal outputs', () {
    InfoBlock block(
      String id,
      String content, {
      int agent = 1,
      BlockRunStatus status = BlockRunStatus.done,
    }) => InfoBlock(
      id: id,
      sessionId: 's',
      messageId: 'b',
      blockId: 'state',
      blockName: 'State',
      blockType: 'generated',
      content: content,
      createdAt: 1,
      agentSwipeId: agent,
      status: status,
    );
    final out = build(
      const [
        BlockContextItem(
          id: '1',
          type: ContextItemType.previousBlock,
          blockName: 'State',
        ),
      ],
      blocks: {
        'b': [
          block('wrong', 'wrong', agent: 0),
          block('running', 'partial', status: BlockRunStatus.running),
          block('ok', 'correct'),
        ],
      },
    );
    expect(out.single['content'], '<State>\ncorrect\n</State>');
  });
  test(
    'ComfyUI traverses conditioning links without touching unrelated encoders',
    () {
      final workflow = <String, dynamic>{
        '1': {
          'inputs': {'text': 'old positive'},
        },
        '2': {
          'inputs': {'text': 'old negative'},
        },
        '3': {
          'inputs': {
            'conditioning': ['1', 0],
          },
        },
        '4': {
          'inputs': {
            'positive': ['3', 0],
            'negative': ['2', 0],
          },
        },
        '5': {
          'inputs': {'text': 'keep unrelated'},
        },
      };
      injectComfyUiPrompts(workflow, prompt: 'new prompt', negativePrompt: '');
      expect(workflow['1']['inputs']['text'], 'new prompt');
      expect(workflow['2']['inputs']['text'], '');
      expect(workflow['5']['inputs']['text'], 'keep unrelated');
    },
  );
  test(
    'Janitor splitting preserves paragraphs and merge removes repeated entries',
    () {
      expect(splitTrigger('alpha beta\n\ngamma delta'), [
        'alpha beta',
        'gamma delta',
      ]);
      expect(splitTrigger('single'), ['single']);
      expect(
        mergeLorebookTexts(['First\n\nSecond', 'first\n\nThird']),
        'First\n\nSecond\n\nThird',
      );
      final budget = JanitorLoreBudget((text) => text.length);
      final probe = {
        'messages': [
          {'role': 'system', 'content': '<Scenario>base</Scenario>'},
        ],
      };
      final payload = {
        'messages': [
          {
            'role': 'system',
            'content': '<Scenario>base${'x' * 110000}</Scenario>',
          },
        ],
      };
      expect(budget.isSaturated(payload, probe: probe), isTrue);
      expect(budget.isSaturated(probe), isFalse);
    },
  );
}
