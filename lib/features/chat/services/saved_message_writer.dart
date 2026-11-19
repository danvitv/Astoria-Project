import '../../../core/models/chat_message.dart';
import '../../../core/utils/id_generator.dart';
import '../../../core/utils/time_helpers.dart';
import '../../image_gen/services/image_tag_markup.dart';
import '../chat_state.dart';

const _studioWriterCheckpointKey = 'studioWriterCheckpoint';

/// Pure-function helpers for building the final [ChatState] after one
/// generation cycle (success or error). Constructor injection of
/// pre-computed inputs (pendingSessionVars, previous swipes, etc.) so
/// this class has no dependency on Riverpod, SseClient, or the chat
/// provider. It is called by [StreamGenerationService] when the SSE
/// stream completes or errors out, and by [ChatNotifier] for regen/continue
/// rollback paths.
class SavedMessageWriter {
  const SavedMessageWriter();

  /// Success path: build the assistant message, attach swipes/meta, and
  /// return a [ChatState] with the new last message appended to the session.
  /// If [regenTargetId] is given, update that message rather than appending
  /// a new message.
  ///
  /// On regen, the new text is appended to `swipes[]` (green icons) as a
  /// new swipe and `swipeId` points at it; on a new generation, `swipes[]`
  /// is seeded with a single swipe pointing at the new text.
  /// A [studioFinalOnly] regen stays in the current outer swipe: it appends
  /// a nested final to a healthy swipe or replaces an errored swipe in place.
  /// It leaves the session unchanged if the saved target is missing.
  ChatState writeAssistant({
    required String text,
    required String? reasoning,
    required ChatSession currentSession,
    required bool Function() isAborted,
    Map<String, String>? pendingSessionVars,
    String? genTime,
    int? tokens,
    String? rawResponse,
    String? time,
    List<String>? previousSwipes,
    int previousSwipeId = 0,
    String? previousReasoning,
    String? previousGenTime,
    int? previousTokens,
    List<Map<String, dynamic>>? previousSwipesMeta,
    String? guidanceText,
    String guidanceType = 'GENERATION',
    Map<String, dynamic> memoryCoverage = const {},
    bool isAllReasoning = false,
    List<TriggeredEntry> triggeredLorebooks = const [],
    List<TriggeredEntry> triggeredMemories = const [],
    String? regenTargetId,
    int visibleStartIndex = 0,
    List<Map<String, dynamic>> studioOutputs = const [],
    Map<String, dynamic>? studioWriterCheckpoint,
    bool studioFinalOnly = false,
  }) {
    // A reply can only *ask* for a picture. Glaze is the sole writer of a
    // finished image block — it writes the `<img data-iig-…>` element the
    // moment it has saved the file — so one arriving in model output names
    // files that do not exist: the message would render a broken picture with
    // a variant switcher counting images that were never generated. Reduced to
    // the pending tag it should have been, the post-gen image stage picks it up
    // and produces a real image (INV-IG12).
    text = ImageTagMarkup.reduceBlocksToInstructions(text);
    final persistedMemoryCoverage = stripEphemeralMemoryCoverage(
      memoryCoverage,
    );
    List<String> swipes;
    int swipeId;

    if (previousSwipes != null && previousSwipes.isNotEmpty) {
      swipes = [...previousSwipes, text];
      swipeId = swipes.length - 1;
    } else {
      swipes = [text];
      swipeId = 0;
    }

    final currentSwipeMeta = <String, dynamic>{
      'genTime': genTime,
      'reasoning': reasoning,
      'tokens': tokens,
      // Opening game clock (Studio only): stamped at creation so the badge
      // renders with the initial append instead of waiting for the
      // post-turn Ledger update.
      'time': ?time,
      if (studioOutputs.isNotEmpty) 'studioOutputs': studioOutputs,
      _studioWriterCheckpointKey: ?studioWriterCheckpoint,
      // Persist triggered entries per swipe so each variation shows its own
      // lorebook/memory activations (restored on swipe in ChatMessageService).
      if (triggeredLorebooks.isNotEmpty)
        'triggeredLorebooks': triggeredLorebooks
            .map((e) => e.toJson())
            .toList(),
      if (triggeredMemories.isNotEmpty)
        'triggeredMemories': triggeredMemories.map((e) => e.toJson()).toList(),
    };
    if (guidanceText != null && guidanceText.isNotEmpty) {
      currentSwipeMeta['guidanceText'] = guidanceText;
      currentSwipeMeta['guidanceType'] = guidanceType;
    }

    List<Map<String, dynamic>> swipesMeta;
    if (previousSwipes != null && previousSwipes.isNotEmpty) {
      final prevMeta = <String, dynamic>{
        'genTime': previousGenTime,
        'reasoning': previousReasoning,
        'tokens': previousTokens,
      };
      swipesMeta = [
        for (var i = 0; i < previousSwipes.length; i++)
          if (previousSwipesMeta != null && i < previousSwipesMeta.length)
            previousSwipesMeta[i]
          else
            i == previousSwipeId ? prevMeta : <String, dynamic>{},
        currentSwipeMeta,
      ];
    } else {
      swipesMeta = [currentSwipeMeta];
    }

    final finalSwipe = AgentSwipe(
      content: text,
      kind: 'final',
      reasoning: reasoning,
      genTime: genTime,
      tokens: tokens,
      time: time,
      studioOutputs: studioOutputs,
    );
    if (regenTargetId != null) {
      if (isAborted()) {
        return ChatState(
          session: currentSession,
          isGenerating: false,
          visibleStartIndex: visibleStartIndex,
        );
      }
      final idx = currentSession.messages.indexWhere(
        (m) => m.id == regenTargetId,
      );
      if (idx >= 0) {
        final existing = currentSession.messages[idx];

        // Full regen creates a new outer swipe with a single nested final.
        final agentSwipes = <AgentSwipe>[];
        if (studioFinalOnly) {
          // Use the saved target, not the caller's full-regen swipe inputs.
          swipes = existing.swipes.isEmpty
              ? [existing.content]
              : [...existing.swipes];
          swipeId = existing.swipes.isEmpty
              ? 0
              : existing.swipeId.clamp(0, swipes.length - 1);
          swipesMeta = _alignedMeta(existing, swipes.length);
          final activeMeta = swipesMeta[swipeId];
          if (!existing.isError && activeMeta['isError'] != true) {
            agentSwipes.addAll(_activeAgentSwipes(existing));
            if (agentSwipes.isEmpty) {
              // Backfill the old reply before adding a final to a legacy swipe.
              agentSwipes.add(
                AgentSwipe(
                  content: existing.content,
                  kind: 'final',
                  parentSwipeId: swipeId,
                  reasoning: existing.reasoning,
                  genTime: existing.genTime,
                  tokens: existing.tokens,
                  time: existing.time,
                  studioOutputs: existing.studioOutputs,
                ),
              );
            }
          }
          swipes[swipeId] = text;
          swipesMeta[swipeId] = {
            ...activeMeta,
            ...currentSwipeMeta,
            'isError': false,
            'time': time,
            'studioOutputs': studioOutputs,
            'continuationOffset': null,
            'guidanceText': guidanceText,
            'guidanceType': guidanceType,
            'triggeredLorebooks': currentSwipeMeta['triggeredLorebooks'],
            'triggeredMemories': currentSwipeMeta['triggeredMemories'],
          };
        }
        agentSwipes.add(finalSwipe.copyWith(parentSwipeId: swipeId));
        final agentSwipeId = agentSwipes.length - 1;
        // Green-swipe round-trips restore the selected nested variation.
        swipesMeta[swipeId] = {
          ...swipesMeta[swipeId],
          'agentSwipes': agentSwipes.map((e) => e.toJson()).toList(),
          'agentSwipeId': agentSwipeId,
        };

        final updated = existing.copyWith(
          content: text,
          reasoning: reasoning,
          isAllReasoning: isAllReasoning,
          // A guided swipe's instruction belongs to the variation it produced:
          // the message shows it while that variation is the visible one, and
          // `ChatMessageService.setSwipe` restores it from the swipe's meta.
          // A reply steered from the composer is described by the user message
          // that carries it, so it leaves no block on this one.
          guidanceText: guidanceType == 'SWIPE' ? guidanceText : null,
          guidanceType: guidanceType,
          // Regen is a fresh event: restamp the message so the chat
          // list (sorted on the last message's timestamp) surfaces the
          // session again. The message keeps its position in the chat — only
          // the stamp moves.
          timestamp: DateTime.now().millisecondsSinceEpoch,
          isError: false,
          isTyping: false,
          genTime: genTime,
          tokens: tokens,
          continuationOffset: studioFinalOnly
              ? null
              : existing.continuationOffset,
          swipes: swipes,
          swipeId: swipeId,
          swipesMeta: swipesMeta,
          swipeDirection: 'right',
          memoryCoverage: persistedMemoryCoverage,
          triggeredLorebooks: triggeredLorebooks,
          triggeredMemories: triggeredMemories,
          agentSwipes: agentSwipes,
          agentSwipeId: agentSwipeId,
          studioOutputs: studioOutputs,
          // Fresh variation carries the opening clock (may be null when no
          // complete game-time tuple exists); Ledger restamps after the turn.
          time: time,
        );
        final updatedMessages = [...currentSession.messages];
        updatedMessages[idx] = updated;
        final finalSession = currentSession.copyWith(
          messages: updatedMessages,
          updatedAt: currentTimestampSeconds(),
          sessionVars: pendingSessionVars ?? currentSession.sessionVars,
        );
        return ChatState(
          session: finalSession,
          lastRawResponse: rawResponse,
          regenTargetId: regenTargetId,
          visibleStartIndex: visibleStartIndex,
        );
      }
    }

    if (studioFinalOnly || isAborted()) {
      return ChatState(
        session: currentSession,
        isGenerating: false,
        visibleStartIndex: visibleStartIndex,
      );
    }

    if (studioWriterCheckpoint != null) {
      currentSwipeMeta['agentSwipes'] = [finalSwipe.toJson()];
      currentSwipeMeta['agentSwipeId'] = 0;
    }
    final assistantMsg = ChatMessage(
      id: generateId(),
      role: 'assistant',
      content: text,
      reasoning: reasoning,
      isAllReasoning: isAllReasoning,
      genTime: genTime,
      tokens: tokens,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      time: time,
      swipes: swipes,
      swipeId: swipeId,
      swipesMeta: swipesMeta,
      memoryCoverage: persistedMemoryCoverage,
      triggeredLorebooks: triggeredLorebooks,
      triggeredMemories: triggeredMemories,
      agentSwipes: [finalSwipe],
      agentSwipeId: 0,
      studioOutputs: studioOutputs,
    );
    final finalMessages = [...currentSession.messages, assistantMsg];
    final now = currentTimestampSeconds();
    final sessionVars = pendingSessionVars ?? currentSession.sessionVars;
    final finalSession = currentSession.copyWith(
      messages: finalMessages,
      updatedAt: now,
      sessionVars: sessionVars,
    );
    return ChatState(
      session: finalSession,
      lastRawResponse: rawResponse,
      visibleStartIndex: visibleStartIndex,
    );
  }

