import '../../../../../core/llm/studio/studio_context.dart';
import '../../../../../core/llm/studio_controller_ontology.dart';
import '../../../../../core/models/preset.dart';
import '../../../../../core/models/studio_preset_validation.dart';
import '../../../../studio/studio_injection_points.dart';

final class SupportPresetKnowledgeRecord {
  const SupportPresetKnowledgeRecord({
    required this.id,
    required this.syntax,
    required this.scope,
    required this.behavior,
    required this.emptyWhen,
  });

  final String id;
  final String syntax;
  final String scope;
  final String behavior;
  final String emptyWhen;

  Map<String, Object?> toJson() => {
    'id': id,
    'syntax': syntax,
    'scope': scope,
    'behavior': behavior,
    'emptyWhen': emptyWhen,
  };
}

/// Fixed native capability projection. It contains no saved preset text and
/// performs no expansion. Dynamic records derive from the exact runtime enums,
/// validator sets and Studio controller ontology used by prompt assembly.
abstract final class SupportPresetKnowledge {
  static const topics = <String>{
    'macros',
    'ordinaryPlacement',
    'studioRouting',
    'studioContext',
  };

  static List<SupportPresetKnowledgeRecord> records(String topic) =>
      List.unmodifiable(switch (topic) {
        'macros' => _macros,
        'ordinaryPlacement' => _ordinaryPlacement,
        'studioRouting' => _studioRouting,
        'studioContext' => _studioContext,
        _ => const <SupportPresetKnowledgeRecord>[],
      });

