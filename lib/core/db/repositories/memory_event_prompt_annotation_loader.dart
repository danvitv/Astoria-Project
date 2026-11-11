import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';

import '../../llm/memory_selector.dart';
import '../../models/chat_message.dart';
import '../../models/memory_book.dart';
import '../../models/memory_entry_revisions.dart';
import '../../models/memory_source_manifest.dart';
import '../../models/session_branch_identity.dart';
import '../app_db.dart';
import 'memory_event_registry_repo.dart';

/// Main-isolate verifier that turns accepted registry rows into plain prompt
/// annotations. It performs no prompt formatting or token-budget decisions.
class MemoryEventPromptAnnotationLoader {
  final AppDatabase db;

  const MemoryEventPromptAnnotationLoader(this.db);

  Future<Map<String, List<MemoryEventPromptAnnotation>>> load({
    required String sessionId,
    required String branchId,
    required List<MemoryEntry> entries,
    required List<ChatMessage> history,
  }) async {
    if (sessionId.isEmpty || branchId != sessionId || entries.isEmpty) {
      return const {};
    }
    final session = await (db.select(
      db.chatSessions,
    )..where((row) => row.sessionId.equals(sessionId))).getSingleOrNull();
    final identity = SessionBranchIdentity.fromSessionVarsJson(
      sessionId: sessionId,
      sessionVarsJson: session?.sessionVarsJson,
    );
    if (identity == null || identity.branchId != branchId) return const {};
    final bookRow = await (db.select(
      db.memoryBookRows,
    )..where((row) => row.sessionId.equals(sessionId))).getSingleOrNull();
    if (bookRow == null) return const {};
    final persistedEntries = _decodeEntries(bookRow.entriesJson);
    if (persistedEntries == null) return const {};
    final selectedEntries = {for (final entry in entries) entry.id: entry};
    if (selectedEntries.length != entries.length) return const {};
    final entryIds = entries.map((entry) => entry.id).toSet();
    final sourceRows =
        await (db.select(db.memoryEventSourceRows)..where(
              (row) =>
                  row.sessionId.equals(sessionId) &
                  row.branchId.equals(branchId) &
                  row.memoryEntryId.isIn(entryIds),
            ))
            .get();
    if (sourceRows.isEmpty) return const {};

    final eventIds = sourceRows.map((row) => row.eventId).toSet();
    final ownEventSources =
        await (db.select(db.memoryEventSourceRows)..where(
              (row) =>
                  row.sessionId.equals(sessionId) &
                  row.branchId.equals(branchId) &
                  row.eventId.isIn(eventIds),
            ))
            .get();
    final eventRows =
        await (db.select(db.memoryEventRows)..where(
              (row) =>
                  row.sessionId.equals(sessionId) &
                  row.branchId.equals(branchId) &
                  row.status.equals('active') &
                  row.id.isIn(eventIds),
            ))
            .get();
    final activeEvents = {for (final event in eventRows) event.id: event};
    if (activeEvents.isEmpty) return const {};
    final links =
        await (db.select(db.memoryEventLinkRows)..where(
              (row) =>
                  row.sessionId.equals(sessionId) &
                  row.branchId.equals(branchId) &
                  row.status.equals('active') &
                  (row.fromEventId.isIn(activeEvents.keys) |
                      row.toEventId.isIn(activeEvents.keys)),
            ))
            .get();
    final otherIds = <String>{};
    for (final link in links) {
      if (activeEvents.containsKey(link.fromEventId)) {
        otherIds.add(link.toEventId);
      }
      if (activeEvents.containsKey(link.toEventId)) {
        otherIds.add(link.fromEventId);
      }
    }
    final linkedEndpoints = otherIds.isEmpty
        ? const <MemoryEventRow>[]
        : await (db.select(db.memoryEventRows)..where(
                (row) =>
                    row.sessionId.equals(sessionId) &
                    row.branchId.equals(branchId) &
                    row.status.equals('active') &
                    row.id.isIn(otherIds),
              ))
              .get();
    final activeEndpointIds = linkedEndpoints.map((row) => row.id).toSet();
    final endpointSources = otherIds.isEmpty
        ? const <MemoryEventSourceRow>[]
        : await (db.select(db.memoryEventSourceRows)..where(
                (row) =>
                    row.sessionId.equals(sessionId) &
                    row.branchId.equals(branchId) &
                    row.eventId.isIn(otherIds),
              ))
              .get();
    final sourcesByEvent = <String, List<MemoryEventSourceRow>>{};
    for (final row in [...ownEventSources, ...endpointSources]) {
      sourcesByEvent.putIfAbsent(row.eventId, () => []).add(row);
    }
    final validEventIds = <String>{};
    for (final item in sourcesByEvent.entries) {
      if (item.value.isNotEmpty &&
          item.value.every(
            (row) => _sourceIsCurrent(
              row,
              persistedEntries,
              verifiedHistory: history,
              sessionId: sessionId,
            ),
          )) {
        validEventIds.add(item.key);
      }
    }
    final allEndpoints = {...eventIds, ...activeEndpointIds};
    final invalidEventIds = <String>{};
    for (final eventId in allEndpoints) {
      final sources = sourcesByEvent[eventId] ?? const <MemoryEventSourceRow>[];
      if (sources.isNotEmpty && validEventIds.contains(eventId)) continue;
      invalidEventIds.add(eventId);
      await _recordInvalidation(
        sessionId: sessionId,
        branchId: branchId,
        targetType: 'event',
        targetId: eventId,
        causeMemoryEntryId: sources.isEmpty
            ? null
            : sources.first.memoryEntryId,
        reason: sources.isEmpty
            ? 'missing_source_rows'
            : 'source_provenance_stale',
      );
    }
    final existingInvalidations =
        await (db.select(db.memoryEventInvalidationRows)..where(
              (row) =>
                  row.sessionId.equals(sessionId) &
                  row.branchId.equals(branchId),
            ))
            .get();
    final invalidatedEventIds = existingInvalidations
        .where((row) => row.targetType == 'event')
        .map((row) => row.targetId)
        .toSet();
    invalidEventIds.addAll(invalidatedEventIds);
    for (final link in links) {
      if (invalidEventIds.contains(link.fromEventId) ||
          invalidEventIds.contains(link.toEventId)) {
        await _recordInvalidation(
          sessionId: sessionId,
          branchId: branchId,
          targetType: 'link',
          targetId: link.id,
          reason: 'endpoint_provenance_stale',
        );
      }
    }
    final invalidatedLinkIds = existingInvalidations
        .where((row) => row.targetType == 'link')
        .map((row) => row.targetId)
        .toSet();
    validEventIds.removeAll(invalidEventIds);
    final verifiedHistory = List<ChatMessage>.unmodifiable(history);
    final byEntry = <String, Map<String, MemoryEventPromptAnnotation>>{};
    for (final sourceRow in sourceRows) {
      final event = activeEvents[sourceRow.eventId];
      final entry = persistedEntries[sourceRow.memoryEntryId];
      if (event == null ||
          entry == null ||
          entry != selectedEntries[sourceRow.memoryEntryId] ||
          entry.status != 'active' ||
          !validEventIds.contains(event.id)) {
        continue;
      }
      final revision = MemoryEntryRevisions.find(entry, sourceRow.revisionId);
      final manifest = revision?.sourceManifest;
      if (revision == null ||
          manifest == null ||
          revision.id != entry.activeRevisionId ||
          !_sourceIsCurrent(
            sourceRow,
            persistedEntries,
            verifiedHistory: verifiedHistory,
            sessionId: sessionId,
          ) ||
          !_boundaryIsCurrent(event, manifest)) {
        continue;
      }
      final validRelations = links
          .where(
            (link) =>
                !invalidatedLinkIds.contains(link.id) &&
                !invalidEventIds.contains(link.fromEventId) &&
                !invalidEventIds.contains(link.toEventId) &&
                ((link.fromEventId == event.id &&
                        activeEndpointIds.contains(link.toEventId) &&
                        validEventIds.contains(link.toEventId)) ||
                    (link.toEventId == event.id &&
                        activeEndpointIds.contains(link.fromEventId) &&
                        validEventIds.contains(link.fromEventId))) &&
                activeEvents.containsKey(event.id),
          )
          .map((link) => link.relation)
          .toSet();
      // Multiple accepted relations for one event/source are ambiguous for
      // this first injection path. Keep the event out rather than guessing.
      if (validRelations.length != 1) continue;
      final relation = validRelations.single;
      final eventSources =
          sourcesByEvent[event.id] ?? const <MemoryEventSourceRow>[];
      final sceneTime = _sceneTime(eventSources, verifiedHistory);
      byEntry
          .putIfAbsent(sourceRow.memoryEntryId, () => {})
          .putIfAbsent(
            event.id,
            () => MemoryEventPromptAnnotation(
              eventId: event.id,
              kind: event.kind,
              description: event.description,
              state: event.state,
              relation: relation,
              sceneTime: sceneTime,
            ),
          );
    }
    return {
      for (final item in byEntry.entries)
        item.key: List.unmodifiable(
          (item.value.values.toList()
                ..sort((a, b) => a.eventId.compareTo(b.eventId)))
              .take(3),
        ),
    };
  }

