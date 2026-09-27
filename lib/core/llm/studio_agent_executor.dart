import 'package:dio/dio.dart';

import '../models/api_config.dart';
import '../models/pipeline_settings.dart';
import '../models/studio_config.dart';
import '../utils/error_format.dart';
import 'agent_runner.dart';
import 'studio_brief_parser.dart';
import 'studio_message_builder.dart';
import 'studio_stage_brief.dart';
import 'controller_batcher.dart';
import 'studio_turn_config_snapshot.dart';
import 'studio/studio_context.dart';

/// Runs the per-agent LLM calls of the Studio chat-time pipeline: the
/// pre-gen tracker, the post-processing tracker, the individual (non-batch)
/// fallback tracker, and the final generator. Extracted from
/// `MemoryStudioService` (plan §2.8).
///
/// Each adapter assembles the agent's message list via the injected
/// [StudioMessageBuilder], invokes [AgentRunner.runAgent], and adapts the
/// result type to the pipeline-internal [StudioStageBrief] / [ControllerBatchResult]
/// / [AgentRunResult] shapes. Tracker failures are retried by the
/// relevant adapter and returned as failed results when retries are exhausted;
/// the final generator rethrows.
class StudioAgentExecutor {
  final AgentRunner _runner;
  final StudioMessageBuilder _messageBuilder;
  final StudioBriefParser _briefParser;
  final PipelineSettings Function() _readPipelineSettings;

  StudioAgentExecutor(
    this._runner,
    this._messageBuilder,
    this._briefParser,
    this._readPipelineSettings,
  );

  Future<ResolvedAgentConfig> resolveTrackerConfig({
    required StudioAgent agent,
    required ApiConfig apiConfig,
    required String sessionId,
    String? apiConfigId,
    StudioTurnConfigSnapshot? turnConfig,
  }) {
    return _runner.resolveAgentConfig(
      agent,
      apiConfig,
      sessionId,
      apiConfigId: apiConfigId,
      turnConfig: turnConfig,
    );
  }

  int? effectiveMaxTokens(
    StudioAgent agent, [
    StudioTurnConfigSnapshot? turnConfig,
  ]) => _runner.effectiveMaxTokens(agent, false, turnConfig);

  double? effectiveTemperature(
    StudioAgent agent, [
    StudioTurnConfigSnapshot? turnConfig,
  ]) => _runner.effectiveTemperature(agent, false, turnConfig);

  /// Delegate the actual LLM call to [AgentRunner]. This method still
  /// builds the `messages` list (prompt assembly via [StudioMessageBuilder])
  /// and adapts the result type to the internal [StudioStageBrief] pipeline.
  ///
  /// When [isFinalResponse] is false, [AgentRunner.runAgent] wraps any failure
  /// into an [AgentRunFailedException]; here we unwrap it into a failed brief
  /// so callers can retry and then surface a hard Studio error. The final
  /// generator rethrows.
  Future<StudioStageBrief> runTracker({
    required StudioAgent agent,
    required StudioContext context,
    required ApiConfig apiConfig,
    required StudioConfig config,
    required StudioPreset studioPreset,
    required String sessionId,
    required CancelToken cancelToken,
    String? apiConfigId,
    StudioTurnConfigSnapshot? turnConfig,
    // 0 = the agent spec's own context size.
    int trackerContextOverride = 0,
    StudioAgent? finalAgent,
    StudioContext? finalContext,
    void Function(String text)? onIntermediateUpdate,
  }) async {
    if (_briefParser.isMetaPolicyAgent(agent)) {
      return StudioStageBrief(
        agentId: agent.id,
        agentName: agent.name,
        brief: _briefParser.metaPolicyBrief(agent),
      );
    }
    try {
      final isThink = agent.reasoningMode == 'think-replacement';
      final settings = turnConfig?.pipelineSettings ?? _readPipelineSettings();
      if (isThink && (finalAgent == null || finalContext == null)) {
        throw StateError('Think controller requires the Main Writer context.');
      }
      final messages = isThink
          ? _messageBuilder.buildThinkControllerMessages(
              agent: agent,
              finalAgent: finalAgent!,
              context: finalContext!,
              config: config,
              studioPreset: studioPreset,
              finalContextOverride: settings.studioAgent.studioFinalContextSize,
              reasoningHistoryCount:
                  settings.studioAgent.studioFinalReasoningHistoryCount,
              excludeReasoningFromContextBudget: settings
                  .studioAgent
                  .studioFinalExcludeReasoningFromContextBudget,
            )
          : _messageBuilder.buildAgentMessages(
              agent: agent,
              context: context,
              config: config,
              studioPreset: studioPreset,
              priorBriefs: const [],
              isFinalResponse: false,
              trackerContextOverride: trackerContextOverride,
            );
      final result = await _runner.runAgent(
        agent: agent,
        messages: messages,
        apiConfig: apiConfig,
        sessionId: sessionId,
        isFinalResponse: false,
        cancelToken: cancelToken,
        apiConfigId: apiConfigId,
        turnConfig: turnConfig,
        charName: context.macroContext.charName,
        userName: context.macroContext.userName,
        onIntermediateUpdate: onIntermediateUpdate,
      );
      return StudioStageBrief(
        agentId: agent.id,
        agentName: agent.name,
        brief: isThink
            ? (result.text.trim().isNotEmpty ? result.text : result.reasoning)
            : _briefParser.sanitizeIntermediateAgentOutput(agent, result.text),
        isThinkReplacement: isThink,
        // When the provider emits reasoning only, that reasoning becomes the
        // seeded <thinking> block. Do not store a duplicate native layer.
        nativeReasoning: isThink && result.text.trim().isNotEmpty
            ? result.reasoning
            : '',
      );
    } on AgentRunFailedException catch (error) {
      return StudioStageBrief(
        agentId: error.agentId,
        agentName: error.agentName,
        brief: 'Studio agent failed: ${error.reason}',
        status: 'error',
        error: error.reason,
      );
    }
  }