  static final _macros = <SupportPresetKnowledgeRecord>[
    SupportPresetKnowledgeRecord(
      id: 'comments',
      syntax: '{{// note}} or {{//}}...{{///}}',
      scope: 'ordinary+Studio instruction text',
      behavior: 'Removed before other macro expansion.',
      emptyWhen: 'Always removed.',
    ),
    SupportPresetKnowledgeRecord(
      id: 'characterName',
      syntax: '{{char}}; alias {char}',
      scope: 'ordinary+Studio',
      behavior:
          'Character macro name when set, otherwise saved character name; case-insensitive.',
      emptyWhen: 'Empty only when the supplied character context is empty.',
    ),
    SupportPresetKnowledgeRecord(
      id: 'userName',
      syntax: '{{user}}; alias {user}',
      scope: 'ordinary+Studio',
      behavior: 'Current persona name, falling back to User; case-insensitive.',
      emptyWhen: 'Normally never empty in a live chat context.',
    ),
    SupportPresetKnowledgeRecord(
      id: 'characterFields',
      syntax:
          '{{description}}, {{personality}}, {{scenario}}, {{mesExamples}}; single-brace aliases',
      scope: 'ordinary+Studio',
      behavior:
          'Current card fields. Lorebook char-field injections can prefix the first three.',
      emptyWhen:
          'Field is absent; the whole block may then be dropped unless empty emission is enabled.',
    ),
    SupportPresetKnowledgeRecord(
      id: 'persona',
      syntax: '{{persona}}; alias {persona}',
      scope: 'ordinary+Studio',
      behavior: 'Current persona prompt/description, not the persona name.',
      emptyWhen: 'No active persona prompt.',
    ),
    SupportPresetKnowledgeRecord(
      id: 'reasoningTags',
      syntax: '{{reasoningPrefix}}, {{reasoningSuffix}}',
      scope: 'ordinary+Studio',
      behavior: 'Configured reasoning tags; defaults to <think> and </think>.',
      emptyWhen: 'Defaults are used when no override exists.',
    ),
    SupportPresetKnowledgeRecord(
      id: 'trim',
      syntax: '{{trim}}',
      scope: 'ordinary+Studio',
      behavior:
          'Removes the marker and trims the whole containing text. Studio build-time variable expansion also handles it.',
      emptyWhen: 'Marker always disappears.',
    ),
    SupportPresetKnowledgeRecord(
      id: 'summary',
      syntax: '{{summary}}',
      scope: 'ordinary+Studio',
      behavior: 'Current prepared chat summary content.',
      emptyWhen: 'No summary was prepared for this request.',
    ),
    SupportPresetKnowledgeRecord(
      id: 'memory',
      syntax: '{{memory}}',
      scope: 'ordinary+Studio',
      behavior:
          'Memory Book content at the authored position; macro-target memory is finalized after context cutoff.',
      emptyWhen:
          'No selected memory, feature unavailable, or macro target has no authored marker.',
    ),
    SupportPresetKnowledgeRecord(
      id: 'lorebooks',
      syntax: '{{lorebooks}}',
      scope: 'ordinary+Studio',
      behavior:
          'Only lorebook entries classified for the macro position, expanded inline.',
      emptyWhen:
          'No active entry triggered for lorebooksMacro; before/after entries use separate routes.',
    ),
    SupportPresetKnowledgeRecord(
      id: 'guidance',
      syntax: '{{guidance}}',
      scope: 'ordinary+Studio',
      behavior: 'Current guided-generation instruction text.',
      emptyWhen: 'This request has no guided generation text.',
    ),
    SupportPresetKnowledgeRecord(
      id: 'studioState',
      syntax: '{{studio_state}}',
      scope: 'ordinary+Studio',
      behavior:
          'Compiled committed Ledger tracker state in <studio_session_state>. Hard-block injection deduplicates it.',
      emptyWhen: 'Ledger is disabled or has not written committed state.',
    ),
    SupportPresetKnowledgeRecord(
      id: 'arc',
      syntax: '{{arc}}',
      scope: 'ordinary+Studio',
      behavior: 'Selected Studio Canon arc:* tracker projection.',
      emptyWhen: 'No eligible current arc state.',
    ),
    SupportPresetKnowledgeRecord(
      id: 'entities',
      syntax: '{{entity}} or {{entities}}',
      scope: 'ordinary+Studio',
      behavior: 'Current entity projection; both spellings are aliases.',
      emptyWhen: 'No entity projection was prepared.',
    ),
    SupportPresetKnowledgeRecord(
      id: 'gameClock',
      syntax: '{{gametime}}, {{gamedate}}, {{gameday}}',
      scope: 'ordinary+Studio',
      behavior:
          'Ledger world:time, world:date and zero-based world:day respectively.',
      emptyWhen: 'The matching Ledger clock tracker is absent.',
    ),
    SupportPresetKnowledgeRecord(
      id: 'sessionVariables',
      syntax: '{{setvar::name::value}}, {{getvar::name}}',
      scope: 'ordinary+Studio',
      behavior:
          'Order-dependent session variables; setvar emits no text and supports nested macro braces in value.',
      emptyWhen: 'getvar name is missing; setvar always emits no text.',
    ),
    SupportPresetKnowledgeRecord(
      id: 'globalVariables',
      syntax: '{{setglobalvar::name::value}}, {{getglobalvar::name}}',
      scope: 'ordinary+Studio',
      behavior: 'Order-dependent global variables; setglobalvar emits no text.',
      emptyWhen: 'getglobalvar name is missing; setter always emits no text.',
    ),
    SupportPresetKnowledgeRecord(
      id: 'legacyGlobalAliases',
      syntax:
          '{{lumiaDef}}, {{lumiaOOC}}, {{lumiaOOCErotic}}, {{lumiaOOCEroticBleed}}, {{lumiaPersonality}}, {{loomRetrofits}}, {{loomStyle}}, {{loomSummary}}, {{loomUtils}}, {{sim_tracker}}, {{suggest}}',
      scope: 'ordinary+Studio',
      behavior:
          'Reads the same-named global variable for legacy preset compatibility.',
      emptyWhen:
          'Unlike getglobalvar, a missing value leaves the authored marker literal.',
    ),
    SupportPresetKnowledgeRecord(
      id: 'random',
      syntax: '{{random::a::b::...}}',
      scope: 'ordinary+Studio',
      behavior: 'Chooses one option nondeterministically for each expansion.',
      emptyWhen: 'No option text is supplied.',
    ),
    SupportPresetKnowledgeRecord(
      id: 'pick',
      syntax: '{{pick::a::b::...}}',
      scope: 'ordinary+Studio',
      behavior:
          'Deterministic per character, session, marker order and __pick_version session variable.',
      emptyWhen: 'No option text is supplied.',
    ),
    SupportPresetKnowledgeRecord(
      id: 'roll',
      syntax: '{{roll::NdM}}',
      scope: 'ordinary+Studio',
      behavior: 'Rolls N M-sided dice; matching is case-insensitive.',
      emptyWhen:
          'Invalid syntax leaves the argument text rather than an empty value.',
    ),
    SupportPresetKnowledgeRecord(
      id: 'localDateTime',
      syntax: '{{date}}, {{time}}, {{weekday}}, {{isodate}}, {{isotime}}',
      scope: 'ordinary+Studio',
      behavior:
          'Current local date/time. time includes seconds; isotime is HH:mm; isodate is YYYY-MM-DD.',
      emptyWhen: 'Never empty under a valid system clock.',
    ),
    SupportPresetKnowledgeRecord(
      id: 'offsetTime',
      syntax: '{{time::UTC+2}} or {{time::UTC-5.5}}',
      scope: 'ordinary+Studio',
      behavior:
          'Current UTC shifted by a signed, optionally fractional hour offset; emits HH:mm:ss.',
      emptyWhen: 'Malformed syntax remains literal.',
    ),
    SupportPresetKnowledgeRecord(
      id: 'formattedDateTime',
      syntax: '{{datetimeformat::FORMAT}}',
      scope: 'ordinary+Studio',
      behavior:
          'Moment-style subset: YYYY YY MMMM MMM MM M DD D dddd ddd HH H hh h mm m ss s A a.',
      emptyWhen: 'Unknown format text passes through unchanged.',
    ),
    SupportPresetKnowledgeRecord(
      id: 'summaryTemplateHistory',
      syntax: '{{history}}, {{previous_summary}}',
      scope: 'ordinary preset summaryPrompt only',
      behavior:
          'Summary service inserts transcript and prior summary after standard macros. Missing history marker appends transcript.',
      emptyWhen: 'previous_summary is removed when no prior summary exists.',
    ),
    SupportPresetKnowledgeRecord(
      id: 'cleanerBeauty',
      syntax: '{{beautyBrief}}',
      scope: 'Studio cleaner blocks only',
      behavior:
          'Post Clean stage inserts the current Beauty brief; standard macro engine does not own this placeholder.',
      emptyWhen: 'No effective Beauty brief.',
    ),
    SupportPresetKnowledgeRecord(
      id: 'studioBriefAliases',
      syntax: '{{studio_agent_briefs}}, {{studio_tracker_briefs}}',
      scope: 'Studio final blocks',
      behavior:
          'Both aliases render the sanitized, deduplicated prior controller briefs.',
      emptyWhen: 'No prior non-empty briefs exist.',
    ),
    for (final spec in StudioControllerOntology.specs)
      SupportPresetKnowledgeRecord(
        id: 'studioBrief:${spec.id}',
        syntax: '{{studio_${spec.id}_brief}}',
        scope: 'Studio final blocks',
        behavior: 'Renders prior briefs produced by the ${spec.name} lane.',
        emptyWhen:
            'That lane produced no retained brief; removed/unknown lane macros are stripped.',
      ),
  ];

