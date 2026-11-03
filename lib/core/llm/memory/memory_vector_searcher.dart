import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:glaze_flutter/core/state/memory_settings_provider.dart';

import '../../db/app_db.dart';
import '../../db/repositories/embedding_repo.dart';
import '../transport/llm_capture_context.dart';
import '../../models/chat_message.dart';
import '../../models/memory_book.dart';
import '../embedding_service.dart';
import '../memory_retrieval_mode.dart';
import '../retrieval_hints.dart';
import '../retrieval_query_builder.dart';
import '../vector_math.dart';

/// Result of a memory vector search: per-entry similarity scores and the
/// matched chunk texts keyed by entry id.
class MemoryVectorMatchResult {
  final Map<String, double> scores;
  final Map<String, List<String>> chunksByEntryId;

  const MemoryVectorMatchResult({
    this.scores = const {},
    this.chunksByEntryId = const {},
  });
}

/// Caller-owned DB/model values only: no repository, transport or cancel state.
class MemoryVectorSnapshot {
  final String id;
  final String title;
  final String content;
  final List<String> keys;
  final String? storedHash;
  final Uint8List? storedVectors;
  final String? storedMetadata;

  MemoryVectorSnapshot({
    required this.id,
    required this.title,
    required this.content,
    required List<String> keys,
    this.storedHash,
    Uint8List? storedVectors,
    this.storedMetadata,
  }) : keys = List.unmodifiable(keys),
       storedVectors = storedVectors == null
           ? null
           : Uint8List.fromList(storedVectors).asUnmodifiableView();
}

class PreparedMemoryVectorCandidate {
  final String id;
  final List<List<double>> vectors;
  final List<String> chunkTexts;

  PreparedMemoryVectorCandidate({
    required this.id,
    required List<List<double>> vectors,
    required List<String> chunkTexts,
  }) : vectors = List.unmodifiable(
         vectors.map(
           (vector) => Float64List.fromList(vector).asUnmodifiableView(),
         ),
       ),
       chunkTexts = List.unmodifiable(chunkTexts);
}

class MemoryVectorScoringInput {
  final List<PreparedMemoryVectorCandidate> candidates;
  final List<List<double>> queryVectors;
  final double threshold;
  final int topK;

  MemoryVectorScoringInput({
    required List<PreparedMemoryVectorCandidate> candidates,
    required List<List<double>> queryVectors,
    required this.threshold,
    required this.topK,
  }) : candidates = List.unmodifiable(candidates),
       queryVectors = List.unmodifiable(
         queryVectors.map(List<double>.unmodifiable),
       );
}

// Keep Isolate.run in top-level wrappers. A closure created in search() could
// implicitly retain its service/repo/network objects, even when unused.
Future<List<PreparedMemoryVectorCandidate>> prepareMemoryVectorsInIsolate(
  List<MemoryVectorSnapshot> entries,
) {
  final input = List<MemoryVectorSnapshot>.unmodifiable(entries);
  return Isolate.run(() => prepareMemoryVectors(input));
}

Future<MemoryVectorMatchResult> scoreMemoryVectorsInIsolate(
  MemoryVectorScoringInput input,
) => Isolate.run(() => scoreMemoryVectors(input));

/// Hash checking, vector and chunk-metadata decoding execute in the worker.
List<PreparedMemoryVectorCandidate> prepareMemoryVectors(
  List<MemoryVectorSnapshot> entries,
) {
  final candidates = <PreparedMemoryVectorCandidate>[];
  for (final entry in entries) {
    final blob = entry.storedVectors;
    if (blob == null || blob.isEmpty) continue;
    final hints = extractRetrievalHintsFrom(
      label: entry.title,
      keys: entry.keys,
      content: entry.content,
    );
    final fingerprint = jsonEncode({
      'text': entry.content,
      'retrievalHints': hints,
    });
    final hash = sha256.convert(utf8.encode(fingerprint)).toString();
    if (entry.storedHash != hash) continue;
    final vectors = _decodeStoredMemoryVectors(blob);
    if (vectors.isEmpty) continue;
    candidates.add(
      PreparedMemoryVectorCandidate(
        id: entry.id,
        vectors: vectors,
        chunkTexts: _decodeMemoryChunkTexts(
          entry.storedMetadata,
          vectors.length,
        ),
      ),
    );
  }
  return List.unmodifiable(candidates);
}

