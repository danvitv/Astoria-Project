import '../../models/character.dart';
import '../../models/memory_book.dart';
import '../../models/studio_config.dart';
import '../../models/tracker.dart';
import '../macro_engine.dart';
import '../studio_ledger_prompt.dart';
import 'ledger_preset_prompt_resolver.dart';

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
    // The persisted legacy selector is compatibility metadata only. All turns
    // use the same editable preset instructions and current wire contract.
    final systemPrompt = const LedgerPresetPromptResolver().resolveTurn(
      blocks: ledgerBlocks,
      macroCtx: macroCtx,
    );
    return _promptBuilder.build(
      systemPrompt: systemPrompt,
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
}
