import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/core/llm/macro_engine.dart';
import 'package:glaze_flutter/core/llm/studio/studio_context.dart';
import 'package:glaze_flutter/core/llm/studio_brief_deduper.dart';
import 'package:glaze_flutter/core/llm/studio_brief_parser.dart';
import 'package:glaze_flutter/core/llm/studio_message_builder.dart';
import 'package:glaze_flutter/core/llm/studio_prompt_text.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

void main() {
  const arc = '<arc_state>completed; do_not_reopen=true</arc_state>';
  const clock = '<current_game_clock>15:00</current_game_clock>';
  const guidance = 'Keep independent character knowledge.';
  const context = StudioContext(
    slots: {
      StudioContextSlot.runtimeDynamic: [
        PromptMessage(role: 'system', content: clock),
        PromptMessage(role: 'system', content: guidance),
        PromptMessage(role: 'system', content: arc),
      ],
    },
    history: [PromptMessage(role: 'user', content: 'Hello')],
    sessionVars: {},
    globalVars: {},
    macroContext: MacroContext(
      charName: 'Hotel',
      charId: 'c',
      sessionId: 's',
      arcContent: arc,
    ),
    diagnostics: StudioContextDiagnostics(),
  );
  final builder = StudioMessageBuilder(
    const StudioPromptText(),
    StudioBriefDeduper(StudioBriefParser((_) {})),
  );
  for (final think in [false, true]) {
    for (final enabled in [false, true]) {
      test(
        '${think ? 'Think' : 'Main'} arc macro enabled=$enabled preserves one closure and clock',
        () {
          final preset = StudioPreset(
            id: 'p',
            blocks: [
              StudioPresetBlock(
                id: 'arcs',
                content: '{{arc}}',
                enabled: enabled,
                mode: 'direct',
                injectionPoint: 'final',
              ),
            ],
          );
          final messages = think
              ? builder.buildThinkControllerMessages(
                  agent: const StudioAgent(
                    id: 'think',
                    controllerId: 'think',
                    specId: 'think',
                  ),
                  finalAgent: const StudioAgent(
                    id: 'final',
                    controllerId: 'final',
                  ),
                  context: context,
                  config: const StudioConfig(sessionId: 's'),
                  studioPreset: preset,
                  finalContextOverride: 0,
                  reasoningHistoryCount: 0,
                  excludeReasoningFromContextBudget: false,
                )
              : builder.buildAgentMessages(
                  agent: const StudioAgent(id: 'final', controllerId: 'final'),
                  context: context,
                  config: const StudioConfig(sessionId: 's'),
                  studioPreset: preset,
                  priorBriefs: const [],
                  isFinalResponse: true,
                );
          final joined = messages.map((m) => m['content']).join('\n');
          expect(arc.allMatches(joined), hasLength(1));
          expect(joined, contains(clock));
          expect(joined, contains(guidance));
        },
      );
    }
  }

  test(
    'an arc macro in a non-emitted append block does not remove fallback',
    () {
      final messages = builder.buildAgentMessages(
        agent: const StudioAgent(id: 'final', controllerId: 'final'),
        context: context,
        config: const StudioConfig(sessionId: 's'),
        studioPreset: const StudioPreset(
          id: 'p',
          blocks: [
            StudioPresetBlock(
              id: 'append',
              content: '{{arc}}',
              mode: 'direct',
              injectionPoint: 'final',
              appendToLastMessage: true,
            ),
          ],
        ),
        priorBriefs: const [],
        isFinalResponse: true,
      );
      expect(messages.map((m) => m['content']).join('\n'), contains(arc));
    },
  );

  test(
    'historical assistant arc text is not a successfully appended macro',
    () {
      final messages = builder.buildAgentMessages(
        agent: const StudioAgent(id: 'final', controllerId: 'final'),
        context: const StudioContext(
          slots: {
            StudioContextSlot.runtimeDynamic: [
              PromptMessage(role: 'system', content: arc),
            ],
          },
          history: [PromptMessage(role: 'assistant', content: arc)],
          sessionVars: {},
          globalVars: {},
          macroContext: MacroContext(
            charName: 'Hotel',
            charId: 'c',
            sessionId: 's',
            arcContent: arc,
          ),
          diagnostics: StudioContextDiagnostics(),
        ),
        config: const StudioConfig(sessionId: 's'),
        studioPreset: const StudioPreset(
          id: 'p',
          blocks: [
            StudioPresetBlock(
              id: 'append',
              content: '{{arc}}',
              mode: 'direct',
              injectionPoint: 'final',
              appendToLastMessage: true,
            ),
            StudioPresetBlock(
              id: 'history',
              type: StudioBlockType.history,
              injectionPoint: 'final',
            ),
          ],
        ),
        priorBriefs: const [],
        isFinalResponse: true,
      );
      expect(
        arc.allMatches(messages.map((m) => m['content']).join('\n')),
        hasLength(2),
      );
    },
  );
}
