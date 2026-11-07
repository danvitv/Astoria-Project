import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../models/memory_book.dart';
import '../../models/chat_message.dart';
import '../../models/memory_entry_revisions.dart';
import '../../models/memory_source_manifest.dart';
import '../../models/session_branch_identity.dart';
import '../app_db.dart';

class MemoryEventSourceInput {
  final String id;
  final String memoryEntryId;
  final String revisionId;
  final String fingerprint;
  final List<String> messageIds;
  final int sourceSwipeId;
  final int sourceAgentSwipeId;

  const MemoryEventSourceInput({
    required this.id,
    required this.memoryEntryId,
    required this.revisionId,
    required this.fingerprint,
    this.messageIds = const [],
    this.sourceSwipeId = 0,
    this.sourceAgentSwipeId = 0,
  });
}

class MemoryEventInput {
  final String id;
  final String sessionId;
  final String branchId;
  final String kind;
  final String description;
  final String state;
  final String? boundaryMessageId;
  final int? boundarySwipeId;
  final int? boundaryAgentSwipeId;
  final int? boundaryOrdinal;
  final List<MemoryEventSourceInput> sources;

  const MemoryEventInput({
    required this.id,
    required this.sessionId,
    required this.branchId,
    required this.kind,
    required this.description,
    required this.state,
    required this.sources,
    this.boundaryMessageId,
    this.boundarySwipeId,
    this.boundaryAgentSwipeId,
    this.boundaryOrdinal,
  });
}

class MemoryEventLinkInput {
  final String id;
  final String fromEventId;
  final String toEventId;
  final String relation;

  const MemoryEventLinkInput({
    required this.id,
    required this.fromEventId,
    required this.toEventId,
    required this.relation,
  });
}

/// Persistence boundary for accepted event-registry facts. Model output must
/// be parsed and reviewed before it reaches this repository.
class MemoryEventRegistryRepo {
  final AppDatabase db;

  const MemoryEventRegistryRepo(this.db);

  static const eventKinds = {
    'promise',
    'agreement',
    'action',
    'result',
    'cancellation',
    'change',
  };
  static const eventStates = {
    'open',
    'completed',
    'cancelled',
    'continuing',
    'contradiction',
  };
  static const relations = {
    'continues',
    'fulfills',
    'cancels',
    'contradicts',
    'confirms',
    'independent_similarity',
  };

  Future<List<MemoryEventRow>> getActiveEvents({
    required String sessionId,
    required String branchId,
  }) async {
    final rows =
        await (db.select(db.memoryEventRows)
              ..where(
                (row) =>
                    row.sessionId.equals(sessionId) &
                    row.branchId.equals(branchId) &
                    row.status.equals('active'),
              )
              ..orderBy([(row) => OrderingTerm(expression: row.acceptedAt)]))
            .get();
    final invalidated = await _invalidatedIds(sessionId, branchId, 'event');
    return rows.where((row) => !invalidated.contains(row.id)).toList();
  }

  Future<List<MemoryEventLinkRow>> getActiveLinks({
    required String sessionId,
    required String branchId,
  }) async {
    final rows =
        await (db.select(db.memoryEventLinkRows)
              ..where(
                (row) =>
                    row.sessionId.equals(sessionId) &
                    row.branchId.equals(branchId) &
                    row.status.equals('active'),
              )
              ..orderBy([(row) => OrderingTerm(expression: row.acceptedAt)]))
            .get();
    final invalidatedLinks = await _invalidatedIds(sessionId, branchId, 'link');
    final invalidatedEvents = await _invalidatedIds(
      sessionId,
      branchId,
      'event',
    );
    return rows
        .where(
          (row) =>
              !invalidatedLinks.contains(row.id) &&
              !invalidatedEvents.contains(row.fromEventId) &&
              !invalidatedEvents.contains(row.toEventId),
        )
        .toList();
  }

  Future<List<MemoryEventInvalidationRow>> getInvalidations({
    required String sessionId,
    required String branchId,
  }) =>
      (db.select(db.memoryEventInvalidationRows)
            ..where(
              (row) =>
                  row.sessionId.equals(sessionId) &
                  row.branchId.equals(branchId),
            )
            ..orderBy([
              (row) => OrderingTerm.asc(row.createdAt),
              (row) => OrderingTerm.asc(row.id),
            ]))
          .get();

