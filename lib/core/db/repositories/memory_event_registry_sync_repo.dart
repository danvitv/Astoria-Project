import 'dart:convert';

import 'package:crypto/crypto.dart';
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
    var events = _rows(data, 'events', MemoryEventRow.fromJson);
    var sources = _rows(data, 'sources', MemoryEventSourceRow.fromJson);
    var links = _rows(data, 'links', MemoryEventLinkRow.fromJson);
    var invalidations = _invalidationRows(data);
    if (events.isEmpty) {
      throw const FormatException('Empty memory event registry payload');
    }

    _validatePayloadRows(sessionId, events, sources, links, invalidations);

    await db.transaction(() async {
      final owner = await (db.select(
        db.chatSessions,
      )..where((row) => row.sessionId.equals(sessionId))).getSingleOrNull();
      if (owner == null) {
        throw StateError('Memory event registry has no owning chat');
      }
      final resolved = await _resolveLegacyEventCollisions(
        events: events,
        sources: sources,
        links: links,
        invalidations: invalidations,
      );
      events = resolved.events;
      sources = resolved.sources;
      links = resolved.links;
      invalidations = resolved.invalidations;
      // Collision migration rewrites identities and references. Re-run the
      // complete wire invariants before any transformed row is persisted.
      _validatePayloadRows(sessionId, events, sources, links, invalidations);
      for (final event in events) {
        final existing = await (db.select(
          db.memoryEventRows,
        )..where((row) => row.id.equals(event.id))).getSingleOrNull();
        _verifyEvent(existing, event);
        if (existing == null) {
          await db.into(db.memoryEventRows).insert(event);
        } else if (_incomingEventMetadataWins(existing, event)) {
          await (db.update(
            db.memoryEventRows,
          )..where((row) => row.id.equals(event.id))).write(
            MemoryEventRowsCompanion(
              acceptedAt: Value(event.acceptedAt),
              acceptedBy: Value(event.acceptedBy),
              createdAt: Value(event.createdAt),
            ),
          );
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
        _verifyLink(existing, link);
        if (existing == null) {
          await db.into(db.memoryEventLinkRows).insert(link);
        } else if (link.acceptedAt < existing.acceptedAt) {
          await (db.update(
            db.memoryEventLinkRows,
          )..where((row) => row.id.equals(link.id))).write(
            MemoryEventLinkRowsCompanion(acceptedAt: Value(link.acceptedAt)),
          );
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
          if (existing.causeMemoryEntryId != item.causeMemoryEntryId) {
            throw StateError('Conflicting memory invalidation identity');
          }
          if (item.createdAt < existing.createdAt) {
            await (db.update(
              db.memoryEventInvalidationRows,
            )..where((row) => row.id.equals(existing.id))).write(
              MemoryEventInvalidationRowsCompanion(
                createdAt: Value(item.createdAt),
              ),
            );
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

  Future<
    ({
      List<MemoryEventRow> events,
      List<MemoryEventSourceRow> sources,
      List<MemoryEventLinkRow> links,
      List<_PortableInvalidation> invalidations,
    })
  >
  _resolveLegacyEventCollisions({
    required List<MemoryEventRow> events,
    required List<MemoryEventSourceRow> sources,
    required List<MemoryEventLinkRow> links,
    required List<_PortableInvalidation> invalidations,
  }) async {
    final localEventIds = <String, String>{};
    final incomingEventIds = <String, String>{};
    for (final incoming in events) {
      final incomingSources = sources
          .where((source) => source.eventId == incoming.id)
          .toList(growable: false);
      final incomingVariantId = incomingSources.isEmpty
          ? null
          : _variantEventId(incoming, incomingSources);
      final existing = await (db.select(
        db.memoryEventRows,
      )..where((row) => row.id.equals(incoming.id))).getSingleOrNull();
      if (existing == null) {
        if (incomingVariantId != null && incomingVariantId != incoming.id) {
          final variant =
              await (db.select(db.memoryEventRows)
                    ..where((row) => row.id.equals(incomingVariantId)))
                  .getSingleOrNull();
          if (variant != null) {
            _verifyEvent(variant, incoming.copyWith(id: incomingVariantId));
            incomingEventIds[incoming.id] = incomingVariantId;
          }
        } else if (incomingVariantId == incoming.id) {
          final localEvents =
              await (db.select(db.memoryEventRows)..where(
                    (row) =>
                        row.sessionId.equals(incoming.sessionId) &
                        row.branchId.equals(incoming.branchId),
                  ))
                  .get();
          for (final local in localEvents) {
            final localSources = await (db.select(
              db.memoryEventSourceRows,
            )..where((row) => row.eventId.equals(local.id))).get();
            if (localSources.isNotEmpty &&
                _variantEventId(local, localSources) == incoming.id) {
              _verifyEvent(local.copyWith(id: incoming.id), incoming);
              localEventIds[local.id] = incoming.id;
              break;
            }
          }
        }
        continue;
      }
      if (_eventsEquivalent(existing, incoming)) continue;
      final localSources = await (db.select(
        db.memoryEventSourceRows,
      )..where((row) => row.eventId.equals(existing.id))).get();
      if (localSources.isEmpty || incomingSources.isEmpty) {
        _verifyEvent(existing, incoming);
      }
      final localVariantId = _variantEventId(existing, localSources);
      final resolvedIncomingVariantId = incomingVariantId!;
      if (localVariantId == resolvedIncomingVariantId) {
        _verifyEvent(existing, incoming);
      }
      localEventIds[existing.id] = localVariantId;
      incomingEventIds[incoming.id] = resolvedIncomingVariantId;
    }
    if (localEventIds.isEmpty && incomingEventIds.isEmpty) {
      return (
        events: events,
        sources: sources,
        links: links,
        invalidations: invalidations,
      );
    }

    if (localEventIds.isNotEmpty) await _rekeyLocalGraph(localEventIds);
    final rewrittenSources = <MemoryEventSourceRow>[];
    for (final source in sources) {
      final eventId = incomingEventIds[source.eventId];
      if (eventId == null) {
        rewrittenSources.add(source);
        continue;
      }
      final id = _variantChildId('source', source.id, eventId);
      rewrittenSources.add(source.copyWith(id: id, eventId: eventId));
    }
    final incomingLinkIds = <String, String>{};
    final rewrittenLinks = <MemoryEventLinkRow>[];
    for (final link in links) {
      final from = incomingEventIds[link.fromEventId] ?? link.fromEventId;
      final to = incomingEventIds[link.toEventId] ?? link.toEventId;
      if (from == link.fromEventId && to == link.toEventId) {
        rewrittenLinks.add(link);
        continue;
      }
      final id = _variantLinkId(link.id, from, to, link.relation);
      incomingLinkIds[link.id] = id;
      rewrittenLinks.add(
        link.copyWith(id: id, fromEventId: from, toEventId: to),
      );
    }
    return (
      events: [
        for (final event in events)
          event.copyWith(id: incomingEventIds[event.id] ?? event.id),
      ],
      sources: rewrittenSources,
      links: rewrittenLinks,
      invalidations: [
        for (final item in invalidations)
          item.copyWith(
            targetId: switch (item.targetType) {
              'event' => incomingEventIds[item.targetId] ?? item.targetId,
              'link' => incomingLinkIds[item.targetId] ?? item.targetId,
              _ => item.targetId,
            },
          ),
      ],
    );
  }

  Future<void> _rekeyLocalGraph(Map<String, String> eventIds) async {
    for (final target in eventIds.values) {
      final occupied = await (db.select(
        db.memoryEventRows,
      )..where((row) => row.id.equals(target))).getSingleOrNull();
      if (occupied != null) {
        throw StateError('Memory event variant identity is already occupied');
      }
    }
    final sources = await (db.select(
      db.memoryEventSourceRows,
    )..where((row) => row.eventId.isIn(eventIds.keys))).get();
    final sourceIds = {
      for (final source in sources)
        source.id: _variantChildId(
          'source',
          source.id,
          eventIds[source.eventId]!,
        ),
    };
    final links =
        await (db.select(db.memoryEventLinkRows)..where(
              (row) =>
                  row.fromEventId.isIn(eventIds.keys) |
                  row.toEventId.isIn(eventIds.keys),
            ))
            .get();
    final linkIds = <String, String>{};
    for (final link in links) {
      final from = eventIds[link.fromEventId] ?? link.fromEventId;
      final to = eventIds[link.toEventId] ?? link.toEventId;
      linkIds[link.id] = _variantLinkId(link.id, from, to, link.relation);
    }
    for (final entry in sourceIds.entries) {
      final occupied = await (db.select(
        db.memoryEventSourceRows,
      )..where((row) => row.id.equals(entry.value))).getSingleOrNull();
      if (occupied != null) {
        throw StateError('Memory source variant identity is already occupied');
      }
    }
    for (final entry in linkIds.entries) {
      final occupied = await (db.select(
        db.memoryEventLinkRows,
      )..where((row) => row.id.equals(entry.value))).getSingleOrNull();
      if (occupied != null) {
        throw StateError('Memory link variant identity is already occupied');
      }
    }

    for (final row
        in await (db.select(db.memoryEventInvalidationRows)..where(
              (row) =>
                  row.targetType.equals('event') &
                      row.targetId.isIn(eventIds.keys) |
                  row.targetType.equals('link') &
                      row.targetId.isIn(linkIds.keys),
            ))
            .get()) {
      final targetId = row.targetType == 'event'
          ? eventIds[row.targetId]!
          : linkIds[row.targetId]!;
      await (db.update(
        db.memoryEventInvalidationRows,
      )..where((item) => item.id.equals(row.id))).write(
        MemoryEventInvalidationRowsCompanion(targetId: Value(targetId)),
      );
    }
    for (final source in sources) {
      await (db.update(
        db.memoryEventSourceRows,
      )..where((row) => row.id.equals(source.id))).write(
        MemoryEventSourceRowsCompanion(
          id: Value(sourceIds[source.id]!),
          eventId: Value(eventIds[source.eventId]!),
        ),
      );
    }
    for (final link in links) {
      await (db.update(
        db.memoryEventLinkRows,
      )..where((row) => row.id.equals(link.id))).write(
        MemoryEventLinkRowsCompanion(
          id: Value(linkIds[link.id]!),
          fromEventId: Value(eventIds[link.fromEventId] ?? link.fromEventId),
          toEventId: Value(eventIds[link.toEventId] ?? link.toEventId),
        ),
      );
    }
    for (final entry in eventIds.entries) {
      await (db.update(db.memoryEventRows)
            ..where((row) => row.id.equals(entry.key)))
          .write(MemoryEventRowsCompanion(id: Value(entry.value)));
    }
  }

  static String _variantEventId(
    MemoryEventRow event,
    List<MemoryEventSourceRow> sources,
  ) {
    final sourceIdentity =
        sources
            .map(
              (source) =>
                  '${source.memoryEntryId}|${source.revisionId}|${source.fingerprint}',
            )
            .toList()
          ..sort();
    final semantic = _eventSemanticJson(event)..remove('id');
    final digest = sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'version': 1,
              'event': semantic,
              'sources': sourceIdentity,
            }),
          ),
        )
        .toString();
    return 'event-${digest.substring(0, 24)}';
  }

  static String _variantChildId(String kind, String oldId, String eventId) {
    final digest = sha256
        .convert(utf8.encode('memory-$kind-variant-v1|$oldId|$eventId'))
        .toString();
    return '$kind-${digest.substring(0, 24)}';
  }

  static String _variantLinkId(
    String oldId,
    String fromEventId,
    String toEventId,
    String relation,
  ) {
    final digest = sha256
        .convert(
          utf8.encode(
            'memory-link-variant-v1|$oldId|$fromEventId|$toEventId|$relation',
          ),
        )
        .toString();
    return 'link-${digest.substring(0, 24)}';
  }

  static void _validatePayloadRows(
    String sessionId,
    List<MemoryEventRow> events,
    List<MemoryEventSourceRow> sources,
    List<MemoryEventLinkRow> links,
    List<_PortableInvalidation> invalidations,
  ) {
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
  }

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
      throw StateError(
        'Conflicting memory $kind identity '
        '(${_differentFields(existing.toJson(), incoming.toJson()).join(', ')})',
      );
    }
  }

  static void _verifyEvent(MemoryEventRow? existing, MemoryEventRow incoming) {
    if (existing == null) return;
    final local = _eventSemanticJson(existing);
    final remote = _eventSemanticJson(incoming);
    if (!_eventsEquivalent(existing, incoming)) {
      throw StateError(
        'Conflicting memory event identity '
        '(${_differentFields(local, remote).join(', ')})',
      );
    }
  }

  static bool _eventsEquivalent(MemoryEventRow local, MemoryEventRow remote) =>
      jsonEncode(_eventSemanticJson(local)) ==
      jsonEncode(_eventSemanticJson(remote));

  static Map<String, dynamic> _eventSemanticJson(MemoryEventRow event) =>
      Map<String, dynamic>.from(event.toJson())
        ..remove('acceptedAt')
        ..remove('acceptedBy')
        ..remove('createdAt');

  static void _verifyLink(
    MemoryEventLinkRow? existing,
    MemoryEventLinkRow incoming,
  ) {
    if (existing == null) return;
    final local = Map<String, dynamic>.from(existing.toJson())
      ..remove('acceptedAt');
    final remote = Map<String, dynamic>.from(incoming.toJson())
      ..remove('acceptedAt');
    if (jsonEncode(local) != jsonEncode(remote)) {
      throw StateError(
        'Conflicting memory link identity '
        '(${_differentFields(local, remote).join(', ')})',
      );
    }
  }

  static bool _incomingEventMetadataWins(
    MemoryEventRow existing,
    MemoryEventRow incoming,
  ) {
    if (incoming.acceptedAt != existing.acceptedAt) {
      return incoming.acceptedAt < existing.acceptedAt;
    }
    if (incoming.createdAt != existing.createdAt) {
      return incoming.createdAt < existing.createdAt;
    }
    return incoming.acceptedBy.compareTo(existing.acceptedBy) < 0;
  }

  static List<String> _differentFields(
    Map<String, dynamic> local,
    Map<String, dynamic> remote,
  ) =>
      ({...local.keys, ...remote.keys}
          .where((key) => jsonEncode(local[key]) != jsonEncode(remote[key]))
          .toList()
        ..sort());

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

  _PortableInvalidation copyWith({String? targetId}) => _PortableInvalidation(
    sessionId: sessionId,
    branchId: branchId,
    targetType: targetType,
    targetId: targetId ?? this.targetId,
    causeMemoryEntryId: causeMemoryEntryId,
    reason: reason,
    createdAt: createdAt,
  );

  String get key =>
      '$sessionId\u0000$branchId\u0000$targetType\u0000$targetId\u0000$reason';
}