  /// Feature 6 — run ONE post-processing tracker. The tracker receives the
  /// generator's [mainResponse] in its context (as an extra
  /// `<assistant_response>` block appended to its `dynamic_context`) and
  /// can produce an edited/rewritten version. Its raw output is returned as
  /// a `StudioStageBrief` whose `brief` field is the rewritten text (NOT
  /// sanitized through the brief-shape contract — a post-gen tracker IS
  /// allowed to produce prose, since its job is to rewrite the response).
  /// The caller decides whether the rewrite replaces `mainResponse`.
  ///
  /// Failure policy: a post-gen tracker gets the same initial attempt + two
  /// retries as pre-gen trackers. Exhausting retries returns a failed brief;
  /// the caller surfaces it as a hard Studio error instead of silently keeping
  /// the previous `mainResponse`.
  Future<StudioStageBrief> runPostProcessingTracker({
    required StudioAgent agent,
    required String mainResponse,
    required StudioContext context,
    required ApiConfig apiConfig,
    required StudioConfig config,
    required StudioPreset studioPreset,
    required String sessionId,
    required CancelToken cancelToken,
    String? apiConfigId,
    StudioTurnConfigSnapshot? turnConfig,
  }) async {
    String? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      if (cancelToken.isCancelled) {
        return StudioStageBrief(
          agentId: agent.id,
          agentName: agent.name,
          brief: '',
          status: 'error',
          error: 'cancelled',
        );
      }
      try {
        final override =
            (turnConfig?.pipelineSettings ?? _readPipelineSettings())
                .studioAgent
                .studioPostControllerContextSize;
        final messages = _messageBuilder.buildAgentMessages(
          agent: agent,
          trackerContextOverride: override,
          context: context,
          config: config,
          studioPreset: studioPreset,
          priorBriefs: const [],
          isFinalResponse: false,
          mainResponse: mainResponse,
        );
        final result = await _runner.runAgent(
          agent: agent,
          messages: messages,
          apiConfig: apiConfig,
          sessionId: sessionId,
          isFinalResponse: false,
          cancelToken: cancelToken,
          apiConfigId: apiConfigId,
          turnConfig: turnConfig,
          charName: context.macroContext.charName,
          userName: context.macroContext.userName,
        );
        final text = result.text.trim();
        return StudioStageBrief(
          agentId: agent.id,
          agentName: agent.name,
          brief: text,
          status: text.isNotEmpty ? 'ok' : 'skipped',
        );
      } on AgentRunFailedException catch (error) {
        lastError = error.reason;
      }
    }
    return StudioStageBrief(
      agentId: agent.id,
      agentName: agent.name,
      brief: '',
      status: 'error',
      error: lastError ?? 'tracker failed after 2 retries',
    );
  }

  /// Run one individual tracker (not part of any batch group). Reuses the
  /// existing per-agent prompt assembly + AgentRunner.
  Future<ControllerBatchResult> runIndividualTracker({
    required StudioAgent agent,
    required StudioConfig config,
    required StudioPreset studioPreset,
    required StudioContext context,
    required ApiConfig apiConfig,
    required String sessionId,
    required CancelToken cancelToken,
    String? apiConfigId,
    StudioTurnConfigSnapshot? turnConfig,
    int trackerContextOverride = 0,
    StudioAgent? finalAgent,
    StudioContext? finalContext,
    void Function(String text)? onIntermediateUpdate,
  }) async {
    String? lastError;
    // A Think pass is a full-context, paid generation. Never silently resend
    // the same large request if it fails or yields an empty response.
    final maxAttempts = agent.reasoningMode == 'think-replacement' ? 1 : 3;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (cancelToken.isCancelled) {
        return ControllerBatchResult.failed(
          agentId: agent.id,
          agentName: agent.name,
          reason: 'cancelled',
        );
      }
      try {
        final brief = await runTracker(
          agent: agent,
          context: context,
          apiConfig: apiConfig,
          config: config,
          studioPreset: studioPreset,
          sessionId: sessionId,
          cancelToken: cancelToken,
          apiConfigId: apiConfigId,
          turnConfig: turnConfig,
          trackerContextOverride: trackerContextOverride,
          finalAgent: finalAgent,
          finalContext: finalContext,
          onIntermediateUpdate: onIntermediateUpdate,
        );
        if (brief.status == 'ok' && brief.brief.trim().isNotEmpty) {
          return ControllerBatchResult(
            agentId: agent.id,
            agentName: agent.name,
            text: brief.brief,
            nativeReasoning: brief.nativeReasoning,
            status: brief.status,
            error: brief.error,
          );
        }
        lastError = brief.error ?? 'tracker returned an empty response';
      } catch (error) {
        lastError = formatError(error);
      }
    }
    return ControllerBatchResult.failed(
      agentId: agent.id,
      agentName: agent.name,
      reason: lastError ?? 'tracker returned no response',
    );
  }

  Future<AgentRunResult> runFinalGenerator({
    required StudioAgent agent,
    required StudioContext context,
    required ApiConfig apiConfig,
    required StudioConfig config,
    required StudioPreset studioPreset,
    required List<StudioStageBrief> priorBriefs,
    required String sessionId,
    required CancelToken cancelToken,
    String? apiConfigId,
    StudioTurnConfigSnapshot? turnConfig,
    String? reasoningPrefill,
    String? controllerNativeReasoning,
    void Function(String text, String? reasoning)? onFinalResponseUpdate,
    void Function(List<Map<String, dynamic>> messages)? onMessagesBuilt,
    Future<void> Function()? beforeSend,
    void Function(Set<String> classifications)? onLorebookClassificationsBuilt,
  }) async {
    final settings = turnConfig?.pipelineSettings ?? _readPipelineSettings();
    final emittedLorebookClassifications = <String>{};
    final responseJsonSchema = <String, dynamic>{};
    final messages = _messageBuilder.buildAgentMessages(
      agent: agent,
      context: context,
      config: config,
      studioPreset: studioPreset,
      priorBriefs: priorBriefs,
      isFinalResponse: true,
      finalContextOverride: settings.studioAgent.studioFinalContextSize,
      reasoningHistoryCount:
          settings.studioAgent.studioFinalReasoningHistoryCount,
      excludeReasoningFromContextBudget:
          settings.studioAgent.studioFinalExcludeReasoningFromContextBudget,
      emittedLorebookClassifications: emittedLorebookClassifications,
      responseJsonSchema: responseJsonSchema,
    );
    onLorebookClassificationsBuilt?.call(emittedLorebookClassifications);
    if (reasoningPrefill != null && reasoningPrefill.trim().isNotEmpty) {
      return _runSeededFinalGenerator(
        agent: agent,
        context: context,
        apiConfig: apiConfig,
        config: config,
        studioPreset: studioPreset,
        priorBriefs: priorBriefs,
        sessionId: sessionId,
        cancelToken: cancelToken,
        apiConfigId: apiConfigId,
        turnConfig: turnConfig,
        baseMessages: messages,
        thinking: normalizeThinkingPrefill(reasoningPrefill),
        controllerNativeReasoning: controllerNativeReasoning,
        responseJsonSchema: responseJsonSchema,
        onMessagesBuilt: onMessagesBuilt,
        beforeSend: beforeSend,
        onFinalResponseUpdate: onFinalResponseUpdate,
      );
    }
    onMessagesBuilt?.call(messages);
    return _runner.runAgent(
      agent: agent,
      messages: messages,
      apiConfig: apiConfig,
      sessionId: sessionId,
      isFinalResponse: true,
      cancelToken: cancelToken,
      apiConfigId: apiConfigId,
      turnConfig: turnConfig,
      charName: context.macroContext.charName,
      userName: context.macroContext.userName,
      responseJsonSchema: responseJsonSchema.isEmpty
          ? null
          : responseJsonSchema,
      beforeSend: beforeSend,
      onFinalResponseUpdate: onFinalResponseUpdate,
    );
  }

  /// Seeds a prior assistant `<thinking>` turn into the final generator's
  /// request, followed by a user instruction to write visible prose only.
  /// This is textual message history, not provider-native thinking or a
  /// trailing assistant prefill; the final model may still reason internally.
  Future<AgentRunResult> _runSeededFinalGenerator({
    required StudioAgent agent,
    required StudioContext context,
    required ApiConfig apiConfig,
    required StudioConfig config,
    required StudioPreset studioPreset,
    required List<StudioStageBrief> priorBriefs,
    required String sessionId,
    required CancelToken cancelToken,
    String? apiConfigId,
    StudioTurnConfigSnapshot? turnConfig,
    required List<Map<String, dynamic>> baseMessages,
    required String thinking,
    String? controllerNativeReasoning,
    required Map<String, dynamic> responseJsonSchema,
    void Function(List<Map<String, dynamic>> messages)? onMessagesBuilt,
    Future<void> Function()? beforeSend,
    void Function(String text, String? reasoning)? onFinalResponseUpdate,
  }) async {
    final nudge =
        'The <thinking> block above is the completed internal analysis for '
        'this turn. Use it directly. Do not repeat, redo, extend, or output '
        'any audit or reasoning. Write only the final response.';
    final answerMessages = <Map<String, dynamic>>[
      ...baseMessages,
      {'role': 'assistant', 'content': thinking},
      {'role': 'user', 'content': nudge},
    ];
    onMessagesBuilt?.call(answerMessages);
    final answer = await _runner.runAgent(
      agent: agent,
      messages: answerMessages,
      beforeSend: beforeSend,
      apiConfig: apiConfig,
      sessionId: sessionId,
      isFinalResponse: true,
      cancelToken: cancelToken,
      apiConfigId: apiConfigId,
      turnConfig: turnConfig,
      charName: context.macroContext.charName,
      userName: context.macroContext.userName,
      responseJsonSchema: responseJsonSchema.isEmpty
          ? null
          : responseJsonSchema,
      onFinalResponseUpdate: onFinalResponseUpdate == null
          ? null
          : (text, reasoning) => onFinalResponseUpdate(
              text,
              combineThinkingReasoning(
                thinking,
                reasoning,
                controllerReasoning: controllerNativeReasoning,
              ),
            ),
    );
    final combinedReasoning = combineThinkingReasoning(
      thinking,
      answer.reasoning,
      controllerReasoning: controllerNativeReasoning,
    );
    return AgentRunResult(
      text: answer.text,
      reasoning: combinedReasoning,
      rawResponseJson: answer.rawResponseJson,
    );
  }

  static String normalizeThinkingPrefill(String value) {
    var body = value.trim();
    body = body.replaceFirst(RegExp(r'^```(?:\w+)?\s*'), '');
    body = body.replaceFirst(RegExp(r'\s*```$'), '');
    for (final tag in const ['thinking', 'audit']) {
      final opening = RegExp(
        '<$tag\\b[^>]*>',
        caseSensitive: false,
      ).firstMatch(body);
      if (opening == null) continue;
      final closings = RegExp(
        '</$tag\\s*>',
        caseSensitive: false,
      ).allMatches(body);
      final closing = closings.where((match) => match.start >= opening.end).lastOrNull;
      if (closing != null) {
        // Controller prose may quote the closing tag while paraphrasing an
        // instruction. The final closing tag still delimits the outer block.
        body = body.substring(opening.end, closing.start).trim();
        break;
      }
    }
    return '<thinking>\n$body\n</thinking>';
  }

  static String combineThinkingReasoning(
    String thinking,
    String? reasoning, {
    String? controllerReasoning,
  }) {
    final firstReasoning = controllerReasoning?.trim() ?? '';
    final secondReasoning = reasoning?.trim() ?? '';
    return [
      if (firstReasoning.isNotEmpty)
        'Think controller (native reasoning):\n$firstReasoning',
      thinking,
      if (secondReasoning.isNotEmpty && secondReasoning != thinking)
        'Main Writer (native reasoning):\n$secondReasoning',
    ].join('\n\n---\n\n');
  }
}