  Future<Set<String>> _invalidatedIds(
    String sessionId,
    String branchId,
    String targetType,
  ) async =>
      (await (db.select(db.memoryEventInvalidationRows)..where(
                (row) =>
                    row.sessionId.equals(sessionId) &
                    row.branchId.equals(branchId) &
                    row.targetType.equals(targetType),
              ))
              .get())
          .map((row) => row.targetId)
          .toSet();

  /// Rechecks every source inside the same transaction that inserts the event.
  /// Returns false if a source changed or an ID is already occupied.
  Future<bool> accept({
    required MemoryEventInput event,
    List<MemoryEventLinkInput> links = const [],
    required bool Function() isCurrent,
    String acceptedBy = 'user',
  }) async {
    _validateEvent(event, links);
    final normalizedAcceptedBy = acceptedBy.trim();
    if (normalizedAcceptedBy.isEmpty || normalizedAcceptedBy.length > 128) {
      throw ArgumentError('Invalid event acceptor.');
    }
    return db.transaction(() async {
      if (!isCurrent()) return false;
      final session =
          await (db.select(db.chatSessions)
                ..where((row) => row.sessionId.equals(event.sessionId)))
              .getSingleOrNull();
      final branchIdentity = SessionBranchIdentity.fromSessionVarsJson(
        sessionId: event.sessionId,
        sessionVarsJson: session?.sessionVarsJson,
      );
      if (session == null ||
          branchIdentity == null ||
          branchIdentity.branchId != event.branchId ||
          !isCurrent()) {
        return false;
      }
      final history = _decodeHistory(session.messagesJson);
      if (history == null) return false;
      final existing = await (db.select(
        db.memoryEventRows,
      )..where((row) => row.id.equals(event.id))).getSingleOrNull();
      if (existing != null) return false;

      final entries = await _readEntries(event.sessionId);
      if (entries == null || !isCurrent()) return false;
      final sourceMessageIds = <String>{};
      for (final source in event.sources) {
        final entry = entries[source.memoryEntryId];
        if (entry == null ||
            entry.status != 'active' ||
            entry.sourceManifest?.invalidated == true ||
            !MemoryEntryRevisions.isUsable(entry)) {
          return false;
        }
        final revision = MemoryEntryRevisions.find(entry, source.revisionId);
        final manifest = revision?.sourceManifest;
        if (revision == null ||
            revision.id != entry.activeRevisionId ||
            !const ListEquality<String>().equals(
              revision.messageIds,
              source.messageIds,
            ) ||
            !const ListEquality<String>().equals(
              entry.messageIds,
              revision.messageIds,
            ) ||
            manifest == null ||
            manifest.originSessionId.isEmpty ||
            manifest.invalidated ||
            manifest != entry.sourceManifest ||
            manifest.validate(source.messageIds, history) !=
                MemorySourceValidity.verified ||
            !const ListEquality<String>().equals(
              manifest.messages.map((stamp) => stamp.messageId).toList(),
              source.messageIds,
            ) ||
            source.sourceSwipeId != entry.sourceSwipeId ||
            source.sourceAgentSwipeId != entry.sourceAgentSwipeId ||
            _fingerprint(
                  revision,
                  sourceSwipeId: source.sourceSwipeId,
                  sourceAgentSwipeId: source.sourceAgentSwipeId,
                ) !=
                source.fingerprint) {
          return false;
        }
        sourceMessageIds.addAll(source.messageIds);
      }
      if (event.boundaryMessageId != null &&
          (!sourceMessageIds.contains(event.boundaryMessageId) ||
              event.boundarySwipeId == null ||
              event.boundaryAgentSwipeId == null ||
              event.boundaryOrdinal == null ||
              event.boundaryOrdinal! < 0 ||
              !event.sources.any((source) {
                final manifest = entries[source.memoryEntryId]!.sourceManifest!;
                return manifest.messages.any(
                  (stamp) =>
                      stamp.messageId == event.boundaryMessageId &&
                      stamp.swipeId == event.boundarySwipeId &&
                      stamp.agentSwipeId == event.boundaryAgentSwipeId,
                );
              }))) {
        return false;
      }
      for (final link in links) {
        final ids = {link.fromEventId, link.toEventId};
        if (!ids.contains(event.id)) return false;
        final otherId = ids.firstWhere((id) => id != event.id);
        final endpoints =
            await (db.select(db.memoryEventRows)..where(
                  (row) =>
                      row.id.equals(otherId) &
                      row.sessionId.equals(event.sessionId) &
                      row.branchId.equals(event.branchId) &
                      row.status.equals('active'),
                ))
                .get();
        if (!isCurrent() ||
            endpoints.length != 1 ||
            endpoints.single.id != otherId ||
            !await _hasCurrentEventSources(
              eventId: otherId,
              sessionId: event.sessionId,
              branchId: event.branchId,
              entries: entries,
              history: history,
            )) {
          return false;
        }
      }
      if (!isCurrent()) return false;
      final sourceIds = event.sources.map((source) => source.id).toSet();
      final linkIds = links.map((link) => link.id).toSet();
      final occupiedSourceIds = await (db.select(
        db.memoryEventSourceRows,
      )..where((row) => row.id.isIn(sourceIds))).get();
      final occupiedLinkIds = await (db.select(
        db.memoryEventLinkRows,
      )..where((row) => row.id.isIn(linkIds))).get();
      if (occupiedSourceIds.isNotEmpty ||
          occupiedLinkIds.isNotEmpty ||
          sourceIds.length != event.sources.length ||
          linkIds.length != links.length ||
          sourceIds.intersection(linkIds).isNotEmpty ||
          sourceIds.contains(event.id) ||
          linkIds.contains(event.id)) {
        return false;
      }
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await db
          .into(db.memoryEventRows)
          .insert(
            MemoryEventRowsCompanion.insert(
              id: event.id,
              sessionId: event.sessionId,
              branchId: event.branchId,
              kind: event.kind,
              description: event.description.trim(),
              state: event.state,
              boundaryMessageId: Value(event.boundaryMessageId),
              boundarySwipeId: Value(event.boundarySwipeId),
              boundaryAgentSwipeId: Value(event.boundaryAgentSwipeId),
              boundaryOrdinal: Value(event.boundaryOrdinal),
              acceptedAt: now,
              acceptedBy: Value(normalizedAcceptedBy),
              createdAt: now,
            ),
          );
      for (final source in event.sources) {
        final revision = MemoryEntryRevisions.find(
          entries[source.memoryEntryId]!,
          source.revisionId,
        )!;
        await db
            .into(db.memoryEventSourceRows)
            .insert(
              MemoryEventSourceRowsCompanion.insert(
                id: source.id,
                eventId: event.id,
                sessionId: event.sessionId,
                branchId: event.branchId,
                memoryEntryId: source.memoryEntryId,
                revisionId: source.revisionId,
                fingerprint: _fingerprint(
                  revision,
                  sourceSwipeId: source.sourceSwipeId,
                  sourceAgentSwipeId: source.sourceAgentSwipeId,
                ),
                sourceManifestJson: Value(
                  jsonEncode(revision.sourceManifest!.toJson()),
                ),
                messageIdsJson: Value(jsonEncode(source.messageIds)),
                sourceSwipeId: Value(source.sourceSwipeId),
                sourceAgentSwipeId: Value(source.sourceAgentSwipeId),
              ),
            );
      }
      for (final link in links) {
        await db
            .into(db.memoryEventLinkRows)
            .insert(
              MemoryEventLinkRowsCompanion.insert(
                id: link.id,
                sessionId: event.sessionId,
                branchId: event.branchId,
                fromEventId: link.fromEventId,
                toEventId: link.toEventId,
                relation: link.relation,
                acceptedAt: now,
              ),
            );
      }
      return true;
    });
  }

