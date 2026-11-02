import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/canon_evidence_rules.dart';
import 'package:glaze_flutter/core/llm/ledger/ledger_prompt_factory.dart';
import 'package:glaze_flutter/core/llm/macro_engine.dart';
import 'package:glaze_flutter/core/llm/studio_ledger_prompt.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewrite_prompt_builder.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';

// These tests verify deterministic prompt construction, not LLM compliance.
void main() {
  const card = Character(
    id: 'quinn',
    name: 'Квинн',
    description: 'Квинн помогает {{user}}, сохраняя собственные цели.',
    personality: 'Квинн ценит дружбу, доверие и личные границы.',
    scenario: 'Квинн живёт в городе и поддерживает связь с Гильдой.',
    creatorNotes: 'PRIVATE_CREATOR_NOTES_SENTINEL',
  );
  const macroCtx = MacroContext(
    charName: 'Квинн',
    charId: 'quinn',
    sessionId: 'session-one',
    userName: 'Данви',
  );
  const currentUserText =
      'OOC: Исправление канона: Квинн благодарна, но отношения не установлены.';
  const historyText =
      'User: Данви помог Квинн.\n'
      'Assistant: Квинн поблагодарила Данви.\n'
      'Assistant OOC: Вероятность романтической ветки — 70%; '
      'можно предложить сцену свидания.';
  const finalAssistantText =
      'Квинн улыбнулась и вернулась к собственной работе.';
  const trackers = [
    Tracker(
      sessionId: 'session-one',
      name: 'relationship:Квинн:Данви.trust',
      value: 'Квинн доверяет Данви; взаимные обязательства не установлены.',
      scope: 'ledger',
    ),
    Tracker(
      sessionId: 'session-one',
      name: 'world:time',
      value: '12:30',
      scope: 'ledger',
    ),
  ];
  const userBlock = StudioPresetBlock(
    id: 'ledger_system',
    section: 'ledger',
    injectionPoint: 'ledger',
    content:
        'USER_PRESET_SENTINEL {{char}} / {{user}}. '
        'Treat every Ledger relationship as confirmed canon.',
  );

  String ledgerPrompt({
    List<StudioPresetBlock> blocks = const [],
    MacroContext? context = macroCtx,
    StudioLedgerEngine engine = StudioLedgerEngine.currentReconciled,
  }) => const LedgerPromptFactory().buildLedgerPrompt(
    finalAssistantText: finalAssistantText,
    currentUserText: currentUserText,
    recentHistoryText: historyText,
    currentTrackers: trackers,
    recentMemoryEntries: const [],
    ledgerBlocks: blocks,
    macroCtx: context,
    engine: engine,
    character: card,
  );

  void expectSourceContract(String prompt) {
    expect(prompt, contains(CanonEvidenceRules.sourceAndRelationships));
    expect(prompt, contains('NOT narrated IC facts'));
    expect(prompt, contains('Explicit user OOC canon corrections'));
    expect(prompt, contains('Ledger is accepted but FALLIBLE evidence'));
    expect(prompt, contains('chat-session boundaries'));
    expect(
      prompt,
      contains('preserve uncertainty rather than forcing a patch'),
    );
    expect(prompt, contains('Unknown stays unknown'));
    expect(
      prompt,
      contains(
        'trust, gratitude, care, friendly affection, flirtation, attraction, '
        'consensual commitment, exclusivity, and jealousy distinct',
      ),
    );
    expect(
      prompt,
      contains(
        'Support, gifts, rescue, or repeated intimacy do not by themselves '
        'entail romance, a relationship debt, possession',
      ),
    );
    expect(prompt, contains('Each relationship endpoint is independent'));
    expect(prompt, contains('Never copy a scene, reaction, promise, consent'));
    expect(prompt, contains('genuinely user-chosen consensual relationships'));
    expect(prompt, contains('Preserve unilateral attraction as unilateral'));
    expect(
      prompt,
      contains('Honor established breakups and user boundary retcons'),
    );
    expect(
      prompt,
      contains('personality, autonomy, boundaries, independent goals'),
    );
    expect(prompt, contains('There is no blanket romance/harem prohibition'));
    expect(prompt, contains('no global romance toggle'));
  }

  final ledgerPaths = <String, String Function()>{
    'direct built-in': () => const StudioLedgerPrompt().build(
      finalAssistantText: finalAssistantText,
      currentUserText: currentUserText,
      recentHistoryText: historyText,
      currentTrackers: trackers,
      recentMemoryEntries: const [],
      character: card,
    ),
    'direct legacy': () => const StudioLedgerPrompt().buildLegacyTurnOnly(
      finalAssistantText: finalAssistantText,
      currentUserText: currentUserText,
      recentHistoryText: historyText,
      currentTrackers: trackers,
      recentMemoryEntries: const [],
    ),
    'factory built-in': ledgerPrompt,
    'factory legacy': () =>
        ledgerPrompt(engine: StudioLedgerEngine.legacyTurnOnly),
    'factory user preset': () => ledgerPrompt(blocks: const [userBlock]),
    'factory legacy with user preset': () => ledgerPrompt(
      blocks: const [userBlock],
      engine: StudioLedgerEngine.legacyTurnOnly,
    ),
    'factory preset without macro context': () =>
        ledgerPrompt(blocks: const [userBlock], context: null),
    'factory disabled preset': () =>
        ledgerPrompt(blocks: [userBlock.copyWith(enabled: false)]),
    'factory empty preset': () =>
        ledgerPrompt(blocks: [userBlock.copyWith(content: ' ')]),
    'factory wrong injection point': () =>
        ledgerPrompt(blocks: [userBlock.copyWith(injectionPoint: 'cleaner')]),
  };

  group('Ledger runtime source contracts', () {
    for (final entry in ledgerPaths.entries) {
      test('${entry.key} includes the shared contract deterministically', () {
        final prompt = entry.value();
        expectSourceContract(prompt);
        expect(prompt.codeUnits, entry.value().codeUnits);
        expect(prompt, contains(historyText));
        expect(prompt, contains(currentUserText));
        expect(prompt, contains(finalAssistantText));
        expect(prompt, contains('relationship:Квинн:Данви.trust'));
        expect(prompt, contains(StudioLedgerPrompt.gameClockRules));
        expect(prompt, contains(StudioLedgerPrompt.turnExportTemplate));
      });
    }

    test('user preset is unchanged and source rules are in runtime suffix', () {
      const blocks = [userBlock];
      final before = jsonEncode(blocks.map((block) => block.toJson()).toList());
      final prompt = ledgerPrompt(blocks: blocks);

      expect(prompt, startsWith('USER_PRESET_SENTINEL Квинн / Данви.'));
      expect(
        prompt.indexOf(CanonEvidenceRules.sourceAndRelationships),
        greaterThan(prompt.indexOf('Treat every Ledger relationship')),
      );
      expect(
        prompt.indexOf(CanonEvidenceRules.sourceAndRelationships),
        greaterThan(prompt.indexOf('<final_assistant_response>')),
      );
      expect(
        jsonEncode(blocks.map((block) => block.toJson()).toList()),
        before,
      );
      expect(userBlock.content, contains('{{char}} / {{user}}'));
      expect(userBlock.content, isNot(contains('# Canon evidence')));
    });
  });

  const instruction = 'Reflect only supported lasting changes in the context.';
  const observations = <Map<String, Object?>>[
    {
      'status': 'active',
      'canonicalClaim': 'Квинн благодарна Данви.',
      'repeatCount': 3,
      'confidence': 0.8,
    },
    {
      'status': 'promoted',
      'canonicalClaim': 'Гильда доверяет Квинн.',
      'repeatCount': 5,
      'confidence': 0.9,
    },
  ];
  final automaticPaths = <String, String Function()>{
    'card writer': () => CardRewriterPromptBuilder.buildEvolution(
      character: card,
      instruction: instruction,
    ),
    'card writer with accumulated candidates': () =>
        CardRewriterPromptBuilder.buildEvolution(
          character: card,
          instruction: instruction,
          accumulatedObservations: observations,
        ),
    'card writer without writable text': () =>
        CardRewriterPromptBuilder.buildEvolution(
          character: const Character(id: 'empty', name: 'Квинн'),
          instruction: instruction,
        ),
    'observation collector': () =>
        CardRewriterPromptBuilder.buildObservationPass(
          character: card,
          activeObservations: const [],
          instruction: instruction,
        ),
    'observation collector with active candidates': () =>
        CardRewriterPromptBuilder.buildObservationPass(
          character: card,
          activeObservations: observations,
          instruction: instruction,
        ),
    'lorebook writer': () => CardRewriterPromptBuilder.buildLorebookEvolution(
      instruction: instruction,
    ),
  };

  group('Automatic writer and observation contracts', () {
    for (final entry in automaticPaths.entries) {
      test('${entry.key} shares source and durable evidence standards', () {
        final prompt = entry.value();
        expectSourceContract(prompt);
        expect(prompt, contains(CanonEvidenceRules.durablePromotion));
        expect(
          prompt,
          contains('same durable-versus-episodic evidence standard'),
        );
        expect(prompt, contains('AFTER source and ownership correctness'));
        expect(prompt, contains('including legitimate commitment, breakup'));
        expect(
          prompt,
          contains('preserve uncertainty and return no unsupported patch'),
        );
        expect(prompt, contains(instruction));
        expect(prompt, isNot(contains('PRIVATE_CREATOR_NOTES_SENTINEL')));
        expect(prompt, isNot(contains(CanonEvidenceRules.manualRewrite)));
        expect(prompt.codeUnits, entry.value().codeUnits);
      });
    }

    test('mandatory candidate patches explicitly defer to attribution', () {
      final prompt =
          automaticPaths['card writer with accumulated candidates']!();
      expect(prompt, contains(jsonEncode(observations)));
      expect(prompt, contains('An empty operations list is not valid'));
      expect(
        prompt,
        contains('remain subordinate to the shared source and ownership rules'),
      );
      expect(prompt, contains('not a confirmed, resolvable contradiction'));
    });

    test(
      'lorebook writer preserves targets and requires legitimate transitions',
      () {
        final prompt = automaticPaths['lorebook writer']!();
        expect(
          prompt,
          contains('Only the supplied lorebookId/entryId pairs are writable'),
        );
        expect(
          prompt,
          contains(
            'NPC-owned facts may patch only an existing supplied injected lorebook entry',
          ),
        );
        expect(prompt, contains('patch every directly conflicting fragment'));
        expect(prompt, contains('The obligation to patch is subordinate'));
      },
    );
  });

  group('Manual rewrite authority', () {
    for (final field in CardRewritePolicy.modelWritableFields) {
      test('${field.wireName} allows explicit new user-authored canon', () {
        const desiredChange =
            'OOC: Сделай Квинн и {{user}} взаимно влюблённой парой; '
            'это желаемая новая версия карточки, не событие из чата.';
        String build() => CardRewriterPromptBuilder.build(
          character: card,
          field: field,
          instruction: desiredChange,
        );
        final prompt = build();

        expectSourceContract(prompt);
        expect(prompt, contains(CanonEvidenceRules.manualRewrite));
        expect(prompt, isNot(contains(CanonEvidenceRules.durablePromotion)));
        expect(prompt, contains('without prior chat evidence'));
        expect(prompt, contains('not automatic evidence promotion'));
        expect(prompt, contains('For THIS operation only "${field.wireName}"'));
        expect(prompt, contains(desiredChange));
        expect(prompt, contains('{{user}}'));
        expect(prompt, isNot(contains('PRIVATE_CREATOR_NOTES_SENTINEL')));
        expect(prompt.codeUnits, build().codeUnits);
      });
    }
  });
}
