import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import '../models/character.dart';
import '../models/lorebook.dart';
import '../db/app_db.dart';
import '../db/repositories/embedding_repo.dart';
import '../db/repositories/session_lorebook_evolution_repo.dart';
import '../utils/cast_helpers.dart';
import 'package:dio/dio.dart';
import 'embedding_service.dart';
import 'transport/llm_capture_context.dart';
import 'embedding_types.dart';
import 'lorebook_activation.dart';
import 'lorebook_embedding_service.dart';
import 'lorebook_embedding_text.dart';
import 'vector_math.dart';

class VectorSearchResult {
  final String entryId;
  final double score;
  final String lorebookId;

  const VectorSearchResult({
    required this.entryId,
    required this.score,
    required this.lorebookId,
  });
}

class LorebookVectorSearch {
  final EmbeddingRepo _repo;
  final EmbeddingService _embeddingService;

  LorebookVectorSearch(this._repo, this._embeddingService);

  Future<List<VectorSearchResult>> search(
    List<ChatMessageForSearch> history,
    String currentText,
    List<Lorebook> lorebooks,
    LorebookGlobalSettings settings,
    EmbeddingConfig config, {
    String? charWorld,
    Character? character,
    LorebookActivations? activations,
    String? chatId,
    Set<SessionLorebookTarget> sessionOverlayTargets = const {},
    int? overrideTopK,
    CancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled == true) return [];
    if (settings.searchType == 'keyword') return [];

    final activeLorebooks = activeLorebooksFor(
      lorebooks: lorebooks,
      charId: character?.id,
      charGroupId: character?.variantGroupId,
      charWorld: charWorld,
      chatId: chatId,
      activations: activations,
    );

    activeLorebooks.removeWhere((lb) {
      final lbSettings = lb.settings;
      return lbSettings != null && !lbSettings.vectorSearchEnabled;
    });

    var effectiveThreshold = settings.vectorThreshold;
    var effectiveTopK = overrideTopK ?? settings.vectorTopK;
    int? configuredScanDepth;
    for (final lb in activeLorebooks) {
      final lbSettings = lb.settings;
      if (lbSettings != null) {
        if (lbSettings.vectorThreshold < effectiveThreshold) {
          effectiveThreshold = lbSettings.vectorThreshold;
        }
        if (lbSettings.vectorTopK > effectiveTopK) {
          effectiveTopK = lbSettings.vectorTopK;
        }
        if (configuredScanDepth == null ||
            lbSettings.vectorScanDepth > configuredScanDepth) {
          configuredScanDepth = lbSettings.vectorScanDepth;
        }
      }
    }
    final effectiveScanDepth = configuredScanDepth ?? 5;

    final vectorEntries = <(LorebookEntry, String)>[];
    // Semantic fallback pool for keyless entries (Marinara analog). Entries
    // with no keys AND no secondaryKeys cannot activate via keyword scan; this
    // fallback activates them via cosine similarity against the current chat
    // text, with a lower threshold (default 0.3) and a smaller topK (default
    // 3) so they cannot flood the prompt. lorebookVectorPoolFor splits the
    // two pools — the indexer asks the same function, so an entry the search
    // expects a vector for is one the indexer actually embedded.
    final fallbackEntries = <(LorebookEntry, String)>[];
    for (final lb in activeLorebooks) {
      final vectorizeAll = lb.settings?.vectorizeAllEntries ?? false;
      for (final entry in lb.entries) {
        if (_isFilteredByCharacter(entry, character)) continue;
        switch (lorebookVectorPoolFor(entry, vectorizeAll: vectorizeAll)) {
          case LorebookVectorPool.main:
            vectorEntries.add((entry, lb.id));
          case LorebookVectorPool.fallback:
            fallbackEntries.add((entry, lb.id));
          case LorebookVectorPool.none:
            break;
        }
      }
    }

    if (vectorEntries.isEmpty && fallbackEntries.isEmpty) return [];

    final relevantLorebookIds = {
      for (final (_, lorebookId) in vectorEntries) lorebookId,
      for (final (_, lorebookId) in fallbackEntries) lorebookId,
    };
    if (cancelToken?.isCancelled == true) return [];
    final rowGroups = await Future.wait([
      _repo.getBySourceIds('lorebook_entry', relevantLorebookIds),
      if (chatId != null && sessionOverlayTargets.isNotEmpty)
        _repo.getBySource('session_lorebook_entry', chatId)
      else
        Future.value(const <EmbeddingRow>[]),
    ]);
    if (cancelToken?.isCancelled == true) return [];

    final embeddingMap = <String, EmbeddingRow>{};
    for (final row in rowGroups.expand((rows) => rows)) {
      embeddingMap[row.entryId] = row;
    }
    final embeddingTargets = <String, String?>{};
    for (final lb in lorebooks) {
      embeddingTargets.putIfAbsent(lb.id, () => lb.settings?.embeddingTarget);
    }

    _CandidateInput? candidateInput(LorebookEntry entry, String lbId) {
      final namespacedId = _embeddingId(
        chatId: chatId,
        lorebookId: lbId,
        entryId: entry.id,
        sessionOverlayTargets: sessionOverlayTargets,
      );
      final row = embeddingMap[namespacedId];
      if (row == null || row.vectorsBlob == null) return null;
      return _CandidateInput(
        entry: entry,
        lorebookId: lbId,
        embeddingTarget: embeddingTargets[lbId],
        textHash: row.textHash,
        vectorsBlob: row.vectorsBlob!.asUnmodifiableView(),
        retrievalHintsJson: row.retrievalHintsJson,
      );
    }

    final preparationInput = _CandidatePreparationInput(
      main: List.unmodifiable([
        for (final (entry, lbId) in vectorEntries) ?candidateInput(entry, lbId),
      ]),
      fallback: List.unmodifiable([
        for (final (entry, lbId) in fallbackEntries)
          ?candidateInput(entry, lbId),
      ]),
      signature: embeddingModelSignature(config),
    );
    if (cancelToken?.isCancelled == true) return [];
    final prepared = await _prepareCandidatesInBackground(preparationInput);
    if (cancelToken?.isCancelled == true) return [];
    final candidates = prepared.main;
    final fallbackCandidates = prepared.fallback;

    if (candidates.isEmpty && fallbackCandidates.isEmpty) return [];

    final recentHistory = effectiveScanDepth <= 0
        ? const <ChatMessageForSearch>[]
        : history
              .skip(
                (history.length - effectiveScanDepth).clamp(0, history.length),
              )
              .toList();
    final focusedQuery = _buildFocusedQuery(
      recentHistory,
      currentText,
      config.maxChunkTokens,
    );
    final fallbackQuery = _buildFallbackQuery(
      recentHistory,
      currentText,
      config.maxChunkTokens,
    );

    final mainScores = <List<VectorSearchResult>>[];
    var fallbackScores = const <VectorSearchResult>[];

    Future<List<VectorChunk>> embedQuery(String query) async {
      if (cancelToken?.isCancelled == true) return [];
      final List<EmbeddingChunk> chunks;
      try {
        chunks = await _embeddingService.getEmbeddingsWithChunks(
          [query],
          config,
          cancelToken: cancelToken,
          captureContext: LlmCaptureContext(
            stage: 'embedding.lorebook',
            sessionId: chatId,
          ),
        );
      } catch (_) {
        if (cancelToken?.isCancelled == true) return [];
        rethrow;
      }
      if (cancelToken?.isCancelled == true) return [];
      return List.unmodifiable([
        for (final chunk in chunks)
          VectorChunk(
            text: chunk.text,
            vector: List.unmodifiable(chunk.vector),
          ),
      ]);
    }

    final focusedChunks = focusedQuery.isNotEmpty
        ? embedQuery(focusedQuery)
        : null;

    Future<void> searchPool(
      List<VectorCandidate> pool,
      String query,
      Future<List<VectorChunk>>? sharedChunks,
    ) async {
      if (cancelToken?.isCancelled == true) return;
      if (query.isEmpty || pool.isEmpty) return;
      final vecChunks = await (sharedChunks ?? embedQuery(query));
      if (cancelToken?.isCancelled == true) return;
      // Previously scoring was synchronous after the embedding await. Reserve
      // that arrival order so different worker runtimes cannot change score ties.
      final arrivalIndex = mainScores.length;
      mainScores.add(const []);
      final results = await _scorePoolInBackground(
        _PoolScoringInput(pool, vecChunks, query, hybridBoost: true),
      );
      if (cancelToken?.isCancelled == true) return;
      mainScores[arrivalIndex] = results;
    }

    // Main vector pool (vectorSearch=true entries) — both focused and
    // fallback queries if available. Run in parallel with a 1s stagger
    // to avoid bursting the embedding endpoint with simultaneous requests.
    final mainFutures = <Future<void>>[];
    if (focusedChunks != null) {
      // Always drain the shared request, even if a synchronous transport hook
      // cancels before either pool can await it.
      mainFutures.add(focusedChunks.then<void>((_) {}));
    }
    if (focusedQuery.isNotEmpty) {
      mainFutures.add(searchPool(candidates, focusedQuery, focusedChunks));
    }
    if (fallbackQuery.isNotEmpty && fallbackQuery != focusedQuery) {
      mainFutures.add(
        Future.delayed(
          const Duration(seconds: 1),
          () => searchPool(candidates, fallbackQuery, null),
        ),
      );
    }
    // Keyless fallback reuses the focused query's in-flight embedding request.
    // Starting another identical request here bypasses the cache until the
    // first one completes and can trigger rate limits on slower endpoints.
    if (focusedChunks != null && fallbackCandidates.isNotEmpty) {
      mainFutures.add(() async {
        if (cancelToken?.isCancelled == true) return;
        final vecChunks = await focusedChunks;
        if (cancelToken?.isCancelled == true) return;
        final results = await _scorePoolInBackground(
          _PoolScoringInput(
            fallbackCandidates,
            vecChunks,
            focusedQuery,
            hybridBoost: false,
          ),
        );
        if (cancelToken?.isCancelled == true) return;
        fallbackScores = results;
      }());
    }
    await Future.wait(mainFutures);
    if (cancelToken?.isCancelled == true) return [];
    final results = await _mergeScoresInBackground(
      _ScoreMergeInput(
        main: List.unmodifiable(mainScores),
        fallback: fallbackScores,
        threshold: effectiveThreshold,
        topK: effectiveTopK,
        fallbackThreshold: settings.fallbackThreshold,
        fallbackTopK: settings.fallbackTopK,
      ),
    );
    if (cancelToken?.isCancelled == true) return [];
    return results.toList();
  }