// Uses the same legacy JSON-byte-array recovery as EmbeddingRepo.decodeVectors.
// No repository instance is needed or permitted in the worker.
List<List<double>> _decodeStoredMemoryVectors(Uint8List stored) {
  final isJsonArray =
      stored.length > 2 &&
      stored.first == 0x5b &&
      stored.last == 0x5d &&
      stored[1] >= 0x30 &&
      stored[1] <= 0x39;
  final bytes = isJsonArray
      ? vectorBytesFromJson(utf8.decode(stored, allowMalformed: true))
      : stored;
  if (bytes == null) return [];
  try {
    return bytesToVectorList(bytes);
  } on RangeError {
    // A truncated later chunk header must not discard other valid entries.
    return [];
  }
}

List<String> _decodeMemoryChunkTexts(String? metadataJson, int vectorCount) {
  if (metadataJson == null) return const [];
  Object? metadata;
  try {
    metadata = jsonDecode(metadataJson);
  } on FormatException {
    return const [];
  }
  if (metadata is! Map || metadata['chunks'] is! List) return const [];
  final texts = List<String>.filled(vectorCount, '');
  for (final chunk in metadata['chunks'] as List) {
    if (chunk is! Map) continue;
    final indexRaw = chunk['index'];
    final textRaw = chunk['text'];
    if (indexRaw is! num || !indexRaw.isFinite || textRaw is! String) continue;
    final index = indexRaw.toInt();
    if (index < 0 || index >= texts.length) continue;
    texts[index] = textRaw;
  }
  return texts;
}

/// Pure multi-chunk scoring and best-chunk/neighbor selection.
MemoryVectorMatchResult scoreMemoryVectors(MemoryVectorScoringInput input) {
  final candidates = [
    for (final candidate in input.candidates)
      VectorCandidate(
        id: candidate.id,
        vectors: [
          for (final vector in candidate.vectors)
            VectorChunk(text: '', vector: vector),
        ],
        metadata: {'chunkTexts': candidate.chunkTexts},
      ),
  ];
  final results = findTopKMulti(
    [
      for (final vector in input.queryVectors)
        VectorChunk(text: '', vector: vector),
    ],
    candidates,
    candidates.length,
    0,
  );
  final scores = <String, double>{};
  final chunksByEntryId = <String, List<String>>{};
  for (final result
      in results
          .where((r) => r.score >= input.threshold)
          .take(input.topK.clamp(1, 50))) {
    scores[result.id] = result.score;
    final chunkTexts = result.metadata['chunkTexts'] as List<String>;
    final bestIndex = result.bestCandidateChunk;
    if (bestIndex == null) continue;
    final matched = <String>[];
    for (final index in [bestIndex, bestIndex - 1, bestIndex + 1]) {
      if (index < 0 || index >= chunkTexts.length) continue;
      final text = chunkTexts[index];
      if (text.trim().isNotEmpty) matched.add(text);
    }
    if (matched.isNotEmpty) {
      chunksByEntryId[result.id] = List.unmodifiable(matched);
    }
  }
  return MemoryVectorMatchResult(
    scores: Map.unmodifiable(scores),
    chunksByEntryId: Map.unmodifiable(chunksByEntryId),
  );
}

/// Performs vector similarity search over memory entries using stored
/// embeddings and a live embedding API call for the retrieval query.
///
/// DB and live embedding calls stay on the caller. CPU work receives only
/// immutable snapshots in a worker, with ownership checked after every await.
class MemoryVectorSearcher {
  final EmbeddingRepo _embeddingRepo;
  final EmbeddingService _embeddingService;

  MemoryVectorSearcher(this._embeddingRepo, this._embeddingService);

