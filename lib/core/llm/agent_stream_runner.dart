import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/studio_config.dart';
import '../credentials/native_provider_credentials.dart';
import '../utils/id_generator.dart';
import 'agent_runner.dart' show AgentRunResult, ResolvedAgentConfig;
import 'reasoning_stripper.dart';
import 'stream_accumulator.dart';
import 'transport/call_attempt_outcome.dart';
import 'transport/chat_transport.dart';
import 'transport/chat_stream_exception.dart';
import 'transport/chat_transport_request.dart';
import 'transport/transport_factory.dart';
import 'transport/llm_call_event.dart';
import 'transport/llm_capture_context.dart';
import 'transport/llm_request_capture.dart';
import 'studio_controller_ontology.dart';
import 'diagnostics/studio_runtime_diagnostics.dart';
import 'diagnostics/studio_runtime_call_facts.dart';

/// The streaming state machine for a single Studio agent run, extracted
/// from `AgentRunner._runAgentInner` (plan §7.1). Given an already-resolved
/// [ResolvedAgentConfig] + the agent's `messages`, it builds a
/// [ChatTransportRequest], drives the LLM transport stream, accumulates
/// the output + reasoning, enforces the per-agent idle/total timeout, and
/// forwards incremental updates to the caller's callbacks.
///
/// Pure aside from the injected [AgentTransportPicker] (so the transport
/// selection is overridable in tests). Does NOT know about `Ref`, API
/// config resolution, or per-agent failure wrapping — those stay in
/// [AgentRunner]. Behavior preserved verbatim.
class AgentStreamRunner {
  // Studio shares one cancellation token across controllers and the final call.
  static final _pipelineIds = Expando<String>('studio pipeline');
  final AgentTransportPicker _pickTransport;

  AgentStreamRunner(this._pickTransport);