  String _buildFocusedQuery(
    List<ChatMessageForSearch> history,
    String currentText,
    int maxChunkTokens,
  ) {
    final userMessages = history
        .where((m) => m.role == 'user')
        .toList()
        .reversed;
    final maxChars = (maxChunkTokens * 2).clamp(0, 1024) * 4;
    final buffer = StringBuffer();

    buffer.write(currentText);

    var skippedCurrent = false;
    for (final msg in userMessages) {
      if (!skippedCurrent && msg.content == currentText) {
        skippedCurrent = true;
        continue;
      }
      final toAdd = '\n${msg.content}';
      if (buffer.length + toAdd.length > maxChars.clamp(0, 6000)) break;
      buffer.write(toAdd);
    }

    return _sanitizeQuery(buffer.toString());
  }

  String _buildFallbackQuery(
    List<ChatMessageForSearch> history,
    String currentText,
    int maxChunkTokens,
  ) {
    final maxChars = (maxChunkTokens * 3).clamp(0, 1536) * 4;
    final buffer = StringBuffer();

    buffer.write(currentText);

    var skippedCurrent = false;
    for (final msg in history.reversed) {
      if (!skippedCurrent && msg.content == currentText) {
        skippedCurrent = true;
        continue;
      }
      final toAdd = '\n${msg.content}';
      if (buffer.length + toAdd.length > maxChars.clamp(0, 10000)) break;
      buffer.write(toAdd);
    }

    return _sanitizeQuery(buffer.toString());
  }

