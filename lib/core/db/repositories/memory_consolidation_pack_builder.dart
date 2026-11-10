import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';

import '../../llm/vector_math.dart';
import '../../llm/tokenizer.dart';
import '../app_db.dart';
import '../../models/memory_book.dart';
import '../../models/chat_message.dart';
import '../../models/memory_consolidation.dart';
import '../../models/memory_entry_revisions.dart';
import '../../models/memory_source_manifest.dart';
import '../../models/session_branch_identity.dart';
import 'embedding_repo.dart';
import 'memory_event_registry_repo.dart';

/// Builds the bounded, immutable input for one consolidation request.
///
/// Candidates are gathered through five independent channels, in plan
/// priority: direct registry links, participant/subject overlap between the
/// requested entry keys and event source entry keys, open obligations,
/// key/full-text hits, and vector similarity of the underlying memory
/// embeddings. Requested active MemoryBook entries are always included, and
/// anything that could not fit or could not be verified is explicit in
/// [MemoryConsolidationSourcePack.unexaminedOpenObligationIds].
class MemoryConsolidationPackBuilder {
  final AppDatabase db;

  const MemoryConsolidationPackBuilder(this.db);

  Future<MemoryConsolidationSourcePack?> build({
    required String sessionId,
    required String branchId,
    required String proposedEventId,
    List<String>? proposedEventIds,
    required List<String> memoryEntryIds,
    int maxCandidates = 12,
    int maxContextCharacters = 120000,
    int? maxContextTokens,
    double vectorSimilarityThreshold = 0.4,
  }) async {
    if (sessionId.isEmpty ||
        branchId.isEmpty ||
        branchId != sessionId ||
        proposedEventId.isEmpty ||
        proposedEventId != proposedEventId.trim() ||
        maxCandidates < 1 ||
        maxContextCharacters < 1 ||
        !(vectorSimilarityThreshold >= 0 && vectorSimilarityThreshold <= 1)) {
      throw ArgumentError('Invalid consolidation pack bounds.');
    }
    final eventIds = proposedEventIds ?? [proposedEventId];
    if (eventIds.isEmpty ||
        eventIds.length > memoryEntryIds.length ||
        eventIds.toSet().length != eventIds.length ||
        eventIds.any((id) => id.trim().isEmpty || id != id.trim())) {
      throw ArgumentError('Invalid proposed event ID set.');
    }
    final row = await (db.select(
      db.memoryBookRows,
    )..where((item) => item.sessionId.equals(sessionId))).getSingleOrNull();
    if (row == null) return null;
    final session = await (db.select(
      db.chatSessions,
    )..where((item) => item.sessionId.equals(sessionId))).getSingleOrNull();
    final identity = SessionBranchIdentity.fromSessionVarsJson(
      sessionId: sessionId,
      sessionVarsJson: session?.sessionVarsJson,
    );
    if (identity == null || identity.branchId != branchId) return null;
    final history = _decodeHistory(session!.messagesJson);
    if (history == null) return null;
    final entries = _decodeEntries(row.entriesJson);
    if (entries == null) return null;

    final selectedSources = <MemoryConsolidationSource>[];
    final sourceRefs = <String>{};
    final sourceRefByIdentity = <String, String>{};
    for (final entryId in memoryEntryIds) {
      final source = _sourceFromEntry(
        entry: entries[entryId],
        sessionId: sessionId,
        branchId: branchId,
        history: history,
        ref: 'entry:$entryId',
      );
      if (source == null || !sourceRefs.add(source.ref)) return null;
      selectedSources.add(source);
      sourceRefByIdentity[_sourceIdentity(source)] = source.ref;
    }
    if (selectedSources.isEmpty) return null;
    final contextPackId =
        'consolidation:$sessionId:${DateTime.now().microsecondsSinceEpoch}';
    if (_exceedsContext(
      packId: contextPackId,
      sessionId: sessionId,
      branchId: branchId,
      proposedEventId: proposedEventId,
      proposedEventIds: eventIds,
      sources: selectedSources,
      candidates: const [],
      unexaminedOpenObligationIds: const [],
      maxContextCharacters: maxContextCharacters,
      maxContextTokens: maxContextTokens,
    )) {
      throw const MemoryConsolidationPackTooLargeException();
    }

    final events = await MemoryEventRegistryRepo(
      db,
    ).getActiveEvents(sessionId: sessionId, branchId: branchId);
    final links = await MemoryEventRegistryRepo(
      db,
    ).getActiveLinks(sessionId: sessionId, branchId: branchId);
    final sourceRows = events.isEmpty
        ? const <MemoryEventSourceRow>[]
        : await (db.select(db.memoryEventSourceRows)..where(
                (row) =>
                    row.sessionId.equals(sessionId) &
                    row.branchId.equals(branchId) &
                    row.eventId.isIn(
                      events.map((event) => event.id).toList(growable: false),
                    ),
              ))
              .get();

    final sourceByEvent = <String, List<MemoryConsolidationSource>>{};
    final unavailableOpenObligations = <String>{};
    for (final sourceRow in sourceRows) {
      final entry = entries[sourceRow.memoryEntryId];
      final source = _sourceFromRow(
        row: sourceRow,
        entry: entry,
        sessionId: sessionId,
        branchId: branchId,
        history: history,
      );
      if (source == null) {
        final event = events.firstWhereOrNull(
          (candidate) => candidate.id == sourceRow.eventId,
        );
        if (event != null && _isOpenObligation(event)) {
          unavailableOpenObligations.add(event.id);
        }
        continue;
      }
      sourceByEvent.putIfAbsent(sourceRow.eventId, () => []).add(source);
    }

    final open = events.where(_isOpenObligation).toList();
    final allOpenIds = open.map((event) => event.id).toSet();
    final directIds = <String>{};
    for (final link in links) {
      directIds
        ..add(link.fromEventId)
        ..add(link.toEventId);
    }
    final scoresByEvent = await _channelScores(
      memoryEntryIds: memoryEntryIds,
      entries: entries,
      sourceByEvent: sourceByEvent,
      vectorSimilarityThreshold: vectorSimilarityThreshold,
    );
    final baseOrder = <String, int>{
      for (var i = 0; i < events.length; i++) events[i].id: i,
    };
    int channelRank(MemoryEventRow event) {
      final score = scoresByEvent[event.id];
      if (directIds.contains(event.id)) return 0;
      if (score != null && score.sharedKeys > 0) return 1;
      if (_isOpenObligation(event)) return 2;
      if (score != null && score.fullTextHit) return 3;
      if (score != null && score.vectorScore >= vectorSimilarityThreshold) {
        return 4;
      }
      return 5;
    }

    final ordered = [...events]
      ..sort((a, b) {
        final rankA = channelRank(a);
        final rankB = channelRank(b);
        if (rankA != rankB) return rankA.compareTo(rankB);
        final scoreA = scoresByEvent[a.id];
        final scoreB = scoresByEvent[b.id];
        if (rankA == 1) {
          return (scoreB?.sharedKeys ?? 0).compareTo(scoreA?.sharedKeys ?? 0);
        }
        if (rankA == 2) {
          final byDate = a.createdAt.compareTo(b.createdAt);
          if (byDate != 0) return byDate;
          return (baseOrder[a.id] ?? 0).compareTo(baseOrder[b.id] ?? 0);
        }
        if (rankA == 4) {
          return (scoreB?.vectorScore ?? 0).compareTo(scoreA?.vectorScore ?? 0);
        }
        return (baseOrder[a.id] ?? 0).compareTo(baseOrder[b.id] ?? 0);
      });
    final candidates = <MemoryConsolidationEventCandidate>[];
    final selectedEventIds = <String>{};
    for (final event in ordered) {
      final sourcesForEvent = sourceByEvent[event.id];
      if (sourcesForEvent == null || sourcesForEvent.isEmpty) {
        if (_isOpenObligation(event)) unavailableOpenObligations.add(event.id);
        continue;
      }
      if (candidates.length >= maxCandidates) continue;
      final candidateSources = <String>{};
      final sourcesToAdd = <MemoryConsolidationSource>[];
      for (final source in sourcesForEvent) {
        final identity = _sourceIdentity(source);
        final existingRef = sourceRefByIdentity[identity];
        if (existingRef != null) {
          candidateSources.add(existingRef);
          continue;
        }
        sourcesToAdd.add(source);
        candidateSources.add(source.ref);
      }
      final linkedEventIds = [
        for (final link in links)
          if (link.fromEventId == event.id &&
              selectedEventIds.contains(link.toEventId))
            link.toEventId
          else if (link.toEventId == event.id &&
              selectedEventIds.contains(link.fromEventId))
            link.fromEventId,
      ];
      final candidate = MemoryConsolidationEventCandidate(
        id: event.id,
        kind: event.kind,
        description: event.description,
        state: event.state,
        sourceRefs: List.unmodifiable(candidateSources),
        linkedEventIds: linkedEventIds,
      );
      final prospectiveSources = [...selectedSources, ...sourcesToAdd];
      final prospectiveCandidates = [...candidates, candidate];
      final prospectiveSelectedOpenIds = {
        ...selectedEventIds.where(allOpenIds.contains),
        if (_isOpenObligation(event)) event.id,
      };
      final prospectiveUnexamined = {
        ...unavailableOpenObligations,
        ...allOpenIds.difference(prospectiveSelectedOpenIds),
      }.toList()..sort();
      if (_exceedsContext(
        packId: contextPackId,
        sessionId: sessionId,
        branchId: branchId,
        proposedEventId: proposedEventId,
        proposedEventIds: eventIds,
        sources: prospectiveSources,
        candidates: prospectiveCandidates,
        unexaminedOpenObligationIds: prospectiveUnexamined,
        maxContextCharacters: maxContextCharacters,
        maxContextTokens: maxContextTokens,
      )) {
        if (_isOpenObligation(event)) unavailableOpenObligations.add(event.id);
        continue;
      }
      selectedSources
        ..clear()
        ..addAll(prospectiveSources);
      for (final source in sourcesToAdd) {
        sourceRefs.add(source.ref);
        sourceRefByIdentity[_sourceIdentity(source)] = source.ref;
      }
      selectedEventIds.add(event.id);
      candidates.add(candidate);
    }

    final selectedOpenIds = candidates
        .where(
          (candidate) =>
              candidate.state == 'open' || candidate.state == 'continuing',
        )
        .map((candidate) => candidate.id)
        .toSet();
    final unexamined = <String>{
      ...unavailableOpenObligations,
      ...allOpenIds.difference(selectedOpenIds),
    };
    final unexaminedIds = unexamined.toList()..sort();
    if (_exceedsContext(
      packId: contextPackId,
      sessionId: sessionId,
      branchId: branchId,
      proposedEventId: proposedEventId,
      proposedEventIds: eventIds,
      sources: selectedSources,
      candidates: candidates,
      unexaminedOpenObligationIds: unexaminedIds,
      maxContextCharacters: maxContextCharacters,
      maxContextTokens: maxContextTokens,
    )) {
      throw const MemoryConsolidationPackTooLargeException();
    }
    return MemoryConsolidationSourcePack(
      packId: contextPackId,
      sessionId: sessionId,
      branchId: branchId,
      proposedEventId: proposedEventId,
      proposedEventIds: eventIds,
      sources: selectedSources,
      candidates: candidates,
      unexaminedOpenObligationIds: unexaminedIds,
    );
  }