  static final _ordinaryPlacement = <SupportPresetKnowledgeRecord>[
    for (final id in staticPresetBlockIds)
      SupportPresetKnowledgeRecord(
        id: 'block:$id',
        syntax: id,
        scope: 'ordinary preset block id',
        behavior: _ordinaryBlockBehavior(id),
        emptyWhen: _ordinaryBlockEmptyWhen(id),
      ),
    const SupportPresetKnowledgeRecord(
      id: 'relative',
      syntax: "insertionMode='relative'",
      scope: 'ordinary preset block',
      behavior: 'Emits in preset block order around the chat_history splice.',
      emptyWhen:
          'Disabled, stashed, or expansion is empty without sendEmptyBlock.',
    ),
    const SupportPresetKnowledgeRecord(
      id: 'depth',
      syntax: "insertionMode='depth', depth=N",
      scope: 'ordinary preset block except chat_history',
      behavior:
          'Interleaves N history messages from the end; missing depth behaves as 0.',
      emptyWhen: 'Disabled, stashed, or expansion is empty.',
    ),
    const SupportPresetKnowledgeRecord(
      id: 'appendToLastMessage',
      syntax: 'appendToLastMessage=true',
      scope: 'ordinary relative block',
      behavior:
          'After expansion, appends content to the last user history message and does not emit a separate message.',
      emptyWhen: 'No user history message or expanded content is empty.',
    ),
    const SupportPresetKnowledgeRecord(
      id: 'sendEmptyBlock',
      syntax: 'sendEmptyBlock=true',
      scope: 'ordinary preset block',
      behavior:
          'Allows an API message even when macro expansion leaves no visible content.',
      emptyWhen: 'Not applicable; explicitly preserves empty emission.',
    ),
    const SupportPresetKnowledgeRecord(
      id: 'rawRecall',
      syntax: '<recalled_messages> (automatic; no preset macro)',
      scope: 'ordinary prompt assembly',
      behavior:
          'Resolved after initial cutoff, excludes already-visible source messages, then inserts a system block before first history.',
      emptyWhen:
          'Recall not requested/unavailable, empty index/query, below threshold, source overlap, token budget, timeout or error.',
    ),
    const SupportPresetKnowledgeRecord(
      id: 'studioStateFallback',
      syntax: '<studio_session_state> automatic hard block',
      scope: 'ordinary prompt assembly',
      behavior:
          'Inserted before recalled_messages unless authored {{studio_state}} already emitted the same state.',
      emptyWhen: 'No committed Studio Ledger state.',
    ),
  ];

