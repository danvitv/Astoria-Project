import '../models/character.dart';
import '../models/memory_book.dart';
import '../models/tracker.dart';
import 'canon_evidence_text.dart';
import 'ledger/ledger_wire_contract.dart';

/// Assembles supplied preset policy, runtime context, and the parser contract.
/// Semantic instructions belong only to the editable Studio preset.
class StudioLedgerPrompt {
  const StudioLedgerPrompt();

  String build({
    required String systemPrompt,
    required String finalAssistantText,
    String currentUserText = '',
    required String recentHistoryText,
    required List<Tracker> currentTrackers,
    required List<MemoryEntry> recentMemoryEntries,
    Character? character,
    Map<String, String> entityAliases = const {},
    String focalUserName = '',
    List<String> gameClockHistory = const [],
  }) {
    if (systemPrompt.trim().isEmpty) {
      throw StateError('Studio Ledger requires nonblank preset instructions.');
    }
    finalAssistantText = CanonEvidenceText.assistantNarrative(
      finalAssistantText,
    );
    final trackerBlock = buildCurrentStateBlock(
      currentTrackers,
      '$recentHistoryText\n$finalAssistantText',
    );
    final keyCatalog = buildExistingKeyCatalog(currentTrackers);
    final memoryBlock = _buildMemoryBlock(recentMemoryEntries);
    final cardBlock = buildCharacterCardSection(character);
    final entityBlock = buildEntityAliasSection(entityAliases);
    final clockBlock = buildGameClockHistoryBlock(gameClockHistory);

    return '''$systemPrompt

$cardBlock
<current_state>
$trackerBlock
</current_state>

$clockBlock<existing_keys>
$keyCatalog
</existing_keys>

$entityBlock<existing_memory>
$memoryBlock
</existing_memory>

<recent_chat>
$recentHistoryText
</recent_chat>

<final_assistant_response>
$finalAssistantText
</final_assistant_response>

${buildCurrentUserTurnBlock(currentUserText)}

${LedgerWireContract.turn(focalUserName: focalUserName)}''';
  }

  /// Compatibility entry point; there is no alternate hidden policy profile.
  String buildLegacyTurnOnly({
    required String systemPrompt,
    required String finalAssistantText,
    String currentUserText = '',
    required String recentHistoryText,
    required List<Tracker> currentTrackers,
    required List<MemoryEntry> recentMemoryEntries,
    Character? character,
    Map<String, String> entityAliases = const {},
    String focalUserName = '',
    List<String> gameClockHistory = const [],
  }) => build(
    systemPrompt: systemPrompt,
    finalAssistantText: finalAssistantText,
    currentUserText: currentUserText,
    recentHistoryText: recentHistoryText,
    currentTrackers: currentTrackers,
    recentMemoryEntries: recentMemoryEntries,
    character: character,
    entityAliases: entityAliases,
    focalUserName: focalUserName,
    gameClockHistory: gameClockHistory,
  );

  /// Full values for state relevant to this turn. This filters rows, never
  /// truncates them; persisted tracker data remains lossless.
  String buildCurrentStateBlock(List<Tracker> trackers, String turnContext) {
    if (trackers.isEmpty) return '(no prior state)';
    // Show only ledger-scope trackers (entity/relationship/arc/world/scene).
    final ledgerTrackers = trackers
        .where((t) => t.scope == 'ledger' || t.scope == 'chat')
        .where(
          (t) =>
              (t.name.startsWith('npc:') && !t.name.endsWith('.knowledge')) ||
              (t.name.startsWith('relationship:') &&
                  !t.name.endsWith('.knowledge')) ||
              t.name.startsWith('arc:') ||
              t.name.startsWith('world:') ||
              t.name.startsWith('scene.'),
        )
        .where((tracker) => _isRelevantTracker(tracker, turnContext))
        .toList();
    if (ledgerTrackers.isEmpty) return '(no prior state)';
    return ledgerTrackers.map((t) => '${t.name}: ${t.value}').join('\n');
  }

  static String buildCurrentUserTurnBlock(String text) =>
      '<current_user_turn>\n${text.trim().isEmpty ? '(no new user turn)' : text}\n'
      '</current_user_turn>';

  bool _isRelevantTracker(Tracker tracker, String turnContext) {
    if (tracker.name.startsWith('world:') ||
        tracker.name.startsWith('scene.')) {
      return true;
    }
    final haystack = _searchTerms(turnContext);
    final key = tracker.name.split('.').first;
    final identifiers = key
        .split(':')
        .skip(1)
        .expand((part) => _searchTerms(part))
        .where((term) => term.length > 2);
    return identifiers.any(haystack.contains);
  }

  Set<String> _searchTerms(String text) => text
      .toLowerCase()
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .where((term) => term.isNotEmpty)
      .toSet();

  /// Names only, so aliases can resolve to an existing canonical key without
  /// injecting every stored value into the Ledger prompt.
  String buildExistingKeyCatalog(List<Tracker> trackers) {
    final keys =
        trackers
            .where(
              (tracker) => tracker.scope == 'ledger' || tracker.scope == 'chat',
            )
            .map((tracker) => tracker.name)
            .where(_isLedgerKey)
            .toSet()
            .toList()
          ..sort();
    return keys.isEmpty ? '(no prior keys)' : keys.join('\n');
  }

  bool _isLedgerKey(String name) =>
      name.startsWith('npc:') ||
      name.startsWith('relationship:') ||
      name.startsWith('arc:') ||
      name.startsWith('world:') ||
      name.startsWith('scene.');

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

  /// Compact `<character_card>` reference; each body field is capped at 2000.
  static String buildCharacterCardSection(Character? character) {
    if (character == null) return '';
    final parts = <String>[];
    final name = (character.displayName?.isNotEmpty ?? false)
        ? character.displayName!
        : character.name;
    parts.add('Name: $name');
    if (character.description != null && character.description!.isNotEmpty) {
      final desc = character.description!;
      parts.add(
        'Description: ${desc.length > 2000 ? '${desc.substring(0, 2000)}…' : desc}',
      );
    }
    if (character.personality != null && character.personality!.isNotEmpty) {
      final pers = character.personality!;
      parts.add(
        'Personality: ${pers.length > 2000 ? '${pers.substring(0, 2000)}…' : pers}',
      );
    }
    return '<character_card>\n${parts.join('\n')}\n</character_card>\n\n';
  }

  /// Entity keys and display names only, without unbounded fact bodies.
  static String buildEntityAliasSection(Map<String, String> entityAliases) {
    if (entityAliases.isEmpty) return '';
    final lines = entityAliases.entries
        .map((e) => '- ${e.key}: ${e.value}')
        .join('\n');
    return '<existing_fact_entities>\n$lines\n</existing_fact_entities>\n\n';
  }

  /// Recent game-clock trajectory, oldest to newest.
  static String buildGameClockHistoryBlock(List<String> entries) {
    if (entries.isEmpty) return '';
    return '<clock_history>\n${entries.join('\n')}\n</clock_history>\n\n';
  }
}
