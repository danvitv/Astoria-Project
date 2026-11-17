import '../transport/chat_transport_request.dart';
import 'studio_runtime_call_facts.dart';

/// Provider-neutral request and callback facts shared by ordinary and Studio
/// generation. The persisted v1 envelope keeps its historical Studio key so
/// existing retained events remain readable; this facade adds no new schema.
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
  );

  static Map<String, Object?>? fromSavedPayload(Object? raw) =>
      StudioRuntimeCallFacts.fromSavedPayload(raw);

  static String? termination(Object? value) =>
      StudioRuntimeCallFacts.termination(value);

  static String? finishReason(Object? value) =>
      StudioRuntimeCallFacts.finishReason(value);
}
