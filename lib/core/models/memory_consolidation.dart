import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../db/repositories/memory_event_registry_repo.dart';
import 'memory_source_manifest.dart';

/// Immutable, fully-qualified source supplied to a consolidation request.
///
/// The pack carries the complete active revision text. A model must never be
/// asked to validate a relation from a shortened memory card alone.
class MemoryConsolidationSource {
  final String ref;
  final String sessionId;
  final String branchId;
  final String memoryEntryId;
  final String revisionId;
  final String fingerprint;
  final String title;
  final String content;
  final List<String> messageIds;
  final String? sceneTime;
  final int sourceSwipeId;
  final int sourceAgentSwipeId;
  final MemorySourceManifest sourceManifest;

  MemoryConsolidationSource({
    required this.ref,
    required this.sessionId,
    required this.branchId,
    required this.memoryEntryId,
    required this.revisionId,
    required this.fingerprint,
    required this.title,
    required this.content,
    required List<String> messageIds,
    this.sceneTime,
    required this.sourceSwipeId,
    required this.sourceAgentSwipeId,
    required this.sourceManifest,
  }) : messageIds = List.unmodifiable(messageIds);

  MemoryEventSourceInput toRegistryInput(String eventId) =>
      MemoryEventSourceInput(
        id: '$eventId::source::$ref',
        memoryEntryId: memoryEntryId,
        revisionId: revisionId,
        fingerprint: fingerprint,
        messageIds: messageIds,
        sourceSwipeId: sourceSwipeId,
        sourceAgentSwipeId: sourceAgentSwipeId,
      );

  factory MemoryConsolidationSource.fromJson(Map<String, dynamic> json) =>
      MemoryConsolidationSource(
        ref: _requiredString(json, 'ref'),
        sessionId: _requiredString(json, 'sessionId'),
        branchId: _requiredString(json, 'branchId'),
        memoryEntryId: _requiredString(json, 'memoryEntryId'),
        revisionId: _requiredString(json, 'revisionId'),
        fingerprint: _requiredString(json, 'fingerprint'),
        title: _requiredString(json, 'title'),
        content: _requiredString(json, 'content'),
        messageIds: [
          for (final id in (json['messageIds'] as List).cast<String>())
            _requiredString({'id': id}, 'id'),
        ],
        sceneTime: json['sceneTime'] as String?,
        sourceSwipeId: json['sourceSwipeId'] as int,
        sourceAgentSwipeId: json['sourceAgentSwipeId'] as int,
        sourceManifest: MemorySourceManifest.fromJson(
          json['sourceManifest'] as Map<String, dynamic>,
        ),
      );

  Map<String, dynamic> toJson() => {
    'ref': ref,
    'sessionId': sessionId,
    'branchId': branchId,
    'memoryEntryId': memoryEntryId,
    'revisionId': revisionId,
    'fingerprint': fingerprint,
    'title': title,
    'content': content,
    'messageIds': messageIds,
    if (sceneTime != null) 'sceneTime': sceneTime,
    'sourceSwipeId': sourceSwipeId,
    'sourceAgentSwipeId': sourceAgentSwipeId,
    'sourceManifest': sourceManifest.toJson(),
  };
}

/// A bounded card for an already accepted event. Its source refs point to
/// full source records also present in the pack.
class MemoryConsolidationEventCandidate {
  final String id;
  final String kind;
  final String description;
  final String state;
  final List<String> sourceRefs;
  final List<String> linkedEventIds;

  const MemoryConsolidationEventCandidate({
    required this.id,
    required this.kind,
    required this.description,
    required this.state,
    required this.sourceRefs,
    this.linkedEventIds = const [],
  });

  factory MemoryConsolidationEventCandidate.fromJson(
    Map<String, dynamic> json,
  ) => MemoryConsolidationEventCandidate(
    id: _requiredString(json, 'id'),
    kind: _requiredString(json, 'kind'),
    description: _requiredString(json, 'description'),
    state: _requiredString(json, 'state'),
    sourceRefs: (json['sourceRefs'] as List).cast<String>(),
    linkedEventIds: (json['linkedEventIds'] as List).cast<String>(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'description': description,
    'state': state,
    'sourceRefs': sourceRefs,
    'linkedEventIds': linkedEventIds,
  };
}

/// Main-isolate input to one consolidation call. Drafts and leases are not
/// represented here and therefore cannot accidentally cross a sync boundary.
class MemoryConsolidationSourcePack {
  final String packId;
  final String sessionId;
  final String branchId;
  final String proposedEventId;
  final List<String> proposedEventIds;
  final List<MemoryConsolidationSource> sources;
  final List<MemoryConsolidationEventCandidate> candidates;
  final List<String> unexaminedOpenObligationIds;