  static Map<String, dynamic> stripEphemeralMemoryCoverage(
    Map<String, dynamic> coverage,
  ) {
    if (coverage.isEmpty || !coverage.containsKey('diagnostics')) {
      return coverage;
    }
    final out = Map<String, dynamic>.from(coverage);
    out.remove('diagnostics');
    return out;
  }

  /// Error path (non-regen): append an error message without changing session
  /// variables (INV-C5). Think display fields require a completed checkpoint.
  /// Called from SSE onError and from the top-level catch.
  ChatState writeError({
    required String errorText,
    required ChatSession currentSession,
    int visibleStartIndex = 0,
    Map<String, dynamic>? studioWriterCheckpoint,
    List<Map<String, dynamic>> studioOutputs = const [],
    String? reasoning,
    String? guidanceText,
    String guidanceType = 'GENERATION',
  }) {
    final hasCheckpoint = studioWriterCheckpoint != null;
    final errorMsg = ChatMessage(
      id: generateId(),
      role: 'assistant',
      content: errorText,
      reasoning: hasCheckpoint ? reasoning : null,
      studioOutputs: hasCheckpoint ? studioOutputs : const [],
      guidanceText: guidanceText,
      guidanceType: guidanceType,
      isError: true,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      swipes: [errorText],
      swipeId: 0,
      // Per-swipe error marker: error styling follows the active variation
      // (see ChatMessageService.setSwipe), so swiping to a healthy swipe
      // clears the error window.
      swipesMeta: [
        _errorMeta(
          studioWriterCheckpoint,
          studioOutputs,
          reasoning,
          guidanceText,
          guidanceType,
        ),
      ],
    );
    final finalMessages = [...currentSession.messages, errorMsg];
    final finalSession = currentSession.copyWith(
      messages: finalMessages,
      updatedAt: currentTimestampSeconds(),
    );
    return ChatState(
      session: finalSession,
      visibleStartIndex: visibleStartIndex,
    );
  }