  String _sanitizeQuery(String text) {
    var clean = text;
    clean = clean.replaceAll(RegExp(r'<[^>]+>'), '');
    clean = clean.replaceAll(RegExp(r'\(OOC:.*?\)', caseSensitive: false), '');
    clean = clean.replaceAll(RegExp(r'data:image/[^;]+;base64,[^\s]+'), '');
    return clean.trim();
  }

  static double _applyHybridBoost(
    double rawScore,
    LorebookEntry entry,
    List<String> hints,
    String queryText,
  ) {
    double boost = 0;
    final queryLower = queryText.toLowerCase();

    final nameInQuery =
        entry.comment.isNotEmpty &&
        queryLower.contains(entry.comment.toLowerCase());
    if (nameInQuery) {
      boost += 0.18;
    }

    int keyOverlap = 0;
    for (final key in entry.keys) {
      if (queryLower.contains(key.toLowerCase())) {
        keyOverlap++;
      }
    }
    boost += (keyOverlap * 0.04).clamp(0, 0.12);

    int hintOverlap = 0;
    final queryTokens = _tokenize(queryLower);
    for (final hint in hints) {
      final hintTokens = _tokenize(hint.toLowerCase());
      for (final ht in hintTokens) {
        if (queryTokens.contains(ht)) {
          hintOverlap++;
        }
      }
    }
    boost += (hintOverlap * 0.025).clamp(0, 0.10);

    return (rawScore + boost).clamp(0, 1);
  }