  MemoryConsolidationSourcePack({
    required this.packId,
    required this.sessionId,
    required this.branchId,
    required this.proposedEventId,
    List<String>? proposedEventIds,
    required List<MemoryConsolidationSource> sources,
    required List<MemoryConsolidationEventCandidate> candidates,
    required List<String> unexaminedOpenObligationIds,
  }) : proposedEventIds = List.unmodifiable(
         proposedEventIds ?? [proposedEventId],
       ),
       sources = List.unmodifiable(sources),
       candidates = List.unmodifiable(candidates),
       unexaminedOpenObligationIds = List.unmodifiable(
         unexaminedOpenObligationIds,
       );

  /// Rebuilds the frozen pack stored beside a package draft. The registry
  /// transaction re-verifies live sources at acceptance time; this only
  /// restores the exact context the reviewed response was parsed against.
  factory MemoryConsolidationSourcePack.fromJson(Map<String, dynamic> json) =>
      MemoryConsolidationSourcePack(
        packId: _requiredString(json, 'packId'),
        sessionId: _requiredString(json, 'sessionId'),
        branchId: _requiredString(json, 'branchId'),
        proposedEventId: _requiredString(json, 'proposedEventId'),
        proposedEventIds: (json['proposedEventIds'] as List).cast<String>(),
        sources: [
          for (final source in (json['sources'] as List))
            MemoryConsolidationSource.fromJson(source as Map<String, dynamic>),
        ],
        candidates: [
          for (final candidate in (json['candidates'] as List))
            MemoryConsolidationEventCandidate.fromJson(
              candidate as Map<String, dynamic>,
            ),
        ],
        unexaminedOpenObligationIds:
            (json['unexaminedOpenObligationIds'] as List).cast<String>(),
      );

  Map<String, dynamic> toJson() => {
    'packId': packId,
    'sessionId': sessionId,
    'branchId': branchId,
    'proposedEventId': proposedEventId,
    'proposedEventIds': proposedEventIds,
    'proposedEventAllocations': [
      for (var i = 0; i < proposedEventIds.length; i++)
        {'eventId': proposedEventIds[i], 'sourceRef': sources[i].ref},
    ],
    'sources': sources.map((source) => source.toJson()).toList(),
    'candidates': candidates.map((candidate) => candidate.toJson()).toList(),
    'unexaminedOpenObligationIds': unexaminedOpenObligationIds,
  };

  String toJsonString() => jsonEncode(toJson());
}

/// One event operation in a package-level consolidation response.
class MemoryConsolidationPackageEventOperation {
  final String eventId;
  final String kind;
  final String description;
  final String state;
  final List<String> sourceRefs;
  final String? boundaryMessageId;
  final int? boundarySwipeId;
  final int? boundaryAgentSwipeId;
  final int? boundaryOrdinal;

  const MemoryConsolidationPackageEventOperation({
    required this.eventId,
    required this.kind,
    required this.description,
    required this.state,
    required this.sourceRefs,
    this.boundaryMessageId,
    this.boundarySwipeId,
    this.boundaryAgentSwipeId,
    this.boundaryOrdinal,
  });
}

class MemoryConsolidationPackageResponse {
  final String contract;
  final int version;
  final String outcome;
  final List<MemoryConsolidationPackageEventOperation> events;
  final List<MemoryConsolidationLinkOperation> links;
  final List<String> unverifiedSourceRefs;
  final List<String> unexaminedOpenObligationIds;

  const MemoryConsolidationPackageResponse({
    required this.contract,
    required this.version,
    required this.outcome,
    required this.events,
    required this.links,
    required this.unverifiedSourceRefs,
    required this.unexaminedOpenObligationIds,
  });

  /// Canonical strict-contract JSON for this parsed response, suitable for
  /// storing beside its pack and re-parsing through the same strict parser.
  Map<String, dynamic> toStrictJson() => {
    'contract': contract,
    'version': version,
    'outcome': outcome,
    'events': [
      for (final event in events)
        {
          'eventId': event.eventId,
          'kind': event.kind,
          'description': event.description,
          'state': event.state,
          'sourceRefs': event.sourceRefs,
          'boundary': event.boundaryMessageId == null
              ? null
              : {
                  'messageId': event.boundaryMessageId,
                  'swipeId': event.boundarySwipeId,
                  'agentSwipeId': event.boundaryAgentSwipeId,
                  'ordinal': event.boundaryOrdinal,
                },
        },
    ],
    'links': [
      for (final link in links)
        {
          'linkId': link.linkId,
          'fromEventId': link.fromEventId,
          'toEventId': link.toEventId,
          'relation': link.relation,
        },
    ],
    'unverifiedSourceRefs': unverifiedSourceRefs,
    'unexaminedOpenObligationIds': unexaminedOpenObligationIds,
  };

  List<MemoryEventInput> toRegistryEvents(MemoryConsolidationSourcePack pack) {
    final sourceByRef = {for (final source in pack.sources) source.ref: source};
    return [
      for (final event in events)
        MemoryEventInput(
          id: event.eventId,
          sessionId: pack.sessionId,
          branchId: pack.branchId,
          kind: event.kind,
          description: event.description,
          state: event.state,
          sources: [
            for (final ref in event.sourceRefs)
              sourceByRef[ref]!.toRegistryInput(event.eventId),
          ],
          boundaryMessageId: event.boundaryMessageId,
          boundarySwipeId: event.boundarySwipeId,
          boundaryAgentSwipeId: event.boundaryAgentSwipeId,
          boundaryOrdinal: event.boundaryOrdinal,
        ),
    ];
  }

