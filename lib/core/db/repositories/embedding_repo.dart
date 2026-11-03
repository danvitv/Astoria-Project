import 'dart:convert';

import 'package:drift/drift.dart';

import '../app_db.dart';
import '../tables.dart';
import '../../llm/embedding_service.dart';
import '../../llm/vector_math.dart';
import '../../utils/time_helpers.dart';
import '../../application/sync_repo_interfaces.dart';

part 'embedding_repo.g.dart';

@DriftAccessor(tables: [Embeddings])
class EmbeddingRepo extends DatabaseAccessor<AppDatabase>
    with _$EmbeddingRepoMixin
    implements SyncEmbeddingStore {
  EmbeddingRepo(super.db);

  Future<EmbeddingRow?> getByEntryId(String entryId) {
    return (select(
      embeddings,
    )..where((e) => e.entryId.equals(entryId))).getSingleOrNull();
  }

  Future<List<EmbeddingRow>> getAll() {
    return select(embeddings).get();
  }

  Future<EmbeddingStaleStats> getStaleStats(String currentSignature) async {
    final rows = await getAll();
    var stale = 0;
    var missingMetadata = 0;
    final bySource = <String, int>{};

    for (final row in rows) {
      final metadata = decodeMetadata(row);
      final signature = metadata?['embeddingSignature'];
      final isMissing = signature is! String || signature.isEmpty;
      final isStale =
          isMissing || !embeddingSignatureMatches(signature, currentSignature);
      if (!isStale) continue;
      stale++;
      if (isMissing) missingMetadata++;
      bySource[row.sourceType] = (bySource[row.sourceType] ?? 0) + 1;
    }

    return EmbeddingStaleStats(
      total: rows.length,
      stale: stale,
      missingMetadata: missingMetadata,
      bySource: bySource,
    );
  }

  Future<List<EmbeddingRow>> getBySourceType(String sourceType) {
    return (select(
      embeddings,
    )..where((e) => e.sourceType.equals(sourceType))).get();
  }

  Future<List<EmbeddingRow>> getBySourceId(String sourceId) {
    return (select(
      embeddings,
    )..where((e) => e.sourceId.equals(sourceId))).get();
  }

  Future<List<EmbeddingRow>> getBySource(String sourceType, String sourceId) {
    return (select(embeddings)
          ..where((e) => e.sourceType.equals(sourceType))
          ..where((e) => e.sourceId.equals(sourceId)))
        .get();
  }

  Future<List<EmbeddingRow>> getBySourceIds(
    String sourceType,
    Iterable<String> sourceIds,
  ) {
    final ids = sourceIds.toSet();
    if (ids.isEmpty) return Future.value(const []);
    return (select(embeddings)
          ..where((e) => e.sourceType.equals(sourceType))
          ..where((e) => e.sourceId.isIn(ids)))
        .get();
  }

  Future<void> put(EmbeddingsCompanion entry) {
    return into(embeddings).insertOnConflictUpdate(entry);
  }

  Future<void> deleteByEntryId(String entryId) {
    return (delete(embeddings)..where((e) => e.entryId.equals(entryId))).go();
  }

  Future<void> deleteBySourceType(String sourceType) {
    return (delete(
      embeddings,
    )..where((e) => e.sourceType.equals(sourceType))).go();
  }

  @override
  Future<void> deleteBySourceId(String sourceId) {
    return (delete(embeddings)..where((e) => e.sourceId.equals(sourceId))).go();
  }

  Future<void> deleteBySource(String sourceType, String sourceId) {
    return (delete(embeddings)
          ..where((e) => e.sourceType.equals(sourceType))
          ..where((e) => e.sourceId.equals(sourceId)))
        .go();
  }

  Future<void> deleteBySourceAndEntryIds(
    String sourceType,
    String sourceId,
    Iterable<String> entryIds,
  ) {
    final ids = entryIds.toSet();
    if (ids.isEmpty) return Future.value();
    return (delete(embeddings)
          ..where((e) => e.sourceType.equals(sourceType))
          ..where((e) => e.sourceId.equals(sourceId))
          ..where((e) => e.entryId.isIn(ids)))
        .go();
  }

  /// Invalidate only groups containing changed/deleted source messages. Chunk
  /// ordinals are not source identities: unaffected groups remain searchable
  /// before the next post-generation indexing pass. Legacy rows without exact
  /// source IDs cannot be proved unaffected and are retired conservatively.
  Future<void> invalidateChatMessageGroupsForMessages(
    String sessionId,
    Set<String> messageIds,
  ) => transaction(() async {
    if (messageIds.isEmpty) return;
    final rows = await getBySource('chat_message', sessionId);
    final invalidated = <String>[];
    for (final row in rows) {
      final ids = decodeMetadata(row)?['messageIds'];
      final hasExactSources =
          ids is List &&
          ids.isNotEmpty &&
          ids.every((id) => id is String && id.isNotEmpty) &&
          ids.toSet().length == ids.length;
      if (!hasExactSources || ids.any(messageIds.contains)) {
        invalidated.add(row.entryId);
      }
    }
    await deleteBySourceAndEntryIds('chat_message', sessionId, invalidated);
  });

  Future<void> putEmbeddingVector({
    required String entryId,
    required String sourceType,
    String? sourceId,
    required List<List<double>> vectors,
    required String textHash,
    List<String>? retrievalHints,
    Map<String, dynamic>? retrievalMetadata,
  }) async {
    final vectorsBlob = vectorListToBytes(vectors);
    final hintsJson = retrievalMetadata != null
        ? jsonEncode(retrievalMetadata)
        : retrievalHints != null
        ? jsonEncode(retrievalHints)
        : null;

    await put(
      EmbeddingsCompanion.insert(
        entryId: entryId,
        sourceType: Value(sourceType),
        sourceId: Value(sourceId),
        vectorsBlob: Value(vectorsBlob),
        textHash: Value(textHash),
        retrievalHintsJson: Value(hintsJson),
        errorJson: const Value(null),
        updatedAt: Value(currentTimestampSeconds()),
      ),
    );
  }

  Future<void> putEmbeddingError({
    required String entryId,
    required String sourceType,
    String? sourceId,
    required String textHash,
    required Map<String, dynamic> error,
    List<String>? retrievalHints,
    Map<String, dynamic>? retrievalMetadata,
  }) async {
    final hintsJson = retrievalMetadata != null
        ? jsonEncode(retrievalMetadata)
        : retrievalHints != null
        ? jsonEncode(retrievalHints)
        : null;

    await put(
      EmbeddingsCompanion.insert(
        entryId: entryId,
        sourceType: Value(sourceType),
        sourceId: Value(sourceId),
        vectorsBlob: const Value(null),
        textHash: Value(textHash),
        retrievalHintsJson: Value(hintsJson),
        errorJson: Value(jsonEncode(error)),
        updatedAt: Value(currentTimestampSeconds()),
      ),
    );
  }

  List<List<double>>? decodeVectors(EmbeddingRow row) => decodeRowVectors(row);

  /// Pure decoding for retrieval workers. No database handle crosses isolates.
  static List<List<double>>? decodeRowVectors(EmbeddingRow row) {
    final stored = row.vectorsBlob;
    if (stored == null) return null;
    // A previous backup import saved BLOB byte arrays as SQLite TEXT. Drift
    // exposes those rows as UTF-8 bytes; decode the original vector payload.
    final isJsonArray =
        stored.length > 2 &&
        stored.first == 0x5b &&
        stored.last == 0x5d &&
        stored[1] >= 0x30 &&
        stored[1] <= 0x39;
    final bytes = isJsonArray
        ? vectorBytesFromJson(utf8.decode(stored, allowMalformed: true))
        : stored;
    return bytes == null ? [] : bytesToVectorList(bytes);
  }

  bool hasUsableVectors(EmbeddingRow row) {
    final blob = row.vectorsBlob;
    return blob != null && blob.isNotEmpty;
  }

  List<String>? decodeHints(EmbeddingRow row) {
    if (row.retrievalHintsJson == null) return null;
    try {
      final decoded = jsonDecode(row.retrievalHintsJson!);
      if (decoded is List) return decoded.cast<String>();
      if (decoded is Map && decoded['hints'] is List) {
        return (decoded['hints'] as List).cast<String>();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? decodeMetadata(EmbeddingRow row) =>
      decodeRowMetadata(row);

  static Map<String, dynamic>? decodeRowMetadata(EmbeddingRow row) {
    if (row.retrievalHintsJson == null) return null;
    try {
      final decoded = jsonDecode(row.retrievalHintsJson!);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? decodeError(EmbeddingRow row) {
    if (row.errorJson == null) return null;
    try {
      return jsonDecode(row.errorJson!) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}

class EmbeddingStaleStats {
  final int total;
  final int stale;
  final int missingMetadata;
  final Map<String, int> bySource;

  const EmbeddingStaleStats({
    required this.total,
    required this.stale,
    required this.missingMetadata,
    required this.bySource,
  });
}