  /// Stable source fingerprint over the exact revision text and provenance.
  static String sourceFingerprint(
    MemoryEntryRevision revision, {
    required int sourceSwipeId,
    required int sourceAgentSwipeId,
  }) => _fingerprint(
    revision,
    sourceSwipeId: sourceSwipeId,
    sourceAgentSwipeId: sourceAgentSwipeId,
  );

  static String _fingerprint(
    MemoryEntryRevision revision, {
    required int sourceSwipeId,
    required int sourceAgentSwipeId,
  }) => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'id': revision.id,
            'title': revision.title,
            'content': revision.content,
            'keys': revision.keys,
            'keyParagraphs': revision.keyParagraphs,
            'ledgerRange': revision.ledgerRange,
            'messageIds': revision.messageIds,
            'sourceManifest': revision.sourceManifest?.toJson(),
            'sourceSwipeId': sourceSwipeId,
            'sourceAgentSwipeId': sourceAgentSwipeId,
          }),
        ),
      )
      .toString();

  Future<Map<String, MemoryEntry>?> _readEntries(String sessionId) async {
    final row = await (db.select(
      db.memoryBookRows,
    )..where((item) => item.sessionId.equals(sessionId))).getSingleOrNull();
    if (row == null) return null;
    try {
      final decoded = jsonDecode(row.entriesJson) as List;
      final entries = <String, MemoryEntry>{};
      for (final item in decoded) {
        if (item is! Map) return null;
        final entry = MemoryEntry.fromJson(Map<String, dynamic>.from(item));
        if (entries.containsKey(entry.id)) return null;
        entries[entry.id] = entry;
      }
      return entries;
    } catch (_) {
      return null;
    }
  }

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

  Future<bool> _hasCurrentEventSources({
    required String eventId,
    required String sessionId,
    required String branchId,
    required Map<String, MemoryEntry> entries,
    required List<ChatMessage> history,
  }) async {
    if ((await _invalidatedIds(
      sessionId,
      branchId,
      'event',
    )).contains(eventId)) {
      return false;
    }
    final rows =
        await (db.select(db.memoryEventSourceRows)..where(
              (row) =>
                  row.eventId.equals(eventId) &
                  row.sessionId.equals(sessionId) &
                  row.branchId.equals(branchId),
            ))
            .get();
    if (rows.isEmpty) return false;
    final memoryEntryIds = <String>{};
    for (final row in rows) {
      if (!memoryEntryIds.add(row.memoryEntryId)) return false;
      final entry = entries[row.memoryEntryId];
      if (entry == null ||
          entry.status != 'active' ||
          !MemoryEntryRevisions.isUsable(entry)) {
        return false;
      }
      final revision = MemoryEntryRevisions.find(entry, row.revisionId);
      final manifest = revision?.sourceManifest;
      final storedManifest = _decodeManifest(row.sourceManifestJson);
      final messageIds = _decodeStringList(row.messageIdsJson);
      if (revision == null ||
          revision.id != entry.activeRevisionId ||
          manifest == null ||
          manifest.invalidated ||
          manifest != entry.sourceManifest ||
          storedManifest != manifest ||
          messageIds == null ||
          !const ListEquality<String>().equals(
            messageIds,
            revision.messageIds,
          ) ||
          !const ListEquality<String>().equals(
            entry.messageIds,
            revision.messageIds,
          ) ||
          manifest.validate(messageIds, history) !=
              MemorySourceValidity.verified ||
          row.sourceSwipeId != entry.sourceSwipeId ||
          row.sourceAgentSwipeId != entry.sourceAgentSwipeId ||
          row.fingerprint !=
              _fingerprint(
                revision,
                sourceSwipeId: row.sourceSwipeId,
                sourceAgentSwipeId: row.sourceAgentSwipeId,
              )) {
        return false;
      }
    }
    return true;
  }

  static MemorySourceManifest? _decodeManifest(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map) return null;
      return MemorySourceManifest.fromJson(Map<String, dynamic>.from(decoded));
    } on Object {
      return null;
    }
  }

  static List<String>? _decodeStringList(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List || decoded.any((value) => value is! String)) {
        return null;
      }
      return decoded.cast<String>();
    } on Object {
      return null;
    }
  }

  static void _validateEvent(
    MemoryEventInput event,
    List<MemoryEventLinkInput> links,
  ) {
    final description = event.description.trim();
    if (event.id.isEmpty ||
        event.id != event.id.trim() ||
        event.sessionId.isEmpty ||
        event.branchId.isEmpty ||
        event.branchId != event.sessionId ||
        description.isEmpty ||
        description.length > 2000 ||
        (event.boundaryMessageId == null &&
            (event.boundarySwipeId != null ||
                event.boundaryAgentSwipeId != null ||
                event.boundaryOrdinal != null)) ||
        !eventKinds.contains(event.kind) ||
        !eventStates.contains(event.state) ||
        event.sources.isEmpty ||
        event.sources.map((source) => source.id).toSet().length !=
            event.sources.length ||
        event.sources.map((source) => source.memoryEntryId).toSet().length !=
            event.sources.length) {
      throw ArgumentError('Invalid memory event.');
    }
    if (event.sources.any(
      (source) =>
          source.id.isEmpty ||
          source.id != source.id.trim() ||
          source.memoryEntryId.isEmpty ||
          source.revisionId.isEmpty ||
          source.fingerprint.length != 64,
    )) {
      throw ArgumentError('Invalid memory event source.');
    }
    for (final link in links) {
      if (link.id.isEmpty ||
          link.id != link.id.trim() ||
          link.id == event.id ||
          link.fromEventId == link.toEventId ||
          !{link.fromEventId, link.toEventId}.contains(event.id) ||
          !relations.contains(link.relation)) {
        throw ArgumentError('Invalid memory event link.');
      }
    }
  }
}
