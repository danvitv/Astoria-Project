import 'dart:isolate';
import 'dart:typed_data';
import 'dart:math' as math;

import '../db/app_db.dart';
import '../db/repositories/embedding_repo.dart';
import '../models/chat_message.dart';
import '../utils/cast_helpers.dart';
import 'chat_message_embedding_service.dart';
import 'message_recall_result.dart';
import 'message_recall_selection.dart';

/// Immutable selected-source snapshot, deliberately excluding swipe variants,
/// Studio outputs, attachments and diagnostic graphs from the worker boundary.
class RecallPreparationInput {
  final List<EmbeddingRow> rows;
  final Map<String, ChatMessage>? sources;
  final Set<String>? allowedIds;
  final Set<String> visibleIds;

  RecallPreparationInput({
    required this.rows,
    Map<String, ChatMessage>? sources,
    Set<String>? allowedIds,
    Set<String> visibleIds = const {},
  }) : sources = sources == null
           ? null
           : Map.unmodifiable({
               for (final entry in sources.entries)
                 entry.key: ChatMessage(
                   id: entry.value.id,
                   role: entry.value.role,
                   content: entry.value.content,
                   isHidden: entry.value.isHidden,
                   isTyping: entry.value.isTyping,
                   isError: entry.value.isError,
                 ),
             }),
       allowedIds = allowedIds == null ? null : Set.unmodifiable(allowedIds),
       visibleIds = Set.unmodifiable(visibleIds);
}

class PreparedRecallCandidates {
  final List<MessageRecallCandidate> candidates;
  final Map<String, int> counters;

  const PreparedRecallCandidates(this.candidates, this.counters);
}

Future<PreparedRecallCandidates> prepareRecallInIsolate(
  RecallPreparationInput input,
) => Isolate.run(() => prepareRecallCandidates(input));

/// Source proofs remain identical to the caller-isolate path. The expensive
/// JSON/vector decoding, hashing and attribution now run off the UI isolate.
PreparedRecallCandidates prepareRecallCandidates(RecallPreparationInput input) {
  final counters = <String, int>{
    'rows': input.rows.length,
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
  final candidates = <MessageRecallCandidate>[];
  final sourceOrdinals = input.sources == null
      ? const <String, int>{}
      : {for (final (index, id) in input.sources!.keys.indexed) id: index};
  for (final row in input.rows) {
    if (row.errorJson != null) {
      counters['indexErrors'] = counters['indexErrors']! + 1;
    }
    final metadata = EmbeddingRepo.decodeRowMetadata(row);
    final rawIds = metadata?['messageIds'];
    final sourceIds = rawIds is List
        ? rawIds.whereType<String>().toList(growable: false)
        : const <String>[];
    if ((rawIds is List &&
            (sourceIds.length != rawIds.length ||
                sourceIds.any((id) => id.isEmpty) ||
                sourceIds.toSet().length != sourceIds.length)) ||
        (input.allowedIds != null &&
            (sourceIds.isEmpty ||
                !sourceIds.every(input.allowedIds!.contains)))) {
      counters['sourceRejected'] = counters['sourceRejected']! + 1;
      continue;
    }
    String? groupedText;
    var sources = const <ChatMessage>[];
    if (input.sources != null) {
      final found = sourceIds.map((id) => input.sources![id]).toList();
      if (found.isEmpty ||
          found.any(
            (m) =>
                m == null ||
                m.isHidden ||
                m.isTyping ||
                m.isError ||
                (m.role != 'user' && m.role != 'assistant'),
          ) ||
          found.asMap().entries.any((e) => e.value!.id != sourceIds[e.key])) {
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
    final vectors = EmbeddingRepo.decodeRowVectors(row);
    if (row.vectorsBlob == null ||
        row.vectorsBlob!.isEmpty ||
        vectors == null ||
        vectors.isEmpty ||
        vectors.any((v) => v.isEmpty || v.any((n) => !n.isFinite))) {
      counters['unusableVectors'] = counters['unusableVectors']! + 1;
      continue;
    }
    final texts = <int, String>{};
    final ranges = <int, ({Object? start, Object? end})>{};
    final duplicates = <int>{};
    final chunks = metadata?['chunks'];
    if (chunks is List) {
      for (final chunk in chunks) {
        if (chunk is! Map) continue;
        final index = chunk['index'];
        final text = chunk['text'];
        if (index is! int || text is! String) continue;
        if (texts.containsKey(index)) duplicates.add(index);
        texts[index] = text;
        if (chunk.containsKey('groupStart') || chunk.containsKey('groupEnd')) {
          ranges[index] = (start: chunk['groupStart'], end: chunk['groupEnd']);
        }
      }
    }
    for (var index = 0; index < vectors.length; index++) {
      final text = texts[index];
      if (duplicates.contains(index) ||
          text == null ||
          text.trim().isEmpty ||
          (groupedText != null && !groupedText.contains(text))) {
        counters['invalidText'] = counters['invalidText']! + 1;
        continue;
      }
      var ids = sourceIds;
      var spans = const <MessageRecallSourceSpan>[];
      final range = ranges[index];
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
        ids = [span.messageId];
      } else if (groupedText != null) {
        spans = MessageRecallSelection.recoverSources(
          groupedText,
          text,
          sources,
        );
      }
      if (ids.any(input.visibleIds.contains)) {
        counters['visibleRejected'] = counters['visibleRejected']! + 1;
        continue;
      }
      candidates.add(
        MessageRecallCandidate(
          entryId: row.entryId,
          chunkIndex: index,
          text: text,
          // Keep worker-to-caller-to-worker transfer contiguous, rather than
          // synchronously copying hundreds of thousands of boxed doubles on UI.
          vector: Float64List.fromList(vectors[index]).asUnmodifiableView(),
          messageIds: ids,
          sourceSpans: spans,
          sourceOrdinal: ids
              .map((id) => sourceOrdinals[id] ?? -1)
              .fold(-1, math.max),
        ),
      );
    }
  }
  counters['candidates'] = candidates.length;
  return PreparedRecallCandidates(
    List.unmodifiable(candidates),
    Map.unmodifiable(counters),
  );
}

class RecallRankingInput {
  final List<MessageRecallCandidate> candidates;
  final List<List<double>> queryVectors;
  final double threshold;
  final Map<String, int> counters;
  final String queryText;
  final Set<String> participantAliases;
  const RecallRankingInput(
    this.candidates,
    this.queryVectors,
    this.threshold,
    this.counters, {
    this.queryText = '',
    this.participantAliases = const {},
  });
}

class RankedRecallCandidates {
  final List<MessageRecallMatch> matches;
  final Map<String, int> counters;
  const RankedRecallCandidates(this.matches, this.counters);
}

Future<RankedRecallCandidates> rankRecallInIsolate(RecallRankingInput input) =>
    Isolate.run(() => rankRecallCandidates(input));

RankedRecallCandidates rankRecallCandidates(RecallRankingInput input) {
  final counters = Map<String, int>.of(input.counters);
  final matches = MessageRecallSelection.rank(
    candidates: input.candidates,
    queryVectors: input.queryVectors,
    threshold: input.threshold,
    counters: counters,
    queryText: input.queryText,
    participantAliases: input.participantAliases,
  );
  return RankedRecallCandidates(matches, counters);
}