  /// Error path (full regen): append an error outer swipe to [regenTargetId]
  /// without changing session variables (INV-C5).
  ChatState writeRegenError({
    required String errorText,
    required ChatSession saveSession,
    required String regenTargetId,
    int visibleStartIndex = 0,
    Map<String, dynamic>? studioWriterCheckpoint,
    List<Map<String, dynamic>> studioOutputs = const [],
    String? reasoning,
    String? guidanceText,
    String guidanceType = 'GENERATION',
  }) {
    final idx = saveSession.messages.indexWhere((m) => m.id == regenTargetId);
    if (idx < 0) {
      return writeError(
        errorText: errorText,
        currentSession: saveSession,
        visibleStartIndex: visibleStartIndex,
        studioWriterCheckpoint: studioWriterCheckpoint,
        studioOutputs: studioOutputs,
        reasoning: reasoning,
        guidanceText: guidanceText,
        guidanceType: guidanceType,
      );
    }
    final original = saveSession.messages[idx];
    final priorSwipes = original.swipes.isNotEmpty
        ? [...original.swipes]
        : [original.content];
    final errorSwipes = [...priorSwipes, errorText];
    // Build metas for the prior (healthy) swipes, then append the error
    // swipe's meta carrying a per-swipe 'isError' marker so the error
    // styling stays bound to this variation only (see
    // ChatMessageService.setSwipe). The list is kept aligned 1:1 with
    // [errorSwipes] so the marker lands on the error swipe's index.
    final priorMeta = _alignedMeta(original, priorSwipes.length);
    final priorId = original.swipes.isEmpty ? 0 : original.swipeId;
    if (priorId >= 0 && priorId < priorMeta.length) {
      final activeMeta = priorMeta[priorId];
      final priorIsError = activeMeta['isError'] == true || original.isError;
      final nested = priorIsError
          ? const <AgentSwipe>[]
          : _activeAgentSwipes(original);
      priorMeta[priorId] = {
        ...activeMeta,
        if (!activeMeta.containsKey('genTime')) 'genTime': original.genTime,
        if (!activeMeta.containsKey('reasoning'))
          'reasoning': original.reasoning,
        if (!activeMeta.containsKey('tokens')) 'tokens': original.tokens,
        if (!activeMeta.containsKey('time')) 'time': original.time,
        if (!activeMeta.containsKey('studioOutputs'))
          'studioOutputs': original.studioOutputs,
        if (!activeMeta.containsKey('continuationOffset') &&
            original.continuationOffset != null)
          'continuationOffset': original.continuationOffset,
        if (!activeMeta.containsKey('guidanceText') &&
            original.guidanceText != null)
          'guidanceText': original.guidanceText,
        if (!activeMeta.containsKey('guidanceType') &&
            original.guidanceText != null)
          'guidanceType': original.guidanceType,
        if (!activeMeta.containsKey('triggeredLorebooks') &&
            original.triggeredLorebooks.isNotEmpty)
          'triggeredLorebooks': original.triggeredLorebooks
              .map((e) => e.toJson())
              .toList(),
        if (!activeMeta.containsKey('triggeredMemories') &&
            original.triggeredMemories.isNotEmpty)
          'triggeredMemories': original.triggeredMemories
              .map((e) => e.toJson())
              .toList(),
        if (!activeMeta.containsKey('isError') && original.isError)
          'isError': true,
        if (nested.isNotEmpty)
          'agentSwipes': nested.map((e) => e.toJson()).toList(),
        if (nested.isNotEmpty)
          'agentSwipeId': original.agentSwipeId.clamp(0, nested.length - 1),
      };
    }
    final errorSwipesMeta = [
      ...priorMeta,
      _errorMeta(
        studioWriterCheckpoint,
        studioOutputs,
        reasoning,
        guidanceText,
        guidanceType,
      ),
    ];
    final updated = original.copyWith(
      content: errorText,
      isError: true,
      isTyping: false,
      swipes: errorSwipes,
      swipesMeta: errorSwipesMeta,
      swipeId: errorSwipes.length - 1,
      reasoning: studioWriterCheckpoint != null ? reasoning : null,
      studioOutputs: studioWriterCheckpoint != null ? studioOutputs : const [],
      guidanceText: guidanceText,
      guidanceType: guidanceType,
      // The new error outer has no nested finals. Its predecessor's variants
      // now live in that predecessor's meta, never under the error bubble.
      agentSwipes: const [],
      agentSwipeId: 0,
      genTime: null,
      tokens: null,
      time: null,
      continuationOffset: null,
      isAllReasoning: false,
      triggeredLorebooks: const [],
      triggeredMemories: const [],
    );
    final finalMessages = [...saveSession.messages];
    finalMessages[idx] = updated;
    final finalSession = saveSession.copyWith(
      messages: finalMessages,
      updatedAt: currentTimestampSeconds(),
    );
    return ChatState(
      session: finalSession,
      regenTargetId: regenTargetId,
      visibleStartIndex: visibleStartIndex,
    );
  }