  /// Scores every event through the participant/subject, full-text and vector
  /// channels. Direct links and open obligations are ranked separately in
  /// [build]; this method only computes the overlap-driven channels.
  Future<Map<String, _ChannelScore>> _channelScores({
    required List<String> memoryEntryIds,
    required Map<String, MemoryEntry> entries,
    required Map<String, List<MemoryConsolidationSource>> sourceByEvent,
    required double vectorSimilarityThreshold,
  }) async {
    final selectedKeys = <String>{};
    final selectedTokens = <String>{};
    for (final entryId in memoryEntryIds) {
      final entry = entries[entryId];
      if (entry == null) continue;
      for (final key in entry.keys) {
        final normalized = _normalizeText(key);
        if (normalized.isEmpty) continue;
        if (normalized.length >= 3) selectedKeys.add(normalized);
        for (final word in normalized.split(RegExp(r'[^a-z0-9а-яё]+'))) {
          if (word.length >= 4) selectedTokens.add(word);
        }
      }
    }
    final embeddingRepo = EmbeddingRepo(db);
    final selectedVectors = <List<List<double>>>[];
    for (final entryId in memoryEntryIds) {
      final row = await embeddingRepo.getByEntryId(entryId);
      final vectors = row == null ? null : embeddingRepo.decodeVectors(row);
      if (vectors != null && vectors.isNotEmpty) selectedVectors.add(vectors);
    }
    final vectorsByEntryId = <String, List<List<double>>?>{};

    Future<List<List<double>>?> entryVectors(String entryId) async {
      if (vectorsByEntryId.containsKey(entryId)) {
        return vectorsByEntryId[entryId];
      }
      final row = await embeddingRepo.getByEntryId(entryId);
      final vectors = row == null ? null : embeddingRepo.decodeVectors(row);
      final result = vectors == null || vectors.isEmpty ? null : vectors;
      vectorsByEntryId[entryId] = result;
      return result;
    }

    final scores = <String, _ChannelScore>{};
    for (final entry in sourceByEvent.entries) {
      var sharedKeys = 0;
      var fullTextHit = false;
      var vectorScore = 0.0;
      for (final source in entry.value) {
        final eventEntry = entries[source.memoryEntryId];
        if (eventEntry == null) continue;
        sharedKeys += eventEntry.keys
            .map(_normalizeText)
            .where(selectedKeys.contains)
            .length;
        if (!fullTextHit) {
          final haystack = '${eventEntry.title}\n${eventEntry.content}'
              .toLowerCase();
          fullTextHit = selectedTokens.any(haystack.contains);
        }
        if (selectedVectors.isNotEmpty) {
          final vectors = await entryVectors(source.memoryEntryId);
          if (vectors != null) {
            for (final selected in selectedVectors) {
              for (final query in selected) {
                for (final candidate in vectors) {
                  final score = cosineSimilarity(query, candidate);
                  if (score > vectorScore) vectorScore = score;
                }
              }
            }
          }
        }
      }
      scores[entry.key] = _ChannelScore(
        sharedKeys: sharedKeys,
        fullTextHit: fullTextHit,
        vectorScore: vectorScore,
      );
    }
    return scores;
  }

