import 'dart:async';

import 'package:dio/dio.dart';

import '../../utils/id_generator.dart';
import '../transport/llm_call_event.dart';
import '../transport/llm_capture_context.dart';
import 'studio_runtime_call_facts.dart';

/// Closed runtime vocabulary. No prompt, model name, route, credential, output
/// or exception prose enters these events, including native saved connections.
enum StudioRuntimeOutcome {
  executed('executed'),
  skipped('skipped'),
  blockingFailure('blocking_failure'),
  fallback('fallback'),
  failed('failed'),
  cancelled('cancelled');

  const StudioRuntimeOutcome(this.wire);
  final String wire;
}

enum StudioRuntimeReason {
  controllerAccepted('controller_results_accepted'),
  phaseCompleted('pre_generation_completed'),
  transportCompleted('transport_completed'),
  cacheHit('cache_hit'),
  noEnabledAgents('no_enabled_agents'),
  noFinalAgent('no_final_agent'),
  noControllers('no_pre_generation_controllers'),
  missingPreset('missing_preset'),
  thinkWriterMissing('think_writer_missing'),
  requiredTrackerFailed('required_tracker_failed'),
  phaseException('pre_generation_exception'),
  phaseTimeout('pre_generation_timeout'),
  idlePartial('idle_timeout_partial'),
  childCancelledPartial('cancelled_child_partial'),
  transportFailed('transport_failed'),
  cancelled('cancelled');

  const StudioRuntimeReason(this.wire);
  final String wire;
}

/// Original-token/original-sink metadata recorder, not a generation executor.
/// A sink switch retires this run rather than delivering an old run to a new DB.
/// Limits are diagnostic-only: exhaustion cannot change a generation result.
final class StudioRuntimeDiagnostics {
  StudioRuntimeDiagnostics._(this.sessionId, this._sink)
    : pipelineRunId = 'studio-pipeline-${generateId()}',
      _sinkRevision = LlmCallEventCapture.sinkRevision,
      _phaseCallId = 'studio-phase-${generateId()}';

  static final _runs = Expando<StudioRuntimeDiagnostics>('Studio diagnostics');
  static StudioRuntimeDiagnostics? forRun(CancelToken token, String sessionId) {
    final existing = _runs[token];
    if (existing != null) {
      return existing.sessionId == sessionId && existing.isCurrent
          ? existing
          : null;
    }
    final sink = LlmCallEventCapture.sink;
    if (sink == null) return null;
    return _runs[token] = StudioRuntimeDiagnostics._(sessionId, sink);
  }

  final String sessionId, pipelineRunId, _phaseCallId;
  final LlmCallEventSink _sink;
  final int _sinkRevision;
  int _records = 0;
  bool _retired = false;
  bool get isCurrent {
    if (_sinkRevision != LlmCallEventCapture.sinkRevision ||
        !identical(LlmCallEventCapture.sink, _sink)) {
      _retired = true;
    }
    return !_retired;
  }

  LlmCaptureContext get phaseContext => LlmCaptureContext(
    stage: 'studio.pre_generation.phase',
    sessionId: sessionId,
    pipelineRunId: pipelineRunId,
    callId: _phaseCallId,
    attempt: 1,
  );

  LlmCaptureContext newCall(String stage, {String? agentId}) =>
      LlmCaptureContext(
        stage: stage,
        sessionId: sessionId,
        pipelineRunId: pipelineRunId,
        callId: 'studio-call-${generateId()}',
        parentCallId: _phaseCallId,
        agentId: agentId,
        attempt: 1,
      );

  bool _owns(LlmCaptureContext context) =>
      context.sessionId == sessionId &&
      context.pipelineRunId == pipelineRunId &&
      context.callId != null &&
      context.attempt != null &&
      context.attempt! > 0;

  void record(
    LlmCaptureContext? context,
    StudioRuntimeOutcome outcome,
    StudioRuntimeReason reason, {
    Map<String, dynamic> callFacts = const {},
  }) {
    if (context == null || !isCurrent || !_owns(context) || _records >= 128) {
      return;
    }
    _records++;
    // Invoke synchronously so the existing repo serial queue retains the exact
    // event order. Failure is observational only and contains no raw exception.
    try {
      final result = _sink.recordCallEvent(
        LlmCallEvent(
          id: 'llm-event-${generateId()}',
          createdAt: DateTime.now().toUtc(),
          context: context,
          // Existing append-only schema vocabulary; no migration/generation.
          kind: context.stage == 'studio.pre_generation.phase'
              ? outcome == StudioRuntimeOutcome.blockingFailure
                    ? 'pipeline_failed'
                    : 'pipeline_completed'
              : 'result_selected',
          status: outcome.wire,
          parserName: 'studio_runtime_v1',
          parserCode: reason.wire,
          payload: StudioRuntimeCallFacts.validate(callFacts) == null
              ? const {}
              : Map.unmodifiable(callFacts),
        ),
      );
      if (result is Future<void>) {
        unawaited(result.catchError((Object _) {}));
      }
    } catch (_) {
      // Diagnostics must not bypass required-tracker failure or fail the turn.
    }
  }
}
