import '../transport/chat_transport_request.dart';
import '../context_calculator.dart';
import 'generation_context_planning_facts.dart';
import 'studio_runtime_call_facts.dart';

/// Provider-neutral request and callback facts shared by ordinary and Studio
/// generation. The persisted envelope keeps its historical Studio version key:
/// v1 remains readable, while v2 adds only validated context-planning counts.
abstract final class GenerationRuntimeCallFacts {
  static Map<String, Object?> constructedRequest(
    ChatTransportRequest request,
  ) => StudioRuntimeCallFacts.constructedRequest(request);

  static Map<String, dynamic> payload({
    required Map<String, Object?> request,
    required int elapsedMs,
    required int chunkCount,
    required int? firstChunkMs,
    required int maxChunkGapMs,
    required int contentOffset,
    required int reasoningOffset,
    required String completionReason,
    String? streamTermination,
    String? callbackFinishReason,
    Map<String, Object?>? contextPlanning,
  }) => StudioRuntimeCallFacts.payload(
    request: request,
    elapsedMs: elapsedMs,
    chunkCount: chunkCount,
    firstChunkMs: firstChunkMs,
    maxChunkGapMs: maxChunkGapMs,
    contentOffset: contentOffset,
    reasoningOffset: reasoningOffset,
    completionReason: completionReason,
    streamTermination: streamTermination,
    callbackFinishReason: callbackFinishReason,
    contextPlanning: contextPlanning,
  );

  static Map<String, Object?> contextPlanning({
    required TokenBreakdown breakdown,
    required int contextSize,
    required int outputReserve,
    required String historyTrimMode,
  }) => GenerationContextPlanningFacts.fromBreakdown(
    breakdown: breakdown,
    contextSize: contextSize,
    outputReserve: outputReserve,
    historyTrimMode: historyTrimMode,
  );

  static Map<String, Object?>? fromSavedPayload(Object? raw) =>
      StudioRuntimeCallFacts.fromSavedPayload(raw);

  static String? termination(Object? value) =>
      StudioRuntimeCallFacts.termination(value);

  static String? finishReason(Object? value) =>
      StudioRuntimeCallFacts.finishReason(value);
}