  /// Search memory entries by vector similarity.
  ///
  /// - Loads stored embedding rows for `memory_entry` source type.
  /// - Filters entries with usable, hash-matched vectors.
  /// - Builds a retrieval query (legacy or v2) and embeds it.
  /// - Returns top-K entries above [settings.vectorThreshold] with their
  ///   best matching chunk texts (plus immediate neighbors).
  Future<MemoryVectorMatchResult> search(
    List<MemoryEntry> entries,
    List<ChatMessage> history,
    String currentText,
    EmbeddingConfig config,
    MemoryGlobalSettings settings, {
    bool Function()? shouldAbort,
    CancelToken? cancelToken,
  }) async {
    entries = List.unmodifiable(entries);
    history = List.unmodifiable(history);
    bool isAborted() =>
        cancelToken?.isCancelled == true || shouldAbort?.call() == true;
    try {
      if (isAborted()) return const MemoryVectorMatchResult();
      debugPrint('[mem-vec] reading embeddings from DB...');
      final embeddingRows = await _embeddingRepo.getBySourceType(
        'memory_entry',
      );
      if (isAborted()) return const MemoryVectorMatchResult();
      final embeddingMap = <String, EmbeddingRow>{};
      for (final row in embeddingRows) {
        embeddingMap[row.entryId] = row;
      }
      debugPrint('[mem-vec] loaded ${embeddingRows.length} embedding rows');

      final candidates = await prepareMemoryVectorsInIsolate([
        for (final entry in entries)
          MemoryVectorSnapshot(
            id: entry.id,
            title: entry.title,
            content: entry.content,
            keys: entry.keys,
            storedHash: embeddingMap[entry.id]?.textHash,
            storedVectors: embeddingMap[entry.id]?.vectorsBlob,
            storedMetadata: embeddingMap[entry.id]?.retrievalHintsJson,
          ),
      ]);
      if (isAborted()) return const MemoryVectorMatchResult();
      debugPrint('[mem-vec] valid candidates: ${candidates.length}');

      if (candidates.isEmpty) return const MemoryVectorMatchResult();

      final queryText =
          MemoryRetrievalMode.fromValue(settings.memoryMode).isLegacy
          ? legacyVectorQuery(history, currentText)
          : RetrievalQueryBuilder.build(
              currentText: currentText,
              history: history,
              includeAssistant: settings.queryIncludeAssistant,
              recentTurns: settings.queryRecentTurns,
              maxChars: settings.queryMaxChars,
            );
      if (queryText.isEmpty) return const MemoryVectorMatchResult();
      if (isAborted()) return const MemoryVectorMatchResult();

      debugPrint(
        '[mem-vec] calling embedding API (endpoint=${config.endpoint})...',
      );
      final queryChunks = await _embeddingService
          .getEmbeddingsWithChunks(
            [queryText],
            config,
            cancelToken: cancelToken,
            captureContext: const LlmCaptureContext(stage: 'embedding.memory'),
          )
          .timeout(const Duration(seconds: 30), onTimeout: () => []);
      if (isAborted()) {
        return const MemoryVectorMatchResult();
      }
      debugPrint(
        '[mem-vec] embedding API returned ${queryChunks.length} chunks',
      );
      if (queryChunks.isEmpty) return const MemoryVectorMatchResult();

      final result = await scoreMemoryVectorsInIsolate(
        MemoryVectorScoringInput(
          candidates: candidates,
          queryVectors: [for (final chunk in queryChunks) chunk.vector],
          threshold: settings.vectorThreshold,
          topK: settings.maxInjectedEntries,
        ),
      );
      if (isAborted()) return const MemoryVectorMatchResult();
      return result;
    } catch (_) {
      return const MemoryVectorMatchResult();
    }
  }

  /// Decode the per-chunk text metadata stored alongside vectors.
  List<String> decodeMemoryChunkTexts(EmbeddingRow row, int vectorCount) {
    return _decodeMemoryChunkTexts(row.retrievalHintsJson, vectorCount);
  }

  /// Legacy vector query: current text + recent user turns up to 1500 chars.
  static String legacyVectorQuery(
    List<ChatMessage> history,
    String currentText,
  ) {
    final parts = <String>[];
    if (currentText.trim().isNotEmpty) parts.add(currentText.trim());
    var chars = parts.fold<int>(0, (sum, part) => sum + part.length);
    for (int i = history.length - 1; i >= 0; i--) {
      final msg = history[i];
      if (msg.isHidden || msg.isTyping || msg.role != 'user') continue;
      final text = msg.content.trim();
      if (text.isEmpty || text == currentText.trim()) continue;
      if (chars + text.length > 1500) break;
      parts.add(text);
      chars += text.length;
    }
    return parts.join('\n').trim();
  }
}