  /// Run one agent's LLM stream. Returns the final accumulated
  /// [AgentRunResult]. [isFinalResponse] = true → the generator; reasoning is
  /// forwarded to the UI. Ordinary trackers discard provider reasoning;
  /// Think replacement retains it separately from its visible block.
  Future<AgentRunResult> run({
    required StudioAgent agent,
    required List<Map<String, dynamic>> messages,
    required ResolvedAgentConfig resolved,
    required String sessionId,
    required bool isFinalResponse,
    required CancelToken cancelToken,
    required int timeoutMs,
    int? maxTokensOverride,
    double? temperatureOverride,
    String? tagStart,
    String? tagEnd,
    String? headerModel,
    String? headerInline,
    String? charName,
    String? userName,
    Map<String, dynamic>? responseJsonSchema,
    void Function(String text, String? reasoning)? onFinalResponseUpdate,
    void Function(String text)? onIntermediateUpdate,
    LlmCaptureContext? diagnosticContext,
  }) async {
    resolved.nativeSource?.requireCurrent();
    if (resolved.savedConnectionAuth != null &&
        _pickTransport == pickChatTransport) {
      throw const NativeProviderException(NativeProviderFailure.denied);
    }
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    final completer = Completer<AgentRunResult>();
    final shouldStream = resolved.stream;

    const defaultTagStart = '<think>';
    const defaultTagEnd = '</think>';
    final effectiveTagStart = (tagStart?.isNotEmpty == true)
        ? tagStart!
        : defaultTagStart;
    final effectiveTagEnd = (tagEnd?.isNotEmpty == true)
        ? tagEnd!
        : defaultTagEnd;
    // Think replacement needs the full tagged reply as text: ordinary
    // tracker reasoning is discarded, so splitting <thinking> would make a
    // successful response appear empty and trigger a retry.
    final hasInlineTags =
        agent.reasoningMode != 'think-replacement' &&
        effectiveTagStart.isNotEmpty &&
        effectiveTagEnd.isNotEmpty;

    final accumulator = StreamAccumulator(
      tagStart: effectiveTagStart,
      tagEnd: effectiveTagEnd,
      hasInlineTags: hasInlineTags,
      headerModel: headerModel,
      headerInline: headerInline,
    );
    final isThinkController = agent.reasoningMode == 'think-replacement';
    String intermediateText() {
      final visible = accumulator.text.trimLeft();
      if (!isThinkController || accumulator.reasoning.isEmpty) return visible;
      return [
        'Think controller (native reasoning):\n${accumulator.reasoning}',
        if (visible.isNotEmpty) visible,
      ].join('\n\n---\n\n');
    }

    var lastIntermediateUpdate = '';
    void reportIntermediateUpdate() {
      if (onIntermediateUpdate == null) return;
      final update = intermediateText();
      if (update == lastIntermediateUpdate || update.isEmpty) return;
      lastIntermediateUpdate = update;
      onIntermediateUpdate(update);
    }

    final baseCaptureContext = _defaultCaptureContext(
      agent: agent,
      sessionId: sessionId,
      isFinalResponse: isFinalResponse,
    );
    final runtime = StudioRuntimeDiagnostics.forRun(cancelToken, sessionId);
    final eventSink = LlmCallEventCapture.sink;
    final captureActive =
        resolved.savedConnectionAuth == null &&
        (diagnosticContext == null || runtime != null) &&
        (LlmRequestCapture.sink != null || LlmCallEventCapture.sink != null);
    final captureContext =
        diagnosticContext ??
        runtime?.newCall(baseCaptureContext.stage, agentId: agent.id) ??
        (captureActive
            ? baseCaptureContext
                  .withCallIdentity(
                    pipelineRunId: _pipelineIds[cancelToken] ??=
                        'studio-pipeline-${generateId()}',
                    callId: 'studio-call-${generateId()}',
                  )
                  .withAttempt(1)
            : baseCaptureContext);

    CancelToken? agentCancelToken;
    var nativeRequestOpen = true;
    final request = buildRequest(
      agent: agent,
      messages: messages,
      resolved: resolved,
      sessionId: sessionId,
      isFinalResponse: isFinalResponse,
      maxTokensOverride: maxTokensOverride,
      temperatureOverride: temperatureOverride,
      charName: charName,
      userName: userName,
      responseJsonSchema: responseJsonSchema,
      captureContext: captureContext,
      isCurrent: () =>
          nativeRequestOpen &&
          !cancelToken.isCancelled &&
          agentCancelToken?.isCancelled != true,
    );
    // Snapshot only the ACTUAL constructed request, before a transport can
    // reshape/normalize it. Native authority never enables raw request capture.
    final constructedRequestFacts =
        resolved.savedConnectionAuth != null && runtime?.isCurrent == true
        ? StudioRuntimeCallFacts.constructedRequest(request)
        : null;
    final transport = _pickTransport(resolved.protocol);
    final startedAt = DateTime.now();
    final startedAtMs = startedAt.millisecondsSinceEpoch;
    Timer? idleTimer;
    var streamStarted = false;
    var chunkCount = 0;
    int? firstChunkMs;
    int? lastChunkAtMs;
    var maxChunkGapMs = 0;
    var contentOffset = 0;
    var reasoningOffset = 0;
    final chunkTrace = <Map<String, int>>[];
    Map<String, int>? longestGap;
    var outcomeRecorded = false;
    var finiteOutcomeRecorded = false;
    String? streamTermination;
    String? providerFinishReason;

    void recordOutcome({
      String? responseText,
      Object? error,
      required String completionReason,
      StudioRuntimeReason? runtimeReason,
    }) {
      // Native saved auth never enables raw capture. Its original event sink
      // receives only a closed outcome from this actual completion branch.
      if (resolved.savedConnectionAuth != null && !finiteOutcomeRecorded) {
        finiteOutcomeRecorded = true;
        final (outcome, reason) = switch (runtimeReason) {
          StudioRuntimeReason.cancelled => (
            StudioRuntimeOutcome.cancelled,
            StudioRuntimeReason.cancelled,
          ),
          StudioRuntimeReason.idlePartial => (
            StudioRuntimeOutcome.fallback,
            StudioRuntimeReason.idlePartial,
          ),
          StudioRuntimeReason.childCancelledPartial => (
            StudioRuntimeOutcome.fallback,
            StudioRuntimeReason.childCancelledPartial,
          ),
          _ =>
            error == null
                ? (
                    StudioRuntimeOutcome.executed,
                    StudioRuntimeReason.transportCompleted,
                  )
                : (
                    StudioRuntimeOutcome.failed,
                    StudioRuntimeReason.transportFailed,
                  ),
        };
        runtime?.record(
          captureContext,
          outcome,
          reason,
          callFacts: constructedRequestFacts == null
              ? const {}
              : StudioRuntimeCallFacts.payload(
                  request: constructedRequestFacts!,
                  elapsedMs:
                      DateTime.now().millisecondsSinceEpoch - startedAtMs,
                  chunkCount: chunkCount,
                  firstChunkMs: firstChunkMs,
                  maxChunkGapMs: maxChunkGapMs,
                  contentOffset: contentOffset,
                  reasoningOffset: reasoningOffset,
                  completionReason: completionReason,
                  streamTermination: streamTermination,
                  callbackFinishReason: providerFinishReason,
                ),
        );
      }
      if (!captureActive ||
          outcomeRecorded ||
          !identical(LlmCallEventCapture.sink, eventSink))
        return;
      outcomeRecorded = true;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      unawaited(
        LlmCallEventCapture.record(
          LlmCallEvent.transport(
            context: captureContext,
            attempt: describeCallAttempt(
              attempt: captureContext.attempt ?? 1,
              startedAtMs: startedAtMs,
              elapsedMs: nowMs - startedAtMs,
              error: error,
            ),
            responseText: responseText,
            extraPayload: {
              'chunkCount': chunkCount,
              'firstChunkMs': ?firstChunkMs,
              'maxChunkGapMs': maxChunkGapMs,
              'completionReason': completionReason,
              'chunkTrace': chunkTrace,
              'chunkTraceTruncated': chunkCount > chunkTrace.length,
              'longestGap': ?longestGap,
              'streamTermination': ?streamTermination,
              'providerFinishReason': ?providerFinishReason,
            },
          ),
        ),
      );
    }

    void completeWithAccumulated(String reason) {
      if (completer.isCompleted) return;
      if (resolved.nativeSource?.isCurrent == false ||
          cancelToken.isCancelled) {
        completer.completeError(
          const NativeProviderException(NativeProviderFailure.stale),
        );
        return;
      }
      final text = accumulator.text.trim();
      final reasoningText = isFinalResponse || isThinkController
          ? accumulator.reasoning
          : '';
      recordOutcome(
        responseText: text.isNotEmpty ? text : null,
        completionReason: reason,
        runtimeReason: switch (reason) {
          'idle_timeout' => StudioRuntimeReason.idlePartial,
          'cancel_with_streamed_text' =>
            StudioRuntimeReason.childCancelledPartial,
          _ => null,
        },
      );
      completer.complete(AgentRunResult(text: text, reasoning: reasoningText));
    }

    void resetAgentTimer() {
      idleTimer?.cancel();
      idleTimer = Timer(Duration(milliseconds: timeoutMs), () {
        if (completer.isCompleted) return;
        if (shouldStream &&
            (accumulator.text.isNotEmpty || accumulator.reasoning.isNotEmpty)) {
          completeWithAccumulated('idle_timeout');
          agentCancelToken?.cancel('Studio agent idle timeout');
        } else if (!completer.isCompleted) {
          final timeoutError = TimeoutException(
            'Studio agent "${agent.name}" timed out after ${timeoutMs}ms',
          );
          recordOutcome(error: timeoutError, completionReason: 'timeout');
          completer.completeError(timeoutError);
          agentCancelToken?.cancel('Studio agent timeout');
        }
      });
    }

    agentCancelToken = CancelToken();
    unawaited(
      cancelToken.whenCancel.then((_) {
        if (!completer.isCompleted) {
          idleTimer?.cancel();
          final error = cancelToken.cancelError!;
          recordOutcome(
            responseText: accumulator.text,
            error: error,
            completionReason: 'cancelled',
            runtimeReason: StudioRuntimeReason.cancelled,
          );
          completer.completeError(error);
        }
        if (!(agentCancelToken?.isCancelled ?? true)) {
          agentCancelToken?.cancel('Studio pipeline cancelled');
        }
      }),
    );
    resetAgentTimer();

    unawaited(
      transport
          .stream(
            request: request,
            cancelToken: agentCancelToken,
            onUpdate: (delta, reasoningDelta) {
              if (completer.isCompleted ||
                  cancelToken.isCancelled ||
                  resolved.nativeSource?.isCurrent == false) {
                return;
              }
              if (delta.isNotEmpty || reasoningDelta?.isNotEmpty == true) {
                final nowMs = DateTime.now().millisecondsSinceEpoch;
                chunkCount++;
                firstChunkMs ??= nowMs - startedAtMs;
                if (lastChunkAtMs != null) {
                  final gap = nowMs - lastChunkAtMs!;
                  if (gap > maxChunkGapMs) {
                    maxChunkGapMs = gap;
                    longestGap = {
                      'gapMs': gap,
                      'contentOffset': contentOffset,
                      'reasoningOffset': reasoningOffset,
                      'chunk': chunkCount,
                    };
                  }
                }
                if (captureActive && chunkTrace.length < 2048) {
                  chunkTrace.add({
                    'elapsedMs': nowMs - startedAtMs,
                    'contentOffset': contentOffset,
                    'contentLength': delta.length,
                    'reasoningOffset': reasoningOffset,
                    'reasoningLength': reasoningDelta?.length ?? 0,
                  });
                }
                contentOffset += delta.length;
                reasoningOffset += reasoningDelta?.length ?? 0;
                lastChunkAtMs = nowMs;
              }
              accumulator.consumeDelta(delta, reasoningDelta: reasoningDelta);
              final effectiveText = accumulator.text.trimLeft();
              if (isFinalResponse) {
                onFinalResponseUpdate?.call(
                  effectiveText,
                  accumulator.reasoning.isNotEmpty
                      ? accumulator.reasoning
                      : null,
                );
              } else if (delta.isNotEmpty ||
                  (isThinkController && reasoningDelta?.isNotEmpty == true)) {
                reportIntermediateUpdate();
              }
              if (delta.isNotEmpty || reasoningDelta?.isNotEmpty == true) {
                if (!streamStarted) {
                  streamStarted = true;
                  idleTimer?.cancel();
                }
              }
            },
            onComplete: (text, finalReasoning, {rawResponseJson}) {
              if (completer.isCompleted ||
                  cancelToken.isCancelled ||
                  resolved.nativeSource?.isCurrent == false) {
                return;
              }
              if (rawResponseJson != null) {
                try {
                  final raw =
                      jsonDecode(rawResponseJson) as Map<String, dynamic>;
                  streamTermination = StudioRuntimeCallFacts.termination(
                    raw['astoria_stream_termination'],
                  );
                  final choices = raw['choices'] as List?;
                  if (choices != null &&
                      choices.isNotEmpty &&
                      choices.first is Map) {
                    providerFinishReason = StudioRuntimeCallFacts.finishReason(
                      choices.first['finish_reason'],
                    );
                  }
                } catch (_) {
                  // Other transports can return a different raw payload shape.
                }
              }
              idleTimer?.cancel();
              if (accumulator.text.isEmpty && text.isNotEmpty) {
                accumulator.consumeDelta(text, reasoningDelta: finalReasoning);
              }
              final effectiveText = accumulator.text.trimLeft();
              final effectiveReasoning = isFinalResponse || isThinkController
                  ? (accumulator.reasoning.isNotEmpty
                        ? accumulator.reasoning
                        : finalReasoning?.trim().isNotEmpty == true
                        ? finalReasoning!.trim()
                        : null)
                  : null;
              if (isFinalResponse) {
                if (effectiveText.isNotEmpty) {
                  onFinalResponseUpdate?.call(
                    effectiveText,
                    effectiveReasoning,
                  );
                } else if (text.isNotEmpty) {
                  onFinalResponseUpdate?.call(
                    text.trimLeft(),
                    effectiveReasoning,
                  );
                }
              } else {
                if (effectiveText.isNotEmpty ||
                    (isThinkController &&
                        effectiveReasoning?.isNotEmpty == true)) {
                  reportIntermediateUpdate();
                } else if (text.isNotEmpty) {
                  onIntermediateUpdate?.call(text.trimLeft());
                }
              }
              if (!completer.isCompleted) {
                final accumulatedText = effectiveText.isEmpty && text.isNotEmpty
                    ? text.trim()
                    : effectiveText;
                final finalText = accumulatedText.isNotEmpty
                    ? accumulatedText
                    : text.trim();
                final reasoningText = isFinalResponse || isThinkController
                    ? (accumulator.reasoning.isNotEmpty
                          ? accumulator.reasoning
                          : finalReasoning?.trim() ?? '')
                    : '';
                recordOutcome(
                  responseText: rawResponseJson ?? finalText,
                  completionReason: 'complete',
                );
                completer.complete(
                  AgentRunResult(
                    text: finalText,
                    reasoning: reasoningText,
                    rawResponseJson: rawResponseJson,
                  ),
                );
              }
            },
            onError: (error) {
              if (completer.isCompleted) return;
              if (resolved.nativeSource?.isCurrent == false ||
                  cancelToken.isCancelled) {
                idleTimer?.cancel();
                completer.completeError(
                  const NativeProviderException(NativeProviderFailure.stale),
                );
                return;
              }
              final elapsed = DateTime.now()
                  .difference(startedAt)
                  .inMilliseconds;
              idleTimer?.cancel();
              if (shouldStream &&
                  (agentCancelToken?.isCancelled ?? false) &&
                  accumulator.text.isNotEmpty) {
                completeWithAccumulated('cancel_with_streamed_text');
                return;
              }
              final partialText = error is ChatStreamException
                  ? error.partialText
                  : accumulator.text.trim();
              recordOutcome(
                responseText: partialText.isNotEmpty ? partialText : null,
                error: error,
                completionReason: error is ChatStreamException
                    ? error.reason
                    : 'error',
              );
              if (resolved.savedConnectionAuth == null) {
                debugPrint(
                  '[AgentRunner] agent error session=$sessionId '
                  'name="${agent.name}" elapsedMs=$elapsed error=$error',
                );
              }
              if (!completer.isCompleted) completer.completeError(error);
            },
          )
          .then<void>((_) {
            // Native revocation can cancel its child token without publishing a
            // callback. Drain that original job; never wait for a later timer to
            // reclassify it or publish an old partial as a successful new result.
            if (resolved.savedConnectionAuth != null &&
                !completer.isCompleted) {
              idleTimer?.cancel();
              final stale =
                  resolved.nativeSource?.isCurrent == false ||
                  cancelToken.isCancelled;
              recordOutcome(
                error: NativeProviderException(
                  stale
                      ? NativeProviderFailure.stale
                      : NativeProviderFailure.unavailable,
                ),
                completionReason: stale ? 'cancelled' : 'error',
                runtimeReason: stale ? StudioRuntimeReason.cancelled : null,
              );
              completer.completeError(
                NativeProviderException(
                  resolved.nativeSource?.isCurrent == false ||
                          cancelToken.isCancelled
                      ? NativeProviderFailure.stale
                      : NativeProviderFailure.unavailable,
                ),
              );
            }
          }),
    );

    return completer.future.whenComplete(() {
      nativeRequestOpen = false;
      idleTimer?.cancel();
    });
  }