  static List<String> _tokenize(String text) {
    return text
        .split(RegExp(r'[\s,.;:!?]+'))
        .where((t) => t.length > 2)
        .toList();
  }

  String _embeddingId({
    required String? chatId,
    required String lorebookId,
    required String entryId,
    required Set<SessionLorebookTarget> sessionOverlayTargets,
  }) {
    final isOverlay = sessionOverlayTargets.contains((
      lorebookId: lorebookId,
      entryId: entryId,
    ));
    if (isOverlay) {
      return '$chatId:$lorebookId:$entryId';
    }
    return '${lorebookId}_$entryId';
  }

  bool _isFilteredByCharacter(LorebookEntry entry, Character? character) {
    if (character == null) return false;
    final filter = entry.characterFilter;
    if (filter == null) return false;
    if (filter.names.isEmpty) return false;
    final charName = character.name.toLowerCase();
    final isInCategory = filter.names.any(
      (n) => charName.contains(n.toLowerCase()),
    );
    if (filter.isExclude && isInCategory) return true;
    if (!filter.isExclude && !isInCategory) return true;
    return false;
  }
}

// These inputs contain data only. Keep Isolate.run closures in top-level
// wrappers: a closure created inside search can implicitly retain its service,
// repository, Dio/capture state or cancellation token even when not used.
class _CandidateInput {
  final LorebookEntry entry;
  final String lorebookId;
  final String? embeddingTarget;
  final String? textHash;
  final Uint8List vectorsBlob;
  final String? retrievalHintsJson;

  const _CandidateInput({
    required this.entry,
    required this.lorebookId,
    required this.embeddingTarget,
    required this.textHash,
    required this.vectorsBlob,
    required this.retrievalHintsJson,
  });
}

class _CandidatePreparationInput {
  final List<_CandidateInput> main;
  final List<_CandidateInput> fallback;
  final String signature;

  const _CandidatePreparationInput({
    required this.main,
    required this.fallback,
    required this.signature,
  });
}

class _PreparedPools {
  final List<VectorCandidate> main;
  final List<VectorCandidate> fallback;

  const _PreparedPools(this.main, this.fallback);
}

Future<_PreparedPools> _prepareCandidatesInBackground(
  _CandidatePreparationInput input,
) => Isolate.run(() => _prepareCandidates(input));

_PreparedPools _prepareCandidates(_CandidatePreparationInput input) {
  List<VectorCandidate> preparePool(List<_CandidateInput> pool) {
    final candidates = <VectorCandidate>[];
    for (final candidate in pool) {
      final entry = candidate.entry;
      final text = lorebookEmbeddingText(entry, candidate.embeddingTarget);
      final fingerprint = LorebookEmbeddingService.buildEmbeddingFingerprint(
        entry,
        text,
      );
      if (candidate.textHash != computeHash(fingerprint)) continue;

      Object? metadata;
      try {
        final json = candidate.retrievalHintsJson;
        metadata = json == null ? null : jsonDecode(json);
      } on FormatException {
        metadata = null;
      }
      if (!embeddingSignatureMatches(
        metadata is Map ? metadata['embeddingSignature'] : null,
        input.signature,
      )) {
        continue;
      }

      // Match EmbeddingRepo.decodeVectors, including the historical backup
      // TEXT-as-BLOB repair. The shared decoder validates sizes before allocation.
      final stored = candidate.vectorsBlob;
      final isJsonArray =
          stored.length > 2 &&
          stored.first == 0x5b &&
          stored.last == 0x5d &&
          stored[1] >= 0x30 &&
          stored[1] <= 0x39;
      final bytes = isJsonArray
          ? vectorBytesFromJson(utf8.decode(stored, allowMalformed: true))
          : stored;
      final vectors = bytes == null
          ? <List<double>>[]
          : bytesToVectorList(bytes);
      if (vectors.isEmpty) continue;

      final hints = metadata is Map ? metadata['hints'] : null;
      candidates.add(
        VectorCandidate(
          id: entry.id,
          vectors: List.unmodifiable([
            for (final vector in vectors)
              VectorChunk(
                text: '',
                vector: Float64List.fromList(vector).asUnmodifiableView(),
              ),
          ]),
          metadata: Map.unmodifiable({
            'entry': entry,
            'lorebookId': candidate.lorebookId,
            'hints': hints is List
                ? List<Object?>.unmodifiable(hints).cast<String>()
                : const <String>[],
          }),
        ),
      );
    }
    return List.unmodifiable(candidates);
  }

  return _PreparedPools(preparePool(input.main), preparePool(input.fallback));
}

