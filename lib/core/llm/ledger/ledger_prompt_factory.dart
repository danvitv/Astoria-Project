import '../../models/character.dart';
import '../../models/memory_book.dart';
import '../../models/studio_config.dart';
import '../../models/tracker.dart';
import '../canon_evidence_rules.dart';
import '../canon_evidence_text.dart';
import '../macro_engine.dart';
import '../studio/studio_aux_prompt_assembler.dart';
import '../studio_ledger_prompt.dart';

const _ledgerSystemPromptBlockId = 'ledger_system';

class LedgerPromptFactory {
  const LedgerPromptFactory([this._promptBuilder = const StudioLedgerPrompt()]);

  final StudioLedgerPrompt _promptBuilder;

  String buildLedgerPrompt({
    required String finalAssistantText,
    String currentUserText = '',
    required String recentHistoryText,
    required List<Tracker> currentTrackers,
    required List<MemoryEntry> recentMemoryEntries,
    List<StudioPresetBlock> ledgerBlocks = const [],
    MacroContext? macroCtx,
    Character? character,
    Map<String, String> entityAliases = const {},
    StudioLedgerEngine engine = StudioLedgerEngine.currentReconciled,
    List<String> gameClockHistory = const [],
  }) {
    finalAssistantText = CanonEvidenceText.assistantNarrative(
      finalAssistantText,
    );
    if (engine == StudioLedgerEngine.legacyTurnOnly) {
      return _promptBuilder.buildLegacyTurnOnly(
        finalAssistantText: finalAssistantText,
        currentUserText: currentUserText,
        recentHistoryText: recentHistoryText,
        currentTrackers: currentTrackers,
        recentMemoryEntries: recentMemoryEntries,
        focalUserName: macroCtx?.userName ?? '',
        gameClockHistory: gameClockHistory,
      );
    }
    final hasActiveLedgerBlocks = ledgerBlocks.any(
      (block) =>
          block.id == _ledgerSystemPromptBlockId &&
          block.enabled &&
          block.injectionPoint == 'ledger' &&
          block.content.trim().isNotEmpty,
    );
    if (!hasActiveLedgerBlocks || macroCtx == null) {
      return _promptBuilder.build(
        finalAssistantText: finalAssistantText,
        currentUserText: currentUserText,
        recentHistoryText: recentHistoryText,
        currentTrackers: currentTrackers,
        recentMemoryEntries: recentMemoryEntries,
        character: character,
        entityAliases: entityAliases,
        focalUserName: macroCtx?.userName ?? '',
        gameClockHistory: gameClockHistory,
      );
    }

    final trackerBlock = _promptBuilder.buildCurrentStateBlock(
      currentTrackers,
      '$recentHistoryText\n$finalAssistantText',
    );
    final keyCatalog = _promptBuilder.buildExistingKeyCatalog(currentTrackers);
    final memoryBlock = _buildMemoryBlock(recentMemoryEntries);
    final cardSection = StudioLedgerPrompt.buildCharacterCardSection(character);
    final entitySection = StudioLedgerPrompt.buildEntityAliasSection(
      entityAliases,
    );

    final runtimeSuffix =
        '''
$cardSection$entitySection<current_state>
$trackerBlock
</current_state>

${_clockBlock(gameClockHistory)}<existing_keys>
$keyCatalog
</existing_keys>

<existing_memory>
$memoryBlock
</existing_memory>

<recent_chat>
$recentHistoryText
</recent_chat>

<final_assistant_response>
$finalAssistantText
</final_assistant_response>

${StudioLedgerPrompt.buildCurrentUserTurnBlock(currentUserText)}

Now produce the Studio Ledger output. You MUST return BOTH blocks below.
The <glaze_memory_export> block is MANDATORY, including the current clock
even when no other state changes. Do not omit it under any circumstance.

Required response template (follow this exact structure):
<glaze_memory_export>
${StudioLedgerPrompt.turnExportTemplate}
</glaze_memory_export>
<glaze_knowledge_cleanup>
{"ops":[]}
</glaze_knowledge_cleanup>
<studio_ledger>
Compact continuity snapshot here.
</studio_ledger>

The <glaze_memory_export> block MUST come first, before <studio_ledger>.
It must contain a single JSON object with "ops" and "knowledgeFacts" arrays.
When there are no other state changes, still return the required world:time
operation. knowledgeFacts may be empty. Replace template placeholders with
the actual clock value and evidence; do NOT skip the block.

The <glaze_knowledge_cleanup> block is OPTIONAL. Include it only when you
need to rename a descriptive alias entity to a canonical identity. Use:
{"ops":[{"op":"rename_entity","fromKey":"entity:descriptive_alias","toKey":"entity:canonical","canonicalName":"Name"}]}
Only rename placeholder/descriptive identities listed in
<existing_fact_entities>. Never rename an already-named entity to a
different name. The canonicalName must appear in the final assistant
response or recent chat.

Ops format:
{"ops":[{"op":"set","key":"npc:Name.field","value":"…","evidence":"…","eventState":"completed"},…],"knowledgeFacts":[]}

Allowed namespaces: npc:, relationship:, arc:, world:, scene.
Allowed ops: set, delete. Every set REPLACES the complete current value.
Never append history to a state value. Keep each value under 1200 characters.
Never write npc:*.knowledge or relationship:*.knowledge; durable propositions belong in knowledgeFacts.
Relationship trust/status/attitude and card overrides are current state and must be updated with set whenever correctly attributed evidence establishes a change; source and ownership correctness takes precedence.
Reuse an exact key from <current_state> or <existing_keys> for the same fact; update it with set instead of creating a synonym key.
Allowed eventState: planned, suggested, threatened, attempted, completed, failed, cancelled, unknown (or omit).

${StudioLedgerPrompt.gameClockRules}

${CanonEvidenceRules.sourceAndRelationships}''';

    return const StudioAuxPromptAssembler().assemble(
      blocks: ledgerBlocks,
      injectionPoint: 'ledger',
      macroCtx: macroCtx,
      runtimeSuffix: runtimeSuffix,
      skipBlockIds: {
        for (final block in ledgerBlocks)
          if (block.id != _ledgerSystemPromptBlockId) block.id,
      },
    );
  }

  String _buildMemoryBlock(List<MemoryEntry> entries) {
    if (entries.isEmpty) return '(no existing memory)';
    return entries
        .take(20)
        .map((e) {
          final keys = e.keys.isEmpty ? '' : ' [${e.keys.join(', ')}]';
          final locked = e.locked ? ' [locked]' : '';
          return '- ${e.title.isNotEmpty ? e.title : e.id}$keys$locked';
        })
        .join('\n');
  }

  String _clockBlock(List<String> gameClockHistory) =>
      StudioLedgerPrompt.buildGameClockHistoryBlock(gameClockHistory);
}