  static final _studioRouting = <SupportPresetKnowledgeRecord>[
    for (final point in studioInjectionPoints)
      SupportPresetKnowledgeRecord(
        id: 'point:$point',
        syntax: "injectionPoint='$point'",
        scope: 'Studio block',
        behavior: _studioPointBehavior(point),
        emptyWhen: _studioPointEmptyWhen(point),
      ),
    for (final section in StudioPresetValidator.supportedSections)
      SupportPresetKnowledgeRecord(
        id: 'section:$section',
        syntax: "section='$section'",
        scope: 'Studio persisted block',
        behavior: section == 'build' || section == 'brief_parser'
            ? 'Supported stored section used outside ordinary chat-time injection routing.'
            : 'Supported section; chat-time routing is controlled by injectionPoint.',
        emptyWhen:
            'A supported section alone does not guarantee this run consumes the block.',
      ),
    for (final role in StudioPresetValidator.supportedRoles)
      SupportPresetKnowledgeRecord(
        id: 'role:$role',
        syntax: "role='$role'",
        scope: 'Studio instruction block',
        behavior: role == 'system'
            ? 'Emits a system instruction.'
            : 'Passed through as an authored $role instruction role.',
        emptyWhen:
            'Unsupported or empty roles normalize to system at runtime; validator reports unsupported roles.',
      ),
    for (final mode in const [
      'direct',
      'pregenBrief',
      'functionPrefill',
      'agentResponse',
    ])
      SupportPresetKnowledgeRecord(
        id: 'mode:$mode',
        syntax: "mode='$mode'",
        scope: 'Studio block',
        behavior: _studioModeBehavior(mode),
        emptyWhen: _studioModeEmptyWhen(mode),
      ),
    for (final mode in StudioPresetValidator.supportedInsertionModes)
      SupportPresetKnowledgeRecord(
        id: 'insertion:$mode',
        syntax: "insertionMode='$mode'",
        scope: 'Studio instruction block',
        behavior: mode == 'depth'
            ? 'Interleaves at depth messages from the end of the selected history.'
            : 'Participates in order-sorted routing for its injection point.',
        emptyWhen: mode == 'depth'
            ? 'Ignored for non-instruction blocks; validator warns when depth is absent.'
            : 'Disabled or empty instruction.',
      ),
    const SupportPresetKnowledgeRecord(
      id: 'appendToLastMessage',
      syntax: 'appendToLastMessage=true',
      scope: 'Studio instruction block',
      behavior:
          'Expanded once, merged into the last user history message and not emitted separately.',
      emptyWhen:
          'No user history message, non-instruction type, or empty expansion.',
    ),
    const SupportPresetKnowledgeRecord(
      id: 'prefillStyles',
      syntax: "prefillStyle='tool'|'structured'|'two-pass'",
      scope: 'Studio functionPrefill block',
      behavior:
          'Selects synthetic tool tail, provider structured schema, or two-pass reasoning flow.',
      emptyWhen:
          'Only meaningful for functionPrefill; thinking pass skips visible prefill.',
    ),
    for (final spec in StudioControllerOntology.specs)
      SupportPresetKnowledgeRecord(
        id: 'lane:${spec.id}',
        syntax: "targetAgentId='${spec.id}'",
        scope: 'Studio controller ontology',
        behavior:
            '${spec.name}; phase=${spec.phase}; final=${spec.isFinal}; lockedOn=${spec.lockedOn}.',
        emptyWhen: spec.isFinal || spec.phase == 'post_processing'
            ? 'Use its dedicated injection point rather than specificAgent routing.'
            : 'Lane disabled, dependency unavailable, or no matching specificAgent block.',
      ),
  ];

