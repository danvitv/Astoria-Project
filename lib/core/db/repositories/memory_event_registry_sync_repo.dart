import 'dart:convert';

import 'package:drift/drift.dart';

import '../../application/sync_repo_interfaces.dart';
import '../../models/memory_source_manifest.dart';
import '../app_db.dart';
import 'memory_event_registry_repo.dart';

/// Cloud-sync boundary for accepted Memory consolidation facts.
///
/// The four registry collections are immutable or append-only. Pull therefore
/// forms a strict union: an occupied identity with different content aborts the
/// transaction instead of replacing either device's accepted history.
class MemoryEventRegistrySyncRepo implements SyncMemoryEventRegistryStore {
  const MemoryEventRegistrySyncRepo(this.db);

  final AppDatabase db;

  @override
  Future<List<String>> getAllSessionIds() async {
    final rows = await db.select(db.memoryEventRows).get();
    return (rows.map((row) => row.sessionId).toSet().toList()..sort());
  }

  @override
  Future<Map<String, dynamic>?> getBySessionId(String sessionId) =>
      db.transaction(() async {
        final events =
            await (db.select(db.memoryEventRows)
                  ..where((row) => row.sessionId.equals(sessionId))
                  ..orderBy([(row) => OrderingTerm.asc(row.id)]))
                .get();
        if (events.isEmpty) return null;
        final sources =
            await (db.select(db.memoryEventSourceRows)
                  ..where((row) => row.sessionId.equals(sessionId))
                  ..orderBy([(row) => OrderingTerm.asc(row.id)]))
                .get();
        final links =
            await (db.select(db.memoryEventLinkRows)
                  ..where((row) => row.sessionId.equals(sessionId))
                  ..orderBy([(row) => OrderingTerm.asc(row.id)]))
                .get();
        final invalidations =
            await (db.select(db.memoryEventInvalidationRows)
                  ..where((row) => row.sessionId.equals(sessionId))
                  ..orderBy([
                    (row) => OrderingTerm.asc(row.targetType),
                    (row) => OrderingTerm.asc(row.targetId),
                    (row) => OrderingTerm.asc(row.reason),
                  ]))
                .get();
        return {
          '__memoryEventRegistry': true,
          'schemaVersion': 1,
          'sessionId': sessionId,
          'events': events.map((row) => row.toJson()).toList(),
          'sources': sources.map((row) => row.toJson()).toList(),
          'links': links.map((row) => row.toJson()).toList(),
          // Drift's local auto-increment key has no cross-device identity. The
          // DB unique tuple below is the portable append-only identity.
          'invalidations': invalidations
              .map(
                (row) => {
                  'sessionId': row.sessionId,
                  'branchId': row.branchId,
                  'targetType': row.targetType,
                  'targetId': row.targetId,
                  'causeMemoryEntryId': row.causeMemoryEntryId,
                  'reason': row.reason,
                  'createdAt': row.createdAt,
                },
              )
              .toList(),
        };
      });

