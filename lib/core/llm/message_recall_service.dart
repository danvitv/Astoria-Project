import 'dart:async';

import 'package:dio/dio.dart';

import '../db/repositories/embedding_repo.dart';
import '../models/chat_message.dart';
import '../utils/cast_helpers.dart';
import 'chat_message_embedding_service.dart';
import 'embedding_service.dart';
import 'message_recall_query.dart';
import 'message_recall_result.dart';
import 'message_recall_selection.dart';
import 'transport/llm_capture_context.dart';

export 'message_recall_result.dart';

/// Best-effort recall of exact indexed chat excerpts. The query is a bounded
/// recent-context projection; source evidence remains unchanged. Prompt assembly
/// excludes visible sources and packs these candidates against its token budget.
class MessageRecallService {
  final EmbeddingRepo _repo;
  final EmbeddingService _embeddingService;

  static const double defaultSimilarityThreshold = 0.25;

  MessageRecallService(this._repo, this._embeddingService);

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
      if (!threshold.isFinite) {
        return finish(MessageRecallReason.invalidLimits);
      }
      final rows = await _repo.getBySource('chat_message', sessionId);
      if (aborted()) return finish(MessageRecallReason.cancelled);
      counters['rows'] = rows.length;
      if (rows.isEmpty) return finish(MessageRecallReason.emptyIndex);

      final candidates = <MessageRecallCandidate>[];
      for (final row in rows) {
        if (row.errorJson != null) {
          counters['indexErrors'] = counters['indexErrors']! + 1;
        }
        final metadata = _repo.decodeMetadata(row);
        final rawIds = metadata?['messageIds'];
        final sourceIds = rawIds is List
            ? rawIds.whereType<String>().toList(growable: false)
            : const <String>[];
        // Do not silently drop a malformed ID and then prove only the rest.
        if ((rawIds is List &&
                (sourceIds.length != rawIds.length ||
                    sourceIds.any((id) => id.isEmpty) ||
                    sourceIds.toSet().length != sourceIds.length)) ||
            (allowedSourceMessageIds != null &&
                (sourceIds.isEmpty ||
                    !sourceIds.every(allowedSourceMessageIds.contains)))) {
          counters['sourceRejected'] = counters['sourceRejected']! + 1;
          continue;
        }
        String? groupedText;
        var sources = const <ChatMessage>[];
        if (sourceMessages != null) {
          final found = sourceIds.map((id) => sourceMessages[id]).toList();
          if (found.isEmpty ||
              found.any(
                (message) =>
                    message == null ||
                    message.isHidden ||
                    message.isTyping ||
                    message.isError ||
                    (message.role != 'user' && message.role != 'assistant'),
              )) {
            counters['sourceRejected'] = counters['sourceRejected']! + 1;
            continue;
          }
          if (found.asMap().entries.any(
            (entry) => entry.value!.id != sourceIds[entry.key],
          )) {
            counters['sourceRejected'] = counters['sourceRejected']! + 1;
            continue;
          }
          sources = found.cast<ChatMessage>();
          groupedText = ChatMessageEmbeddingService.formatChunk(sources);
          if (computeHash(groupedText) != row.textHash) {
            counters['hashRejected'] = counters['hashRejected']! + 1;
            continue;
          }
        }
        final vectors = _repo.decodeVectors(row);
        if (!_repo.hasUsableVectors(row) ||
            vectors == null ||
            vectors.isEmpty ||
            vectors.any(
              (vector) =>
                  vector.isEmpty || vector.any((value) => !value.isFinite),
            )) {
          counters['unusableVectors'] = counters['unusableVectors']! + 1;
          continue;
        }
        final chunks = metadata?['chunks'];
        final texts = <int, String>{};
        final ranges = <int, ({Object? start, Object? end})>{};
        final duplicateIndices = <int>{};
        if (chunks is List) {
          for (final chunk in chunks) {
            if (chunk is! Map) continue;
            final index = chunk['index'];
            final text = chunk['text'];
            if (index is! int || text is! String) continue;
            if (texts.containsKey(index)) duplicateIndices.add(index);
            texts[index] = text;
            if (chunk.containsKey('groupStart') ||
                chunk.containsKey('groupEnd')) {
              ranges[index] = (
                start: chunk['groupStart'],
                end: chunk['groupEnd'],
              );
            }
          }
        }
        for (var index = 0; index < vectors.length; index++) {
          final text = texts[index];
          if (duplicateIndices.contains(index) ||
              text == null ||
              text.trim().isEmpty ||
              (groupedText != null && !groupedText.contains(text))) {
            counters['invalidText'] = counters['invalidText']! + 1;
            continue;
          }
          final range = ranges[index];
          var candidateIds = sourceIds;
          var spans = const <MessageRecallSourceSpan>[];
          if (range != null && groupedText != null) {
            final start = range.start;
            final end = range.end;
            if (start is! int ||
                end is! int ||
                start < 0 ||
                end > groupedText.length ||
                end != start + text.length ||
                groupedText.substring(start, end) != text) {
              counters['invalidText'] = counters['invalidText']! + 1;
              continue;
            }
            spans = MessageRecallSelection.recoverSources(
              groupedText,
              text,
              sources,
              groupStart: start,
            );
            // Only exact, hash-verified single-message ranges may narrow a
            // storage group's provenance or its visible-history exclusion.
            if (spans.length != 1) {
              counters['invalidText'] = counters['invalidText']! + 1;
              continue;
            }
            final span = spans.single;
            final source = sources.singleWhere((m) => m.id == span.messageId);
            final contentStart = start + span.excerptStart - span.sourceStart;
            if (start < contentStart - source.role.length - 2 ||
                end > contentStart + source.content.length) {
              counters['invalidText'] = counters['invalidText']! + 1;
              continue;
            }
            candidateIds = [span.messageId];
          } else if (groupedText != null) {
            spans = MessageRecallSelection.recoverSources(
              groupedText,
              text,
              sources,
            );
          }
          if (candidateIds.any(visibleMessageIds.contains)) {
            counters['visibleRejected'] = counters['visibleRejected']! + 1;
            continue;
          }
          candidates.add(
            MessageRecallCandidate(
              entryId: row.entryId,
              chunkIndex: index,
              text: text,
              vector: vectors[index],
              messageIds: candidateIds,
              sourceSpans: spans,
            ),
          );
        }
      }
      counters['candidates'] = candidates.length;
      if (candidates.isEmpty) {
        return finish(MessageRecallReason.noUsableCandidates);
      }
      if (aborted()) return finish(MessageRecallReason.cancelled);

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
      final matches = MessageRecallSelection.rank(
        candidates: candidates,
        queryVectors: queryChunks.map((chunk) => chunk.vector).toList(),
        threshold: threshold,
        counters: counters,
      );
      if (aborted()) return finish(MessageRecallReason.cancelled);
      if (matches.isNotEmpty) {
        return finish(MessageRecallReason.success, matches);
      }
      if (counters['dimensionMismatch'] == candidates.length) {
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
      // Exception strings can contain endpoint URLs or credentials. Only the
      // finite classification is retained in local chat diagnostics.
      return finish(
        aborted() ? MessageRecallReason.cancelled : MessageRecallReason.error,
      );
    }
  }
}