class _PoolScoringInput {
  final List<VectorCandidate> pool;
  final List<VectorChunk> queryChunks;
  final String query;
  final bool hybridBoost;

  const _PoolScoringInput(
    this.pool,
    this.queryChunks,
    this.query, {
    required this.hybridBoost,
  });
}

Future<List<VectorSearchResult>> _scorePoolInBackground(
  _PoolScoringInput input,
) => Isolate.run(() => _scorePool(input));

List<VectorSearchResult> _scorePool(_PoolScoringInput input) {
  final results = findTopKMulti(
    input.queryChunks,
    input.pool,
    input.pool.length,
    0,
  );
  return List.unmodifiable([
    for (final result in results)
      VectorSearchResult(
        entryId: result.id,
        lorebookId: result.metadata['lorebookId'] as String,
        score: input.hybridBoost
            ? LorebookVectorSearch._applyHybridBoost(
                result.score,
                result.metadata['entry'] as LorebookEntry,
                result.metadata['hints'] as List<String>,
                input.query,
              )
            : result.score,
      ),
  ]);
}

class _ScoreMergeInput {
  final List<List<VectorSearchResult>> main;
  final List<VectorSearchResult> fallback;
  final double threshold;
  final int topK;
  final double fallbackThreshold;
  final int fallbackTopK;

  const _ScoreMergeInput({
    required this.main,
    required this.fallback,
    required this.threshold,
    required this.topK,
    required this.fallbackThreshold,
    required this.fallbackTopK,
  });
}

Future<List<VectorSearchResult>> _mergeScoresInBackground(
  _ScoreMergeInput input,
) => Isolate.run(() => _mergeScores(input));

List<VectorSearchResult> _mergeScores(_ScoreMergeInput input) {
  final allResults = <String, double>{};
  final allLorebookIds = <String, String>{};
  for (final pool in input.main) {
    for (final result in pool) {
      final id = '${result.lorebookId}_${result.entryId}';
      if (allResults[id] == null || result.score > allResults[id]!) {
        allResults[id] = result.score;
      }
      allLorebookIds[id] = result.lorebookId;
    }
  }
  final sorted = allResults.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final mainResults = sorted
      .where((e) => e.value >= input.threshold)
      .take(input.topK)
      .map(
        (e) => VectorSearchResult(
          entryId: e.key.substring((allLorebookIds[e.key]?.length ?? -1) + 1),
          score: e.value,
          lorebookId: allLorebookIds[e.key] ?? '',
        ),
      )
      .toList();

  final fallbackResults = <String, double>{};
  final fallbackLorebookIds = <String, String>{};
  for (final result in input.fallback) {
    if (!(result.score >= input.fallbackThreshold)) continue;
    final id = '${result.lorebookId}_${result.entryId}';
    fallbackResults[id] = result.score;
    fallbackLorebookIds[id] = result.lorebookId;
  }
  final fallbackSorted = fallbackResults.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final mainIds = mainResults
      .map((r) => '${r.lorebookId}_${r.entryId}')
      .toSet();
  final fallbackFinal = fallbackSorted
      .where((e) => !mainIds.contains(e.key))
      .take(input.fallbackTopK)
      .map(
        (e) => VectorSearchResult(
          entryId: e.key.substring(
            (fallbackLorebookIds[e.key]?.length ?? -1) + 1,
          ),
          score: e.value,
          lorebookId: fallbackLorebookIds[e.key] ?? '',
        ),
      );
  return List.unmodifiable([...mainResults, ...fallbackFinal]);
}