  @override
  Future<Map<String, dynamic>> mergeBySessionId(
    String sessionId,
    Map<String, dynamic> data,
  ) async {
    if (sessionId.isEmpty ||
        data['__memoryEventRegistry'] != true ||
        data['schemaVersion'] != 1 ||
        data['sessionId'] != sessionId) {
      throw const FormatException('Invalid memory event registry payload');
    }
    final events = _rows(data, 'events', MemoryEventRow.fromJson);
    final sources = _rows(data, 'sources', MemoryEventSourceRow.fromJson);
    final links = _rows(data, 'links', MemoryEventLinkRow.fromJson);
    final invalidations = _invalidationRows(data);
    if (events.isEmpty) {
      throw const FormatException('Empty memory event registry payload');
    }

    final eventIds = <String>{};
    for (final event in events) {
      if (event.sessionId != sessionId ||
          event.branchId != sessionId ||
          event.status != 'active' ||
          event.revision < 1 ||
          event.acceptedAt < 0 ||
          event.createdAt < 0 ||
          event.acceptedBy.trim().isEmpty ||
          event.id.isEmpty ||
          event.description.trim().isEmpty ||
          event.description.length > 2000 ||
          !MemoryEventRegistryRepo.eventKinds.contains(event.kind) ||
          !MemoryEventRegistryRepo.eventStates.contains(event.state) ||
          !eventIds.add(event.id)) {
        throw const FormatException('Invalid memory event row');
      }
      final hasBoundary = event.boundaryMessageId != null;
      if (hasBoundary !=
              (event.boundarySwipeId != null &&
                  event.boundaryAgentSwipeId != null &&
                  event.boundaryOrdinal != null) ||
          (event.boundarySwipeId ?? 0) < 0 ||
          (event.boundaryAgentSwipeId ?? 0) < 0 ||
          (event.boundaryOrdinal ?? 0) < 0) {
        throw const FormatException('Invalid memory event boundary');
      }
    }

    final sourceIds = <String>{};
    final sourcedEvents = <String>{};
    for (final source in sources) {
      if (source.sessionId != sessionId ||
          source.branchId != sessionId ||
          !eventIds.contains(source.eventId) ||
          source.id.isEmpty ||
          source.memoryEntryId.isEmpty ||
          source.revisionId.isEmpty ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(source.fingerprint) ||
          source.sourceSwipeId < 0 ||
          source.sourceAgentSwipeId < 0 ||
          !_validSourceJson(source) ||
          !sourceIds.add(source.id)) {
        throw const FormatException('Invalid memory event source row');
      }
      sourcedEvents.add(source.eventId);
    }
    if (!sourcedEvents.containsAll(eventIds)) {
      throw const FormatException('Memory event has no provenance source');
    }

    final linkIds = <String>{};
    for (final link in links) {
      if (link.sessionId != sessionId ||
          link.branchId != sessionId ||
          link.status != 'active' ||
          link.revision < 1 ||
          link.acceptedAt < 0 ||
          link.id.isEmpty ||
          link.fromEventId == link.toEventId ||
          !eventIds.contains(link.fromEventId) ||
          !eventIds.contains(link.toEventId) ||
          !MemoryEventRegistryRepo.relations.contains(link.relation) ||
          !linkIds.add(link.id)) {
        throw const FormatException('Invalid memory event link row');
      }
    }
    if (eventIds.intersection(sourceIds).isNotEmpty ||
        eventIds.intersection(linkIds).isNotEmpty ||
        sourceIds.intersection(linkIds).isNotEmpty) {
      throw const FormatException('Memory registry identities overlap');
    }

    final invalidationKeys = <String>{};
    for (final item in invalidations) {
      final targetExists = switch (item.targetType) {
        'event' => eventIds.contains(item.targetId),
        'link' => linkIds.contains(item.targetId),
        _ => false,
      };
      if (item.sessionId != sessionId ||
          item.branchId != sessionId ||
          !targetExists ||
          item.reason.isEmpty ||
          item.createdAt < 0 ||
          (item.causeMemoryEntryId?.trim().isEmpty ?? false) ||
          !invalidationKeys.add(item.key)) {
        throw const FormatException('Invalid memory event invalidation row');
      }
    }

    await db.transaction(() async {
      final owner = await (db.select(
        db.chatSessions,
      )..where((row) => row.sessionId.equals(sessionId))).getSingleOrNull();
      if (owner == null) {
        throw StateError('Memory event registry has no owning chat');
      }
      for (final event in events) {
        final existing = await (db.select(
          db.memoryEventRows,
        )..where((row) => row.id.equals(event.id))).getSingleOrNull();
        _verify(existing, event, 'event');
        if (existing == null) {
          await db.into(db.memoryEventRows).insert(event);
        }
      }
      for (final source in sources) {
        final existing = await (db.select(
          db.memoryEventSourceRows,
        )..where((row) => row.id.equals(source.id))).getSingleOrNull();
        _verify(existing, source, 'source');
        if (existing == null) {
          await db.into(db.memoryEventSourceRows).insert(source);
        }
      }
      for (final link in links) {
        final existing = await (db.select(
          db.memoryEventLinkRows,
        )..where((row) => row.id.equals(link.id))).getSingleOrNull();
        _verify(existing, link, 'link');
        if (existing == null) {
          await db.into(db.memoryEventLinkRows).insert(link);
        }
      }
      for (final item in invalidations) {
        final existing =
            await (db.select(db.memoryEventInvalidationRows)..where(
                  (row) =>
                      row.sessionId.equals(item.sessionId) &
                      row.branchId.equals(item.branchId) &
                      row.targetType.equals(item.targetType) &
                      row.targetId.equals(item.targetId) &
                      row.reason.equals(item.reason),
                ))
                .getSingleOrNull();
        if (existing != null) {
          if (existing.causeMemoryEntryId != item.causeMemoryEntryId ||
              existing.createdAt != item.createdAt) {
            throw StateError('Conflicting memory invalidation identity');
          }
          continue;
        }
        await db
            .into(db.memoryEventInvalidationRows)
            .insert(
              MemoryEventInvalidationRowsCompanion.insert(
                sessionId: item.sessionId,
                branchId: item.branchId,
                targetType: item.targetType,
                targetId: item.targetId,
                causeMemoryEntryId: Value(item.causeMemoryEntryId),
                reason: item.reason,
                createdAt: item.createdAt,
              ),
            );
      }
    });
    return (await getBySessionId(sessionId))!;
  }

