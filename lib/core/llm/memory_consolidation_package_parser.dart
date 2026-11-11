import 'dart:convert';

import '../db/repositories/memory_event_registry_repo.dart';
import '../models/memory_consolidation.dart';

class MemoryConsolidationPackageParser {
  const MemoryConsolidationPackageParser._();

  static const contract = 'memory_event_consolidation';
  static const version = 2;

  static MemoryConsolidationPackageResponse parse(
    String raw,
    MemoryConsolidationSourcePack pack,
  ) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('Expected an object.');
    final root = Map<String, dynamic>.from(decoded);
    _keys(root, {
      'contract',
      'version',
      'outcome',
      'events',
      'links',
      'unverifiedSourceRefs',
      'unexaminedOpenObligationIds',
    });
    if (root['contract'] != contract || root['version'] != version) {
      throw const FormatException('Unsupported package contract.');
    }
    final outcome = _string(root['outcome']);
    if (!const {
      'confirmed',
      'independent_similarity',
      'unable_to_verify',
    }.contains(outcome)) {
      throw const FormatException('Invalid package outcome.');
    }
    final obligations = _strings(root['unexaminedOpenObligationIds']);
    if (!_sameSet(obligations, pack.unexaminedOpenObligationIds)) {
      throw const FormatException('Package changed obligation boundary.');
    }
    final unverified = _strings(root['unverifiedSourceRefs']);
    final selectedSources = pack.sources
        .where((source) => source.ref.startsWith('entry:'))
        .toList(growable: false);
    final selectedRefs = selectedSources.map((source) => source.ref).toSet();
    if (unverified.toSet().length != unverified.length ||
        !unverified.every(selectedRefs.contains)) {
      throw const FormatException('Invalid unverified source refs.');
    }
    if (selectedRefs.isEmpty ||
        selectedRefs.length != pack.proposedEventIds.length) {
      throw const FormatException(
        'Pack must allocate an event ID for every selected source.',
      );
    }
    final rawEvents = root['events'];
    if (rawEvents is! List || rawEvents.length > pack.proposedEventIds.length) {
      throw const FormatException('Invalid package events.');
    }
    final sourcesByRef = {
      for (final source in pack.sources) source.ref: source,
    };
    final events = <MemoryConsolidationPackageEventOperation>[];
    final usedRefs = <String>{};
    final eventIds = <String>{};
    for (final rawEvent in rawEvents) {
      if (rawEvent is! Map) throw const FormatException('Invalid event.');
      final event = Map<String, dynamic>.from(rawEvent);
      _keys(event, {
        'eventId',
        'kind',
        'description',
        'state',
        'sourceRefs',
        'boundary',
      });
      final eventId = _bounded(event['eventId'], 128);
      if (!pack.proposedEventIds.contains(eventId) || !eventIds.add(eventId)) {
        throw const FormatException(
          'Event ID was not allocated or is duplicated.',
        );
      }
      final kind = _string(event['kind']);
      final state = _string(event['state']);
      if (!MemoryEventRegistryRepo.eventKinds.contains(kind) ||
          !MemoryEventRegistryRepo.eventStates.contains(state)) {
        throw const FormatException('Invalid event kind or state.');
      }
      final description = _bounded(event['description'], 2000);
      final refs = _strings(event['sourceRefs']);
      if (refs.isEmpty ||
          refs.toSet().length != refs.length ||
          refs.any((ref) => !sourcesByRef.containsKey(ref))) {
        throw const FormatException('Event has invalid or reused sources.');
      }
      final allocationIndex = pack.proposedEventIds.indexOf(eventId);
      final allocatedSourceRef = selectedSources[allocationIndex].ref;
      if (!refs.contains(allocatedSourceRef)) {
        throw const FormatException(
          'Event does not cite the source allocated to its ID.',
        );
      }
      for (final ref in refs.where(selectedRefs.contains)) {
        if (!usedRefs.add(ref)) {
          throw const FormatException(
            'A selected source may support only one event.',
          );
        }
      }
      final boundary = _boundary(event['boundary'], refs, sourcesByRef);
      events.add(
        MemoryConsolidationPackageEventOperation(
          eventId: eventId,
          kind: kind,
          description: description,
          state: state,
          sourceRefs: List.unmodifiable(refs),
          boundaryMessageId: boundary?['messageId'] as String?,
          boundarySwipeId: boundary?['swipeId'] as int?,
          boundaryAgentSwipeId: boundary?['agentSwipeId'] as int?,
          boundaryOrdinal: boundary?['ordinal'] as int?,
        ),
      );
    }
    if (usedRefs.intersection(unverified.toSet()).isNotEmpty ||
        usedRefs.union(unverified.toSet()).length != selectedRefs.length ||
        !usedRefs.union(unverified.toSet()).containsAll(selectedRefs)) {
      throw const FormatException(
        'Every selected source must be accounted for once.',
      );
    }
    if ((outcome == 'unable_to_verify' &&
            (events.isNotEmpty ||
                linksFrom(root['links']) ||
                unverified.length != selectedRefs.length)) ||
        (outcome != 'unable_to_verify' && events.isEmpty)) {
      throw const FormatException(
        'Outcome does not match package event coverage.',
      );
    }
    final links = _links(root['links'], pack, {...eventIds});
    final independent = links.any(
      (link) => link.relation == 'independent_similarity',
    );
    if ((outcome == 'independent_similarity') != independent) {
      throw const FormatException('Independent-similarity outcome mismatch.');
    }
    return MemoryConsolidationPackageResponse(
      contract: contract,
      version: version,
      outcome: outcome,
      events: List.unmodifiable(events),
      links: List.unmodifiable(links),
      unverifiedSourceRefs: List.unmodifiable(unverified),
      unexaminedOpenObligationIds: List.unmodifiable(obligations),
    );
  }

  static bool linksFrom(Object? raw) => raw is List && raw.isNotEmpty;

  static List<MemoryConsolidationLinkOperation> _links(
    Object? raw,
    MemoryConsolidationSourcePack pack,
    Set<String> newEventIds,
  ) {
    if (raw is! List) throw const FormatException('Invalid package links.');
    final known = {
      ...pack.candidates.map((candidate) => candidate.id),
      ...pack.proposedEventIds,
    };
    final ids = <String>{};
    final result = <MemoryConsolidationLinkOperation>[];
    for (final rawLink in raw) {
      if (rawLink is! Map) throw const FormatException('Invalid link.');
      final link = Map<String, dynamic>.from(rawLink);
      _keys(link, {'linkId', 'fromEventId', 'toEventId', 'relation'});
      final id = _bounded(link['linkId'], 128);
      final from = _bounded(link['fromEventId'], 128);
      final to = _bounded(link['toEventId'], 128);
      final relation = _string(link['relation']);
      if (!ids.add(id) ||
          from == to ||
          !known.contains(from) ||
          !known.contains(to) ||
          (!newEventIds.contains(from) && !newEventIds.contains(to)) ||
          !MemoryEventRegistryRepo.relations.contains(relation)) {
        throw const FormatException('Invalid or unrelated package link.');
      }
      result.add(
        MemoryConsolidationLinkOperation(
          linkId: id,
          fromEventId: from,
          toEventId: to,
          relation: relation,
        ),
      );
    }
    return result;
  }

  static Map<String, Object?>? _boundary(
    Object? raw,
    List<String> refs,
    Map<String, MemoryConsolidationSource> sources,
  ) {
    if (raw == null) return null;
    if (raw is! Map) throw const FormatException('Invalid event boundary.');
    final boundary = Map<String, dynamic>.from(raw);
    _keys(boundary, {'messageId', 'swipeId', 'agentSwipeId', 'ordinal'});
    final messageId = _bounded(boundary['messageId'], 256);
    final swipeId = boundary['swipeId'];
    final agentSwipeId = boundary['agentSwipeId'];
    final ordinal = boundary['ordinal'];
    if (swipeId is! int ||
        agentSwipeId is! int ||
        ordinal is! int ||
        swipeId < 0 ||
        agentSwipeId < 0 ||
        ordinal < 0 ||
        !refs.any(
          (ref) => sources[ref]!.sourceManifest.messages.any(
            (stamp) =>
                stamp.messageId == messageId &&
                stamp.swipeId == swipeId &&
                stamp.agentSwipeId == agentSwipeId,
          ),
        )) {
      throw const FormatException('Boundary is not in a cited package source.');
    }
    return {
      'messageId': messageId,
      'swipeId': swipeId,
      'agentSwipeId': agentSwipeId,
      'ordinal': ordinal,
    };
  }

  static List<String> _strings(Object? value) {
    if (value is! List || value.any((item) => item is! String)) {
      throw const FormatException('Expected a string array.');
    }
    return value.map((item) => _bounded(item, 256)).toList(growable: false);
  }

  static String _string(Object? value) {
    if (value is! String || value.isEmpty || value != value.trim()) {
      throw const FormatException('Expected a non-empty trimmed string.');
    }
    return value;
  }

  static String _bounded(Object? value, int maxLength) {
    final string = _string(value);
    if (string.length > maxLength) {
      throw const FormatException('String too long.');
    }
    return string;
  }

  static bool _sameSet(List<String> left, List<String> right) =>
      left.toSet().length == left.length &&
      left.length == right.length &&
      left.toSet().containsAll(right);

  static void _keys(Map<String, dynamic> value, Set<String> expected) {
    if (!value.keys.toSet().containsAll(expected) ||
        !expected.containsAll(value.keys.toSet())) {
      throw const FormatException('Unknown or missing contract fields.');
    }
  }
}