  static final _studioContext = <SupportPresetKnowledgeRecord>[
    for (final slot in StudioContextSlot.values)
      SupportPresetKnowledgeRecord(
        id: slot.name,
        syntax: "contextSlot='${slot.name}'",
        scope: 'Studio context block',
        behavior: _studioContextBehavior(slot),
        emptyWhen: _studioContextEmptyWhen(slot),
      ),
  ];

  static String _ordinaryBlockBehavior(String id) => switch (id) {
    'worldInfoBefore' =>
      'Native lorebook entries classified before the character card.',
    'worldInfoAfter' =>
      'Native lorebook entries classified after character card and before history.',
    'char_card' =>
      'Saved character description; anchors native lorebook before/after placement.',
    'char_personality' => 'Saved character personality.',
    'user_persona' => 'Native User Name plus current persona prompt.',
    'scenario' => 'Saved character scenario.',
    'example_dialogue' => 'Saved character example dialogue.',
    'chat_history' =>
      'Splices selected history, depth blocks, continue instruction and appended blocks.',
    'summary' => 'Native current summary with the block/payload prefix.',
    'authors_note' =>
      'Current session Author’s Note using this block role and placement.',
    'guided_generation' =>
      'Current guidance through the block’s authored wrapper.',
    'memory' =>
      'Dedicated Memory Book sink, equivalent to the memory macro content.',
    _ => 'Native ordinary-preset hard block.',
  };

  static String _ordinaryBlockEmptyWhen(String id) => switch (id) {
    'chat_history' => 'No selected history messages.',
    'user_persona' => 'Still emits User Name in a live context.',
    'summary' => 'No prepared summary.',
    'authors_note' => 'Author’s Note is disabled or empty.',
    'guided_generation' => 'No guidance text.',
    'memory' => 'No selected Memory content.',
    'worldInfoBefore' ||
    'worldInfoAfter' => 'No triggered lorebook entry for this classification.',
    _ => 'The corresponding saved field is empty.',
  };