  /// Model link IDs are request-local labels only. Durable IDs are derived by
  /// the app from the frozen pack and link operation, so a model cannot collide
  /// with an already accepted global registry ID by returning `link-1` again.
  List<MemoryEventLinkInput> toRegistryLinks(
    MemoryConsolidationSourcePack pack,
  ) => [
    for (final (index, link) in links.indexed)
      MemoryEventLinkInput(
        id: _durablePackageLinkId(pack, link, index),
        fromEventId: link.fromEventId,
        toEventId: link.toEventId,
        relation: link.relation,
      ),
  ];

  static String _durablePackageLinkId(
    MemoryConsolidationSourcePack pack,
    MemoryConsolidationLinkOperation link,
    int index,
  ) {
    final digest = sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'packId': pack.packId,
              'index': index,
              'requestLinkId': link.linkId,
              'fromEventId': link.fromEventId,
              'toEventId': link.toEventId,
              'relation': link.relation,
            }),
          ),
        )
        .toString();
    return 'link-${digest.substring(0, 24)}';
  }
}

/// A parsed, strict response operation that can still be displayed as a
/// review draft. It is not persisted or accepted until [toRegistryChange] is
/// called and the repository rechecks every source in a transaction.
class MemoryConsolidationEventOperation {
  final String eventId;
  final String kind;
  final String description;
  final String state;
  final List<String> sourceRefs;
  final String? boundaryMessageId;
  final int? boundarySwipeId;
  final int? boundaryAgentSwipeId;
  final int? boundaryOrdinal;

  const MemoryConsolidationEventOperation({
    required this.eventId,
    required this.kind,
    required this.description,
    required this.state,
    required this.sourceRefs,
    this.boundaryMessageId,
    this.boundarySwipeId,
    this.boundaryAgentSwipeId,
    this.boundaryOrdinal,
  });
}

class MemoryConsolidationLinkOperation {
  final String linkId;
  final String fromEventId;
  final String toEventId;
  final String relation;

  const MemoryConsolidationLinkOperation({
    required this.linkId,
    required this.fromEventId,
    required this.toEventId,
    required this.relation,
  });
}

class MemoryConsolidationResponse {
  final String contract;
  final int version;
  final String outcome;
  final MemoryConsolidationEventOperation? event;
  final List<MemoryConsolidationLinkOperation> links;
  final List<String> unverifiedSourceRefs;
  final List<String> unexaminedOpenObligationIds;

  const MemoryConsolidationResponse({
    required this.contract,
    required this.version,
    required this.outcome,
    required this.event,
    required this.links,
    required this.unverifiedSourceRefs,
    required this.unexaminedOpenObligationIds,
  });

  /// Converts the reviewed model output into the persistence DTOs. The DB
  /// repository remains the final authority and repeats all source checks.
  MemoryConsolidationRegistryChange toRegistryChange(
    MemoryConsolidationSourcePack pack,
  ) {
    final operation = event;
    if (operation == null) {
      throw StateError('Consolidation response has no event operation.');
    }
    final sourceByRef = {for (final source in pack.sources) source.ref: source};
    final sources = operation.sourceRefs
        .map((ref) => sourceByRef[ref])
        .map((source) {
          if (source == null) {
            throw StateError('Consolidation source disappeared from the pack.');
          }
          return source.toRegistryInput(operation.eventId);
        })
        .toList(growable: false);
    return MemoryConsolidationRegistryChange(
      event: MemoryEventInput(
        id: operation.eventId,
        sessionId: pack.sessionId,
        branchId: pack.branchId,
        kind: operation.kind,
        description: operation.description,
        state: operation.state,
        sources: sources,
        boundaryMessageId: operation.boundaryMessageId,
        boundarySwipeId: operation.boundarySwipeId,
        boundaryAgentSwipeId: operation.boundaryAgentSwipeId,
        boundaryOrdinal: operation.boundaryOrdinal,
      ),
      links: operationLinks(),
    );
  }

  List<MemoryEventLinkInput> operationLinks() => [
    for (final link in links)
      MemoryEventLinkInput(
        id: link.linkId,
        fromEventId: link.fromEventId,
        toEventId: link.toEventId,
        relation: link.relation,
      ),
  ];
}

class MemoryConsolidationRegistryChange {
  final MemoryEventInput event;
  final List<MemoryEventLinkInput> links;

  const MemoryConsolidationRegistryChange({
    required this.event,
    required this.links,
  });
}

/// Shared strict read for persisted pack fields: a stored envelope that lost a
/// field is corrupt and must fail loudly instead of silently degrading.
String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('Consolidation pack field "$key" is missing.');
  }
  return value;
}
