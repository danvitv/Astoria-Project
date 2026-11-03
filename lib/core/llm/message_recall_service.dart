import 'dart:async';

import 'package:dio/dio.dart';

import '../db/repositories/embedding_repo.dart';
import '../models/chat_message.dart';
import 'embedding_service.dart';
import 'message_recall_compute.dart';
import 'message_recall_query.dart';
import 'message_recall_result.dart';
import 'transport/llm_capture_context.dart';

export 'message_recall_result.dart';

/// Best-effort exact-source recall. Database/network calls stay on the owning
/// isolate; source validation, vector decoding and ranking run in workers.
/// Prompt assembly still packs all ranked candidates after its visible cutoff.
class MessageRecallService {
  final EmbeddingRepo _repo;
  final EmbeddingService _embeddingService;
  final Future<PreparedRecallCandidates> Function(RecallPreparationInput)
  prepare;
  final Future<RankedRecallCandidates> Function(RecallRankingInput) rank;

  static const double defaultSimilarityThreshold = 0.25;

  MessageRecallService(
    this._repo,
    this._embeddingService, {
    this.prepare = prepareRecallInIsolate,
    this.rank = rankRecallInIsolate,
  });

  Future<MessageRecallResult> recall({
    required String sessionId,
    required String currentText,
    required EmbeddingConfig config,
    List<ChatMessage> recentHistory = const [],
    double threshold = defaultSimilarityThreshold,
    Set<String> visibleMessageIds = const {},
    Set<String>? allowedSourceMessageIds,
    Map<String, ChatMessage>? sourceMessages,
    CancelToken? cancelToken,
    bool Function()? shouldAbort,
  }) async {
    final query = MessageRecallQuery.build(
      currentText: currentText,
      history: recentHistory,
    );
    final counters = <String, int>{
      'rows': 0,
      'sourceRejected': 0,
      'visibleRejected': 0,
      'hashRejected': 0,
      'unusableVectors': 0,
      'indexErrors': 0,
      'invalidText': 0,
      'candidates': 0,
      'dimensionMismatch': 0,
      'aboveThreshold': 0,
    };
    MessageRecallResult finish(
      MessageRecallReason reason, [
      List<MessageRecallMatch> matches = const [],
    ]) => MessageRecallResult(
      matches: List.unmodifiable(matches),
      reason: reason,
      query: query,
      counters: Map.unmodifiable({...counters, 'ranked': matches.length}),
    );
    bool aborted() =>
        cancelToken?.isCancelled == true || shouldAbort?.call() == true;

    try {
      if (aborted()) return finish(MessageRecallReason.cancelled);
      if (config.endpoint.isEmpty) {
        return finish(MessageRecallReason.endpointNotConfigured);
      }
      if (query.isEmpty) return finish(MessageRecallReason.emptyQuery);
      if (!threshold.isFinite) return finish(MessageRecallReason.invalidLimits);
      final rows = await _repo.getBySource('chat_message', sessionId);
      if (aborted()) return finish(MessageRecallReason.cancelled);
      counters['rows'] = rows.length;
      if (rows.isEmpty) return finish(MessageRecallReason.emptyIndex);
      final prepared = await prepare(
        RecallPreparationInput(
          rows: rows,
          sources: sourceMessages,
          allowedIds: allowedSourceMessageIds,
          visibleIds: visibleMessageIds,
        ),
      );
      if (aborted()) return finish(MessageRecallReason.cancelled);
      counters.addAll(prepared.counters);
      if (prepared.candidates.isEmpty) {
        return finish(MessageRecallReason.noUsableCandidates);
      }

      final queryChunks = await _embeddingService
          .getEmbeddingsWithChunks(
            [query],
            config,
            cancelToken: cancelToken,
            captureContext: LlmCaptureContext(
              stage: 'embedding.recall',
              sessionId: sessionId,
            ),
          )
          .timeout(const Duration(seconds: 30));
      if (aborted()) return finish(MessageRecallReason.cancelled);
      if (queryChunks.isEmpty ||
          queryChunks.any(
            (chunk) =>
                chunk.vector.isEmpty ||
                chunk.vector.any((value) => !value.isFinite),
          )) {
        return finish(MessageRecallReason.embeddingEmpty);
      }
      final queryDim = queryChunks.first.vector.length;
      if (queryChunks.any((chunk) => chunk.vector.length != queryDim)) {
        return finish(MessageRecallReason.dimensionMismatch);
      }
      final ranked = await rank(
        RecallRankingInput(
          prepared.candidates,
          queryChunks.map((chunk) => chunk.vector).toList(),
          threshold,
          counters,
        ),
      );
      // Worker completion never owns publication: cancellation/source ownership
      // may change while its synchronous CPU job is executing.
      if (aborted()) return finish(MessageRecallReason.cancelled);
      counters.addAll(ranked.counters);
      if (ranked.matches.isNotEmpty) {
        return finish(MessageRecallReason.success, ranked.matches);
      }
      if (counters['dimensionMismatch'] == prepared.candidates.length) {
        return finish(MessageRecallReason.dimensionMismatch);
      }
      return finish(MessageRecallReason.belowThreshold);
    } on TimeoutException {
      return finish(
        aborted() ? MessageRecallReason.cancelled : MessageRecallReason.timeout,
      );
    } on DioException catch (error) {
      return finish(
        aborted() || error.type == DioExceptionType.cancel
            ? MessageRecallReason.cancelled
            : MessageRecallReason.error,
      );
    } catch (_) {
      // Never retain exception strings containing endpoints or credentials.
      return finish(
        aborted() ? MessageRecallReason.cancelled : MessageRecallReason.error,
      );
    }
  }
}
