import 'dart:convert';

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
  final List<MemoryConsolidationSource> sources;
  final List<MemoryConsolidationEventCandidate> candidates;
  final List<String> unexaminedOpenObligationIds;

  MemoryConsolidationSourcePack({
    required this.packId,
    required this.sessionId,
    required this.branchId,
    required this.proposedEventId,
    required List<MemoryConsolidationSource> sources,
    required List<MemoryConsolidationEventCandidate> candidates,
    required List<String> unexaminedOpenObligationIds,
  }) : sources = List.unmodifiable(sources),
       candidates = List.unmodifiable(candidates),
       unexaminedOpenObligationIds = List.unmodifiable(
         unexaminedOpenObligationIds,
       );

  Map<String, dynamic> toJson() => {
    'packId': packId,
    'sessionId': sessionId,
    'branchId': branchId,
    'proposedEventId': proposedEventId,
    'sources': sources.map((source) => source.toJson()).toList(),
    'candidates': candidates.map((candidate) => candidate.toJson()).toList(),
    'unexaminedOpenObligationIds': unexaminedOpenObligationIds,
  };

  String toJsonString() => jsonEncode(toJson());
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