  @override
  Future<void> deleteBySessionId(String sessionId) => db.transaction(() async {
    await (db.delete(
      db.memoryEventInvalidationRows,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (db.delete(
      db.memoryEventLinkRows,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (db.delete(
      db.memoryEventSourceRows,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (db.delete(
      db.memoryEventRows,
    )..where((row) => row.sessionId.equals(sessionId))).go();
  });

  static bool _validSourceJson(MemoryEventSourceRow source) {
    try {
      final ids = jsonDecode(source.messageIdsJson);
      final manifestJson = jsonDecode(source.sourceManifestJson);
      if (ids is! List ||
          ids.isEmpty ||
          ids.any((id) => id is! String || id.trim().isEmpty)) {
        return false;
      }
      if (manifestJson is! Map<String, dynamic>) return false;
      final manifest = MemorySourceManifest.fromJson(manifestJson);
      return manifest.version == 1 &&
          manifest.originSessionId.trim().isNotEmpty &&
          manifest.messages.length == ids.length &&
          manifest.messages.asMap().entries.every(
            (entry) =>
                entry.value.messageId == ids[entry.key] &&
                entry.value.messageId.trim().isNotEmpty &&
                entry.value.swipeId >= 0 &&
                entry.value.agentSwipeId >= 0 &&
                RegExp(r'^[0-9a-f]{64}$').hasMatch(entry.value.contentHash),
          );
    } on Object {
      return false;
    }
  }

  static void _verify(DataClass? existing, DataClass incoming, String kind) {
    if (existing != null &&
        jsonEncode(existing.toJson()) != jsonEncode(incoming.toJson())) {
      throw StateError('Conflicting memory $kind identity');
    }
  }

  static List<T> _rows<T>(
    Map<String, dynamic> data,
    String key,
    T Function(Map<String, dynamic>) decode,
  ) {
    final raw = data[key];
    if (raw is! List) throw FormatException('Missing memory registry $key');
    return raw.map((value) {
      if (value is! Map<String, dynamic>) {
        throw FormatException('Invalid memory registry $key row');
      }
      return decode(value);
    }).toList();
  }

  static List<_PortableInvalidation> _invalidationRows(
    Map<String, dynamic> data,
  ) {
    final raw = data['invalidations'];
    if (raw is! List) {
      throw const FormatException('Missing memory registry invalidations');
    }
    return raw.map((value) {
      if (value is! Map<String, dynamic>) {
        throw const FormatException('Invalid memory registry invalidation');
      }
      return _PortableInvalidation(
        sessionId: value['sessionId'] as String,
        branchId: value['branchId'] as String,
        targetType: value['targetType'] as String,
        targetId: value['targetId'] as String,
        causeMemoryEntryId: value['causeMemoryEntryId'] as String?,
        reason: value['reason'] as String,
        createdAt: value['createdAt'] as int,
      );
    }).toList();
  }
}

class _PortableInvalidation {
  const _PortableInvalidation({
    required this.sessionId,
    required this.branchId,
    required this.targetType,
    required this.targetId,
    required this.causeMemoryEntryId,
    required this.reason,
    required this.createdAt,
  });

  final String sessionId;
  final String branchId;
  final String targetType;
  final String targetId;
  final String? causeMemoryEntryId;
  final String reason;
  final int createdAt;

  String get key =>
      '$sessionId\u0000$branchId\u0000$targetType\u0000$targetId\u0000$reason';
}