  static Map<String, dynamic> _errorMeta(
    Map<String, dynamic>? checkpoint,
    List<Map<String, dynamic>> studioOutputs,
    String? reasoning,
    String? guidanceText,
    String guidanceType,
  ) => {
    'isError': true,
    _studioWriterCheckpointKey: ?checkpoint,
    if (checkpoint != null) ...{
      'reasoning': reasoning,
      'studioOutputs': studioOutputs,
    },
    if (guidanceText != null || guidanceType != 'GENERATION') ...{
      'guidanceText': guidanceText,
      'guidanceType': guidanceType,
    },
  };

  static List<Map<String, dynamic>> _alignedMeta(
    ChatMessage message,
    int length,
  ) => [
    for (var i = 0; i < length; i++)
      i < message.swipesMeta.length
          ? Map<String, dynamic>.from(message.swipesMeta[i])
          : <String, dynamic>{},
  ];

  static List<AgentSwipe> _activeAgentSwipes(ChatMessage message) {
    final swipes = [...message.agentSwipes];
    final active = message.agentSwipeId;
    if (active >= 0 &&
        active < swipes.length &&
        swipes[active].time == null &&
        message.time != null) {
      swipes[active] = swipes[active].copyWith(time: message.time);
    }
    return swipes;
  }

  /// Strip residual inline reasoning markers from streamed text. The
  /// model sometimes emits `<think>...</think>` outside the parsed
  /// reasoning block; this is a defensive cleanup.
  String sanitizeReasoningMarkers(
    String input,
    String tagStart,
    String tagEnd,
  ) {
    var s = input;
    if (tagStart.isNotEmpty) {
      s = s.replaceAll(tagStart, '');
    }
    if (tagEnd.isNotEmpty) {
      s = s.replaceAll(tagEnd, '');
    }
    s = s.replaceAll('<think>', '');
    s = s.replaceAll('</think>', '');
    s = s.replaceAll('<think>\n', '');
    s = s.replaceAll('\n</think>', '');
    s = s.replaceAll('<think> ', '');
    s = s.replaceAll(' </think>', '');
    s = s.replaceAll('<think', '');
    s = s.replaceAll('</think', '');
    s = s.replaceAll('think>', '');
    s = s.replaceAll('think\n', '');
    return s;
  }
}