  /// Ledger clock stamp of the scene the event belongs to: the game time
  /// recorded on the event's first source message that carries one, in
  /// story order. The clock only moves forward, so the first stamp is when
  /// the event was given; later stamps describe later scenes. Null when no
  /// source message carries a stamp — the consumer must not invent one.
  static String? _sceneTime(
    List<MemoryEventSourceRow> sources,
    List<ChatMessage> history,
  ) {
    if (sources.isEmpty) return null;
    final timeById = {
      for (final message in history)
        if (message.id.isNotEmpty && (message.time?.isNotEmpty ?? false))
          message.id: message.time!,
    };
    if (timeById.isEmpty) return null;
    final orderedIds = [
      for (final source in sources)
        ...(_decodeStringList(source.messageIdsJson) ?? const <String>[]),
    ];
    for (final id in orderedIds) {
      final time = timeById[id];
      if (time != null) return time;
    }
    return null;
  }

  Future<void> _recordInvalidation({
    required String sessionId,
    required String branchId,
    required String targetType,
    required String targetId,
    String? causeMemoryEntryId,
    required String reason,
  }) => db
      .into(db.memoryEventInvalidationRows)
      .insert(
        MemoryEventInvalidationRowsCompanion.insert(
          sessionId: sessionId,
          branchId: branchId,
          targetType: targetType,
          targetId: targetId,
          causeMemoryEntryId: Value(causeMemoryEntryId),
          reason: reason,
          createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        ),
        mode: InsertMode.insertOrIgnore,
      );