  static String _studioPointBehavior(String point) => switch (point) {
    'pregen' => 'Consumed by non-final pre-generation controllers.',
    'specificAgent' =>
      'Consumed only by a matching non-final, non-post-processing controller spec id.',
    'final' => 'Consumed by Main Writer.',
    'cleaner' => 'Consumed by Post Clean.',
    'ledger' => 'Consumed by Studio Ledger.',
    _ => 'Unknown Studio injection point.',
  };

  static String _studioPointEmptyWhen(String point) => switch (point) {
    'specificAgent' =>
      'targetAgentId does not equal an active runtime controller spec id.',
    'cleaner' ||
    'ledger' => 'The matching post-processing lane is disabled or unavailable.',
    _ => 'No matching active lane consumes the block.',
  };

  static String _studioModeBehavior(String mode) => switch (mode) {
    'direct' => 'Expands authored text and emits it as an instruction.',
    'pregenBrief' =>
      'Final writer receives sanitized prior briefs unless explicit brief macros are authored.',
    'functionPrefill' =>
      'Shapes the final output start/schema according to prefillStyle.',
    'agentResponse' =>
      'Produces no authored instruction message in the message builder.',
    _ => 'Unknown Studio mode.',
  };

  static String _studioModeEmptyWhen(String mode) => switch (mode) {
    'pregenBrief' =>
      'Not the final writer, explicit brief macros exist, or no prior briefs.',
    'functionPrefill' => 'Empty expansion or a thinking-only pass.',
    'agentResponse' => 'Always inert in ordinary instruction emission.',
    _ => 'Expanded text is empty.',
  };

  static String _studioContextBehavior(
    StudioContextSlot slot,
  ) => switch (slot) {
    StudioContextSlot.characterCard =>
      'Current character description/card context.',
    StudioContextSlot.characterPersonality => 'Current character personality.',
    StudioContextSlot.userPersona => 'Current persona identity and prompt.',
    StudioContextSlot.scenario => 'Current character scenario.',
    StudioContextSlot.exampleDialogue => 'Current character example dialogue.',
    StudioContextSlot.authorsNote => 'Current enabled session Author’s Note.',
    StudioContextSlot.summary => 'Prepared chat summary.',
    StudioContextSlot.memory => 'Selected Memory Book context.',
    StudioContextSlot.loreBefore => 'Triggered lorebook before-card messages.',
    StudioContextSlot.loreAfter => 'Triggered lorebook after-card messages.',
    StudioContextSlot.loreMacro => 'Triggered lorebook macro-position content.',
    StudioContextSlot.recalledMessages =>
      'Raw Recall <recalled_messages>; this is a context slot, not a macro.',
    StudioContextSlot.characterKnowledge =>
      'Effective committed character knowledge/canon.',
    StudioContextSlot.studioSessionState =>
      'Committed Studio Ledger session state.',
    StudioContextSlot.runtimeDynamic =>
      'Game clock, guidance, arc, entities and other current runtime context.',
    StudioContextSlot.staticContext =>
      'Aggregate: card, personality, persona, scenario, examples and Author’s Note.',
    StudioContextSlot.dynamicContext =>
      'Aggregate: canon, Ledger state, summary, Memory, lorebooks, Raw Recall and runtime dynamic.',
  };

  static String _studioContextEmptyWhen(
    StudioContextSlot slot,
  ) => switch (slot) {
    StudioContextSlot.recalledMessages =>
      'Recall unavailable/not requested, no usable match, source overlap, budget trim, timeout or error.',
    StudioContextSlot.memory => 'No selected Memory content.',
    StudioContextSlot.loreBefore ||
    StudioContextSlot.loreAfter ||
    StudioContextSlot.loreMacro =>
      'No triggered lorebook entry for this classification.',
    StudioContextSlot.studioSessionState =>
      'Ledger disabled or no committed tracker state.',
    StudioContextSlot.summary => 'No prepared summary.',
    StudioContextSlot.authorsNote => 'Disabled or empty.',
    StudioContextSlot.staticContext ||
    StudioContextSlot.dynamicContext => 'Every component slot is empty.',
    _ => 'The current request prepared no content for this slot.',
  };
}
