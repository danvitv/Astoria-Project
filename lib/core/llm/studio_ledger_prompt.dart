import '../models/character.dart';
import '../models/memory_book.dart';
import '../models/tracker.dart';
import 'canon_evidence_rules.dart';
import 'canon_evidence_text.dart';

// ─────────────────────────────────────────────────────────────────────────────
// StudioLedgerPrompt
//
// Builds the prompt for the Studio Ledger LLM call.
// Pure, stateless — all inputs are passed explicitly.
//
// Based on the Studio Ledger prompt contract: the ledger is an internal
// continuity/state extractor that maintains session-canon facts for future
// generations. It does NOT write story prose. It preserves prior state unless
// contradicted, distinguishes event states
// (planned/suggested/threatened/attempted/completed/failed/cancelled/unknown),
// and never converts threats/plans/questions/offers/pending choices into
// completed facts. Returns <studio_ledger> + <glaze_memory_export> JSON,
// preferring patch ops in `ops` for persistence.
// ─────────────────────────────────────────────────────────────────────────────

/// Builds the non-streaming prompt sent to the Studio Ledger model.
class StudioLedgerPrompt {
  const StudioLedgerPrompt();

  /// Build the full ledger prompt from the turn's context.
  ///
  /// [finalAssistantText] — cleaned final assistant response (post-cleaner
  /// output when enabled, raw response otherwise).
  ///
  /// [currentUserText] — user input belonging to this assistant turn, separated
  /// from older history so the model does not re-apply earlier timeskips.
  ///
  /// [recentHistoryText] — last ~10 user+assistant messages in plain text,
  /// for scene/entity context.
  ///
  /// [currentTrackers] — current tracker_rows for this session (entity,
  /// relationship, arc, world, scene state written by prior ledger runs).
  ///
  /// [recentMemoryEntries] — up to 20 active MemoryBook entries (title + keys
  /// only, content omitted to keep prompt lean).
  ///
  /// [character] — the character card for this session. Name, description, and
  /// personality are injected as a reference section so the ledger can resolve
  /// aliases and placeholders to the canonical identity.
  ///
  /// [entityAliases] — compact `{subjectKey: subjectName}` map of entities
  /// that already appear in active knowledge facts. Lets the ledger issue
  /// `rename_entity` ops to merge descriptive aliases into canonical
  /// identities immediately, without waiting for reconciliation.
  String build({
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

    return '''$_systemPrompt

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

Now produce the Studio Ledger output. You MUST return BOTH blocks below.
The <glaze_memory_export> block is MANDATORY, including the current clock
even when no other state changes. Do not omit it under any circumstance.

Required response template (follow this exact structure):
<glaze_memory_export>
$turnExportTemplate
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
{"ops":[{"op":"set","key":"npc:Name.field","value":"…","evidence":"…","eventState":"completed"},…],"knowledgeFacts":[{"knowerKey":"entity:lucy","knowerName":"Lucy","subjectKey":"entity:danvi","subjectName":"Danvi","factClass":"relationship","scopeKey":"relationship:danvi","predicate":"trusts","object":"Trusts Danvi.","epistemicState":"confirmed","confidence":0.9,"importance":0.8,"entities":["Lucy"],"topics":["trust"],"supersedesId":null}]}

Allowed namespaces: npc:, relationship:, arc:, world:, scene.
Allowed ops: set, delete. Every set replaces the complete current value.
Do not write npc:*.knowledge — use knowledgeFacts instead.
Allowed eventState: planned, suggested, threatened, attempted, completed, failed, cancelled, unknown (or omit).
Allowed factClass: knowledge, relationship, behavior_change, commitment, goal, persistent_condition, identity_development.
Allowed epistemicState: observed, heard_claim, inferred, confirmed, disbelieved, forgotten, retracted.
knowledgeFacts rules:
- One proposition per fact. Never summarize prior facts.
- supersedesId only when correcting a known injected fact ID.
- Distinguish direct observation, heard claim, inference, confirmation, disbelief, and correction.
- Never output future events as facts.
 - scopeKey: narrowest defensible scope (e.g. relationship:danvi), never global for convenience.
 - Do not create npc:$focalUserName.* or arc:$focalUserName.* state. The user's goals, emotions, intentions, and arc belong to their own messages.
 - For $focalUserName, write knowledgeFacts only for concrete information explicitly seen, heard, or confirmed; this tracks information access and never dictates a reaction or belief.''';
  }

  /// Parser-compatible per-turn compatibility profile for presets that do not
  /// use automatic reconciliation. It preserves the former workflow shape,
  /// with minimal adaptations for the current parser contract; it is not
  /// claimed to be a byte-for-byte historical prompt copy.
  String buildLegacyTurnOnly({
    required String finalAssistantText,
    String currentUserText = '',
    required String recentHistoryText,
    required List<Tracker> currentTrackers,
    required List<MemoryEntry> recentMemoryEntries,
    String focalUserName = '',
    List<String> gameClockHistory = const [],
  }) {
    finalAssistantText = CanonEvidenceText.assistantNarrative(
      finalAssistantText,
    );
    final trackerBlock = buildCurrentStateBlock(
      currentTrackers,
      '$recentHistoryText\n$finalAssistantText',
    );
    final keyCatalog = buildExistingKeyCatalog(currentTrackers);
    final memoryBlock = _buildMemoryBlock(recentMemoryEntries);
    final clockBlock = buildGameClockHistoryBlock(gameClockHistory);
    return '''$_legacyTurnOnlySystemPrompt

<current_state>
$trackerBlock
</current_state>

$clockBlock<existing_keys>
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

${buildCurrentUserTurnBlock(currentUserText)}
$gameClockRules
$sceneConditionLifecycleRules

Now produce the Studio Ledger output. You MUST return BOTH blocks below.
The <glaze_memory_export> block is MANDATORY, including the current clock
even when no other state changes. Do not omit it under any circumstance.

Required response template (follow this exact structure):
<glaze_memory_export>
$turnExportTemplate
</glaze_memory_export>
<studio_ledger>
Compact continuity snapshot here.
</studio_ledger>

The <glaze_memory_export> block MUST come first, before <studio_ledger>.
It must contain a single JSON object with "ops" and "knowledgeFacts" arrays.
When there are no other state changes, still return the required world:time
operation. knowledgeFacts may be empty. Replace template placeholders with
the actual clock value and evidence; do NOT skip the block.

Ops format:
{"ops":[{"op":"set","key":"npc:Name.field","value":"…","evidence":"…","eventState":"completed"}],"knowledgeFacts":[]}

Allowed namespaces: npc:, relationship:, arc:, world:, scene.
Allowed ops: set, delete. Every set replaces the complete current value.
Do not write npc:*.knowledge — use knowledgeFacts instead.
Allowed eventState: planned, suggested, threatened, attempted, completed, failed, cancelled, unknown (or omit).
Allowed factClass: knowledge, relationship, behavior_change, commitment, goal, persistent_condition, identity_development.
Allowed epistemicState: observed, heard_claim, inferred, confirmed, disbelieved, forgotten, retracted.
knowledgeFacts rules:
- One proposition per fact. Never summarize prior facts.
- supersedesId only when correcting a known injected fact ID.
- Never output future events as facts.
 - scopeKey must be the narrowest defensible scope.
 - Do not create npc:$focalUserName.* or arc:$focalUserName.* state. For $focalUserName, write knowledgeFacts only for concrete information explicitly seen, heard, or confirmed.''';
  }

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

  /// Minimum per-turn export shape; the model supplies actual values/evidence.
  static const String turnExportTemplate =
      '{"ops":[{"op":"set","key":"world:time","value":"HH:MM",'
      '"evidence":"Reason for elapsed time or for remaining in the same moment",'
      '"eventState":"completed"}],"knowledgeFacts":[]}';

  /// Runtime contract shared by built-in, user-preset, and compatibility paths.
  /// Elapsed time is a narrative estimate; code validates the clock tuple only.
  static const String gameClockRules =
      '''Game clock (world:time, world:date, world:day):
- Maintain a complete tuple: 24-hour HH:MM, real calendar date DD.MM.YYYY,
  and zero-based RP day. Never invent a missing month or year. If canon gives
  only a month and year, day-of-month = 1 + world:day (Day 0 = the 1st).
- Every per-turn response MUST include exactly one set operation for world:time
  in the <glaze_memory_export> ops array, even when time has not advanced.
  Return the resulting current time as HH:MM, not merely a time mention in
  <studio_ledger>. Also show the resulting clock in the visible ledger.
- If this is still the same moment, explicitly repeat the current world:time
  from <current_state> and explain in evidence why no time elapsed. Unchanged
  time is an explicit clock decision, never a reason to omit the operation.
  If time advanced, evidence must describe the elapsed events or user timeskip.
  Use eventState completed for the resulting current clock, not a future plan.
- Include world:date and world:day set operations whenever they change. If
  they are unchanged, preserve their current values; do not reset the calendar
  or RP day merely to return world:time.
- If a complete canonical clock is unavailable, explicitly report that in
  <studio_ledger>; do not fabricate missing components or emit placeholder
  clock values. This is the only exception to the required clock operation.
- Independently estimate elapsed time from the scene: conversation, travel,
  waiting, work, rest, and scene transitions. There is no five-minute cap and
  no requirement for a numeric time or duration to appear in the prose.
- Explicit user timeskips take priority, including "спустя полчаса", "на
  следующее утро", and "следующая сцена". Honor them even if the assistant
  does not repeat the cue. Use a stated duration; otherwise choose a plausible
  interval from context. Do not freeze the clock during a genuine transition.
- A directly continuing moment may advance slightly or stay at the same time.
  Do not add a fixed number of minutes mechanically for every response.
- Advance only FORWARD. Memories, flashbacks, plans, promises, hypothetical
  events, and mentions of future appointments do not themselves advance time.
- Apply each timeskip once. <current_user_turn> and <final_assistant_response>
  describe this turn; older <recent_chat> and <clock_history> help distinguish
  already-applied skips. The newest clock-history line is the prior trajectory,
  while <current_state> includes any newer manual clock corrections.
- Bells, lighting, watches, and other atmospheric cues require setting context;
  ordinal bells do not automatically map to real-world clock hours.
- Crossing midnight must advance world:date and world:day together by the same
  number of days. Keep all clock components consistent.''';

  /// Code-owned lifecycle contract shared by every live extraction path,
  /// including DB-backed user presets. Reconciliation is deliberately not a
  /// semantic garbage collector: closure must be evidenced by the accepted
  /// turn and expressed as an explicit durable operation here.
  static const String sceneConditionLifecycleRules =
      '''Scene-scoped condition lifecycle:
- Distinguish durable boundaries from conditions tied to one scene, deadline,
  permission, restriction, or obligation. Prefer a separate
  npc:Name.persistent_condition tracker for active scene-scoped conditions;
  keep separate conditions as separate clauses in its complete value. Include
  the established scene clock/date or explicit deadline when available.
- If the accepted user/assistant turn explicitly proves that an existing
  scene-scoped condition was fulfilled, withdrawn/cancelled, or expired at its
  explicitly established deadline, this response MUST emit an explicit tracker
  operation. Never leave it unchanged for reconciliation to clean up later.
- For a dedicated persistent_condition, emit delete. For a legacy clause inside
  boundaries, emit set with the complete remaining boundary value after removing
  only the closed clause; emit delete only when nothing valid remains.
- Do NOT close or delete a condition merely because the scene changed, time
  passed without a proven deadline, it was not mentioned, or a later episode is
  similar. A similar condition in a later scene is new state unless the later
  evidence explicitly extends or re-establishes the earlier condition.
- set replaces the full tracker value. There is no durable mark operation, and
  eventState alone does not close or mutate an existing tracker.''';

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

  /// Compact `<character_card>` section for the ledger prompt.
  ///
  /// Includes name, description, and personality (each capped at 2000 chars)
  /// so the ledger agent can resolve descriptive aliases ("беловолосая
  /// женщина") and transliteration variants ("Lucy" / "Люси") to the canonical
  /// character identity from the card.
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

  /// Compact `<existing_fact_entities>` section — entity keys and display
  /// names only, no fact content. Lets the ledger issue `rename_entity` ops
  /// to merge aliases without injecting full fact bodies (which would grow
  /// the prompt unboundedly with fact count).
  static String buildEntityAliasSection(Map<String, String> entityAliases) {
    if (entityAliases.isEmpty) return '';
    final lines = entityAliases.entries
        .map((e) => '- ${e.key}: ${e.value}')
        .join('\n');
    return '<existing_fact_entities>\n$lines\n</existing_fact_entities>\n\n';
  }

  /// Compact `<clock_history>` section listing the recent game-clock
  /// trajectory (oldest→newest). Lets the ledger see that a timeskip already
  /// happened and where the clock currently stands, so it does not re-apply a
  /// previous skip or over-advance time. Empty entries yield an empty block.
  static String buildGameClockHistoryBlock(List<String> entries) {
    if (entries.isEmpty) return '';
    return '<clock_history>\n${entries.join('\n')}\n</clock_history>\n\n';
  }

  static const String _systemPrompt =
      '''You are Studio Ledger, an internal continuity and state extractor.
You do not write story prose.
You maintain session-canon facts for future generations.

Use the final assistant response, latest user message, previous ledger, recent chat, current state, and existing memory.

Rules:
- Preserve prior state unless valid attributed evidence or an explicit user correction contradicts it; source and ownership correctness takes precedence.
- Treat accepted assistant prose as evidence of what was narrated, not proof of
  hidden motives, unseen research, ownership, causation, or off-screen events.
  Persist only explicit observations, actions, dialogue, user corrections, and
  already-established canon. If a claim is merely plausible, omit it from
  current state; use an epistemically qualified knowledgeFact only when useful.
- Never turn guesses, rhetorical flourishes, metaphors, probabilistic language,
  or a character's interpretation into objective current state.
- Temporary posture/outfit/props stay in the visible ledger unless they became important.
- Do not create quests unless an explicit task/goal exists.
- Do not create persona stats unless already tracked.
- Do not infer romance/trust jumps without correctly attributed evidence; distinguish these independent relationship dimensions.
- Correctly attributed established session state overrides character-card baseline; fallible Ledger claims are not unconditional authority.
- Source priority is: explicit user correction and established session canon;
  then episodic MemoryBook/raw recall; then character card and supplied lore;
  then model knowledge of the source material.
- Source-material knowledge is allowed to fill genuine gaps. Absence from the
  character card does NOT mean a known canon person or fact is unknown.
- Model knowledge must not contradict explicit session canon, episodic evidence,
  or explicit card/lore claims. An omitted card fact is a gap, not a conflict.
  When unsure, omit the claim instead of recording it as session fact.
- A model-known source fact becomes session canon only after it is stated in an
  accepted user/assistant turn. The Ledger may then persist it with evidence.
- A retcon invalidates only the fact or condition it identifies. It does not
  prevent a later, explicitly established event from creating a new state of
  the same category. Keep the old fact deleted and store the newer state with
  its later evidence anchor.
- If an arc from the card is resolved in session canon, mark it completed with do_not_reopen=true.
- Never write future events as facts.
- Pending user choices are hooks, not completed events.
- Do not convert threats, plans, questions, offers, or pending choices into completed facts.
- Distinguish planned, suggested, threatened, attempted, completed, failed, cancelled, and unknown event states.
- Do not mark an entity present only because it is mentioned.
- Do not mark an entity absent unless it explicitly leaves, dies, is left behind, or the scene changes.
- Locations are current state, not history. When the scene or time advances and
  an NPC's current location is no longer established, delete npc:Name.location
  instead of retaining a stale location or inventing where the NPC went.
- Keep current_goal limited to the entity's active immediate objective. Remove
  completed, abandoned, and merely remembered tasks; never use it as a backlog.
- Return <studio_ledger> plus <glaze_memory_export> JSON.
- Prefer patch ops in the ops list for persistence. Do not rewrite the whole world state.
- Reuse an exact key from <current_state> or <existing_keys> when it represents the same fact. Update it with set; do not create a synonym key.
- Identity resolution overrides exact-key reuse. When chat establishes that a
  placeholder or alias (for example "Unidentified Netrunner") is a named
  entity, migrate every relevant field to one canonical npc:Name key and emit
  delete ops for every obsolete placeholder/alias key. Preserve only supported
  values during the merge; do not duplicate the entity under two names.
- Explicit user corrections have highest priority. Apply the correction to all
  affected current-state keys and delete incompatible or obsolete keys in the
  same patch.
- Keep entity/relationship/arc/world state compact. Update current truth; do not create a history log.
- Never output ledger text as story prose or a chat message.
- Entity state keys: npc:Name.relationship_to_user, npc:Name.attitude_to_user, npc:Name.trust_to_user, npc:Name.boundaries, npc:Name.card_overrides, npc:Name.location, npc:Name.current_emotional_residue, npc:Name.current_goal, npc:Name.persistent_condition
- Relationship keys: relationship:A:B.trust, relationship:A:B.status, relationship:A:B.relationship, relationship:A:B.attitude, relationship:A:B.boundaries, relationship:A:B.card_override
- Never write npc:*.knowledge or relationship:*.knowledge. Use knowledgeFacts.
- Arc keys: arc:id.status, arc:id.summary, arc:id.do_not_reopen, arc:id.card_override
- World/scene keys: world:location, world:time, world:date, world:day, world:active_threats, scene.present_entities, scene.absent_backstory_entities
$gameClockRules
$sceneConditionLifecycleRules

${CanonEvidenceRules.sourceAndRelationships}''';

  static const String _legacyTurnOnlySystemPrompt =
      '''You are Studio Ledger, an internal continuity and state extractor.
You do not write story prose. You maintain session-canon facts for future generations.

Rules:
- Preserve prior state unless valid attributed evidence or an explicit user correction contradicts it; source and ownership correctness takes precedence.
- Temporary posture/outfit/props stay in the visible ledger unless important.
- Do not create quests or persona stats unless explicitly established.
- Do not infer romance or trust jumps without correctly attributed evidence.
- Correctly attributed established session state overrides character-card baseline; fallible Ledger claims are not unconditional authority.
- Never write future events as facts or pending choices as completed events.
- Distinguish planned, suggested, threatened, attempted, completed, failed, cancelled, and unknown event states.
- Do not mark an entity present merely because it is mentioned.
- Prefer patch ops; update current truth rather than creating a history log.
- Reuse exact keys from current_state or existing_keys for the same fact.
- Never output ledger text as story prose or a chat message.
- Entity keys include relationship_to_user, attitude_to_user, trust_to_user, boundaries, location, current_emotional_residue, current_goal, and persistent_condition.
- Relationship keys include trust, status, relationship, attitude, boundaries, and card_override.
- Never write npc:*.knowledge or relationship:*.knowledge. Use knowledgeFacts.
- Arc keys: arc:id.status, arc:id.summary, arc:id.do_not_reopen, arc:id.card_override.
- World/scene keys: world:location, world:time, world:date, world:day, world:active_threats, scene.present_entities, scene.absent_backstory_entities.

${CanonEvidenceRules.sourceAndRelationships}''';
}