  static LlmCaptureContext _defaultCaptureContext({
    required StudioAgent agent,
    required String sessionId,
    required bool isFinalResponse,
  }) => LlmCaptureContext(
    stage: isFinalResponse
        ? 'studio.final'
        : agent.phase == 'post_processing'
        ? 'studio.post_processing'
        : 'studio.controller',
    sessionId: sessionId,
    agentId: agent.id,
  );

  /// Builds the exact provider-neutral request used by [run] without invoking
  /// a transport. Prompt Inspector uses this pure seam for current previews.
  static ChatTransportRequest buildRequest({
    required StudioAgent agent,
    required List<Map<String, dynamic>> messages,
    required ResolvedAgentConfig resolved,
    required String sessionId,
    required bool isFinalResponse,
    int? maxTokensOverride,
    double? temperatureOverride,
    String? charName,
    String? userName,
    Map<String, dynamic>? responseJsonSchema,
    LlmCaptureContext? captureContext,
    bool Function()? isCurrent,
  }) {
    final hasInlineReasoningTags =
        resolved.reasoningTagStart?.isNotEmpty == true &&
        resolved.reasoningTagEnd?.isNotEmpty == true;
    final requestMessages =
        isFinalResponse &&
            (!resolved.requestReasoning || resolved.omitReasoning) &&
            !hasInlineReasoningTags
        ? ReasoningStripper.stripMessageReasoning(messages)
        : messages;
    final spec = StudioControllerOntology.specForAgent(agent);
    return ChatTransportRequest(
      savedConnectionAuth: resolved.savedConnectionAuth,
      savedConnectionId: resolved.savedConnectionId,
      nativeSourceIsCurrent: resolved.nativeSource?.bindNativeCurrent(
        isCurrent: isCurrent,
      ),
      endpoint: resolved.endpoint,
      apiKey: resolved.apiKey,
      model: resolved.model,
      messages: requestMessages,
      maxTokens: maxTokensOverride ?? (spec?.maxTokens ?? 8000),
      temperature: temperatureOverride ?? (spec?.temperature ?? 0.3),
      topP: resolved.topP,
      topK: resolved.topK,
      frequencyPenalty: resolved.frequencyPenalty,
      presencePenalty: resolved.presencePenalty,
      stream: resolved.stream,
      requestReasoning: resolved.requestReasoning,
      useResponsesApi: resolved.useResponsesApi,
      reasoningEffort: resolved.requestReasoning
          ? resolved.reasoningEffort
          : null,
      omitTemperature: resolved.omitTemperature,
      omitTopP: resolved.omitTopP,
      omitTopK: resolved.omitTopK,
      omitFrequencyPenalty: resolved.omitFrequencyPenalty,
      omitPresencePenalty: resolved.omitPresencePenalty,
      omitReasoning: resolved.omitReasoning,
      omitReasoningEffort: resolved.omitReasoningEffort,
      showNativeReasoning: resolved.showNativeReasoning,
      // The Studio timer owns first-chunk timeout semantics. A Dio receive
      // timeout would incorrectly become a second total/idle timeout.
      receiveTimeoutMs: 0,
      sessionId: sessionId,
      cacheControlTtl: resolved.cacheControlTtl,
      cacheBreakpointMode: resolved.cacheBreakpointMode,
      sessionIdMode: resolved.sessionIdMode,
      promptPostProcessing: resolved.promptPostProcessing,
      charName: charName,
      userName: userName,
      responseJsonSchema: responseJsonSchema,
      extraRequestParameters: resolved.extraRequestParameters,
      captureContext:
          captureContext ??
          _defaultCaptureContext(
            agent: agent,
            sessionId: sessionId,
            isFinalResponse: isFinalResponse,
          ),
    );
  }
}

/// Function signature for picking a chat transport by protocol. Extracted
/// so [AgentStreamRunner] can be tested without depending on
/// `pickChatTransport` directly.
typedef AgentTransportPicker = ChatTransport Function(String protocol);