  static bool _sourceIsCurrent(
    MemoryEventSourceRow sourceRow,
    Map<String, MemoryEntry> entries, {
    required List<ChatMessage> verifiedHistory,
    required String sessionId,
  }) {
    final entry = entries[sourceRow.memoryEntryId];
    if (entry == null || entry.status != 'active') return false;
    final revision = MemoryEntryRevisions.find(entry, sourceRow.revisionId);
    final manifest = revision?.sourceManifest;
    final storedManifest = _decodeManifest(sourceRow.sourceManifestJson);
    final messageIds = _decodeStringList(sourceRow.messageIdsJson);
    return revision != null &&
        revision.id == entry.activeRevisionId &&
        MemoryEntryRevisions.isUsable(entry) &&
        manifest != null &&
        !manifest.invalidated &&
        manifest.originSessionId.isNotEmpty &&
        storedManifest != null &&
        storedManifest == manifest &&
        sourceRow.fingerprint ==
            MemoryEventRegistryRepo.sourceFingerprint(
              revision,
              sourceSwipeId: sourceRow.sourceSwipeId,
              sourceAgentSwipeId: sourceRow.sourceAgentSwipeId,
            ) &&
        sourceRow.sourceSwipeId == entry.sourceSwipeId &&
        sourceRow.sourceAgentSwipeId == entry.sourceAgentSwipeId &&
        messageIds != null &&
        const ListEquality<String>().equals(messageIds, revision.messageIds) &&
        const ListEquality<String>().equals(
          entry.messageIds,
          revision.messageIds,
        ) &&
        manifest.validate(messageIds, verifiedHistory) ==
            MemorySourceValidity.verified;
  }

  static bool _boundaryIsCurrent(
    MemoryEventRow event,
    MemorySourceManifest manifest,
  ) {
    if (event.boundaryMessageId == null) {
      return event.boundarySwipeId == null &&
          event.boundaryAgentSwipeId == null &&
          event.boundaryOrdinal == null;
    }
    if (event.boundarySwipeId == null ||
        event.boundaryAgentSwipeId == null ||
        event.boundaryOrdinal == null ||
        event.boundaryOrdinal! < 0) {
      return false;
    }
    return manifest.messages.any(
      (stamp) =>
          stamp.messageId == event.boundaryMessageId &&
          stamp.swipeId == event.boundarySwipeId &&
          stamp.agentSwipeId == event.boundaryAgentSwipeId,
    );
  }

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

  static MemorySourceManifest? _decodeManifest(String json) {
    try {
      final value = jsonDecode(json);
      if (value is! Map) return null;
      return MemorySourceManifest.fromJson(Map<String, dynamic>.from(value));
    } on Object {
      return null;
    }
  }

  static List<String>? _decodeStringList(String json) {
    try {
      final value = jsonDecode(json);
      return value is List && value.every((item) => item is String)
          ? value.cast<String>()
          : null;
    } on Object {
      return null;
    }
  }
}