  static String _normalizeText(String value) => value.trim().toLowerCase();

  static Map<String, MemoryEntry>? _decodeEntries(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return null;
      final entries = <String, MemoryEntry>{};
      for (final item in decoded) {
        if (item is! Map) return null;
        final entry = MemoryEntry.fromJson(Map<String, dynamic>.from(item));
        if (entries.containsKey(entry.id)) return null;
        entries[entry.id] = entry;
      }
      return entries;
    } on Object {
      return null;
    }
  }

  static MemoryConsolidationSource? _sourceFromEntry({
    required MemoryEntry? entry,
    required String sessionId,
    required String branchId,
    required List<ChatMessage> history,
    required String ref,
  }) {
    if (entry == null || entry.status != 'active') return null;
    final revision = _activeRevision(entry);
    if (revision == null) return null;
    final manifest = revision.sourceManifest;
    if (manifest == null ||
        !_validManifest(entry, revision, manifest, sessionId) ||
        manifest.validate(revision.messageIds, history) !=
            MemorySourceValidity.verified) {
      return null;
    }
    return MemoryConsolidationSource(
      ref: ref,
      sessionId: sessionId,
      branchId: branchId,
      memoryEntryId: entry.id,
      revisionId: revision.id,
      fingerprint: MemoryEventRegistryRepo.sourceFingerprint(
        revision,
        sourceSwipeId: entry.sourceSwipeId,
        sourceAgentSwipeId: entry.sourceAgentSwipeId,
      ),
      title: revision.title,
      content: revision.content,
      messageIds: revision.messageIds,
      sourceSwipeId: entry.sourceSwipeId,
      sourceAgentSwipeId: entry.sourceAgentSwipeId,
      sourceManifest: manifest,
    );
  }

  static MemoryConsolidationSource? _sourceFromRow({
    required MemoryEventSourceRow row,
    required MemoryEntry? entry,
    required String sessionId,
    required String branchId,
    required List<ChatMessage> history,
  }) {
    if (entry == null || entry.status != 'active') return null;
    final revision = MemoryEntryRevisions.find(entry, row.revisionId);
    if (revision == null || revision.id != entry.activeRevisionId) return null;
    final manifest = revision.sourceManifest;
    final storedManifest = _decodeManifest(row.sourceManifestJson);
    if (manifest == null ||
        !_validManifest(entry, revision, manifest, sessionId) ||
        manifest.validate(revision.messageIds, history) !=
            MemorySourceValidity.verified ||
        storedManifest == null ||
        storedManifest != manifest ||
        row.fingerprint !=
            MemoryEventRegistryRepo.sourceFingerprint(
              revision,
              sourceSwipeId: row.sourceSwipeId,
              sourceAgentSwipeId: row.sourceAgentSwipeId,
            ) ||
        row.sourceSwipeId != entry.sourceSwipeId ||
        row.sourceAgentSwipeId != entry.sourceAgentSwipeId) {
      return null;
    }
    final messageIds = _decodeStringList(row.messageIdsJson);
    if (messageIds == null ||
        messageIds.length != revision.messageIds.length ||
        messageIds.asMap().entries.any(
          (item) => item.value != revision.messageIds[item.key],
        )) {
      return null;
    }
    return MemoryConsolidationSource(
      ref: 'event:${row.eventId}:source:${row.id}',
      sessionId: sessionId,
      branchId: branchId,
      memoryEntryId: entry.id,
      revisionId: revision.id,
      fingerprint: row.fingerprint,
      title: revision.title,
      content: revision.content,
      messageIds: messageIds,
      sourceSwipeId: row.sourceSwipeId,
      sourceAgentSwipeId: row.sourceAgentSwipeId,
      sourceManifest: manifest,
    );
  }

  static MemoryEntryRevision? _activeRevision(MemoryEntry entry) {
    if (!MemoryEntryRevisions.isUsable(entry) ||
        entry.activeRevisionId == null) {
      return null;
    }
    final revision = MemoryEntryRevisions.find(entry, entry.activeRevisionId!);
    return revision?.id == entry.activeRevisionId ? revision : null;
  }

  static bool _validManifest(
    MemoryEntry entry,
    MemoryEntryRevision revision,
    MemorySourceManifest? manifest,
    String sessionId,
  ) =>
      manifest != null &&
      manifest.originSessionId.isNotEmpty &&
      !manifest.invalidated &&
      revision.messageIds.length == manifest.messages.length &&
      revision.messageIds.asMap().entries.every(
        (item) => manifest.messages[item.key].messageId == item.value,
      ) &&
      const ListEquality<String>().equals(
        entry.messageIds,
        revision.messageIds,
      );

  static String _sourceIdentity(MemoryConsolidationSource source) =>
      '${source.memoryEntryId}\u0000${source.revisionId}\u0000${source.fingerprint}';

  static List<ChatMessage>? _decodeHistory(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return null;
      return decoded
          .map(
            (item) =>
                ChatMessage.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList(growable: false);
    } on Object {
      return null;
    }
  }

  static int _serializedContextCharacters({
    required String packId,
    required String sessionId,
    required String branchId,
    required String proposedEventId,
    required List<String> proposedEventIds,
    required List<MemoryConsolidationSource> sources,
    required List<MemoryConsolidationEventCandidate> candidates,
    required List<String> unexaminedOpenObligationIds,
  }) => jsonEncode({
    'packId': packId,
    'sessionId': sessionId,
    'branchId': branchId,
    'proposedEventId': proposedEventId,
    'proposedEventIds': proposedEventIds,
    'sources': sources.map((source) => source.toJson()).toList(),
    'candidates': candidates.map((candidate) => candidate.toJson()).toList(),
    'unexaminedOpenObligationIds': unexaminedOpenObligationIds,
  }).length;

  static bool _exceedsContext({
    required String packId,
    required String sessionId,
    required String branchId,
    required String proposedEventId,
    required List<String> proposedEventIds,
    required List<MemoryConsolidationSource> sources,
    required List<MemoryConsolidationEventCandidate> candidates,
    required List<String> unexaminedOpenObligationIds,
    required int maxContextCharacters,
    required int? maxContextTokens,
  }) {
    final chars = _serializedContextCharacters(
      packId: packId,
      sessionId: sessionId,
      branchId: branchId,
      proposedEventId: proposedEventId,
      proposedEventIds: proposedEventIds,
      sources: sources,
      candidates: candidates,
      unexaminedOpenObligationIds: unexaminedOpenObligationIds,
    );
    if (chars > maxContextCharacters) return true;
    if (maxContextTokens == null) return false;
    final json = jsonEncode({
      'packId': packId,
      'sessionId': sessionId,
      'branchId': branchId,
      'proposedEventId': proposedEventId,
      'proposedEventIds': proposedEventIds,
      'sources': sources.map((source) => source.toJson()).toList(),
      'candidates': candidates.map((candidate) => candidate.toJson()).toList(),
      'unexaminedOpenObligationIds': unexaminedOpenObligationIds,
    });
    return estimateTokens(json) > maxContextTokens;
  }

  static List<String>? _decodeStringList(String json) {
    try {
      final value = jsonDecode(json);
      if (value is! List || value.any((item) => item is! String)) return null;
      return List<String>.from(value);
    } on Object {
      return null;
    }
  }

  static MemorySourceManifest? _decodeManifest(String json) {
    try {
      final value = jsonDecode(json);
      if (value is! Map) return null;
      return MemorySourceManifest.fromJson(Map<String, dynamic>.from(value));
    } on Object {
      return null;
    }
  }

  static bool _isOpenObligation(MemoryEventRow event) =>
      (event.kind == 'promise' || event.kind == 'agreement') &&
      (event.state == 'open' || event.state == 'continuing');
}

final class MemoryConsolidationPackTooLargeException implements Exception {
  const MemoryConsolidationPackTooLargeException();

  @override
  String toString() =>
      'A complete memory source does not fit the selected API context budget.';
}

class _ChannelScore {
  final int sharedKeys;
  final bool fullTextHit;
  final double vectorScore;

  const _ChannelScore({
    required this.sharedKeys,
    required this.fullTextHit,
    required this.vectorScore,
  });
}
