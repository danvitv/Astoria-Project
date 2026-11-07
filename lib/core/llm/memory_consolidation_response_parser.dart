import 'dart:convert';

import '../db/repositories/memory_event_registry_repo.dart';
import '../models/memory_consolidation.dart';

class MemoryConsolidationResponseFormatException extends FormatException {
  const MemoryConsolidationResponseFormatException(super.message);
}

/// Strict v1 parser for the consolidation model response.
///
/// This parser deliberately accepts one new event per request. That is the
/// first vertical: one package, one reviewed event, and optional links to
/// already accepted events. Multi-event graph edits need a transaction model
/// that can atomically topologically order new endpoints; they are not hidden
/// behind a permissive parser here.
class MemoryConsolidationResponseParser {
  const MemoryConsolidationResponseParser._();

  static const contract = 'memory_event_consolidation';
  static const version = 1;

  static MemoryConsolidationResponse parse(
    String raw,
    MemoryConsolidationSourcePack pack,
  ) {
    final decoded = _decode(raw);
    _expectKeys(decoded, {
      'contract',
      'version',
      'outcome',
      'event',
      'links',
      'unverifiedSourceRefs',
      'unexaminedOpenObligationIds',
    });
    if (decoded['contract'] != contract || decoded['version'] != version) {
      throw const MemoryConsolidationResponseFormatException(
        'Unsupported consolidation contract.',
      );
    }
    final outcome = _string(decoded, 'outcome');
    const outcomes = {
      'confirmed',
      'independent_similarity',
      'unable_to_verify',
    };
    if (!outcomes.contains(outcome)) {
      throw const MemoryConsolidationResponseFormatException(
        'Invalid consolidation outcome.',
      );
    }
    final sourceRefs = _stringList(decoded, 'unverifiedSourceRefs');
    _unique(sourceRefs, 'unverifiedSourceRefs');
    final knownSources = {for (final source in pack.sources) source.ref};
    if (!sourceRefs.every(knownSources.contains)) {
      throw const MemoryConsolidationResponseFormatException(
        'Response references an unknown source.',
      );
    }
    final unexamined = _stringList(decoded, 'unexaminedOpenObligationIds');
    _unique(unexamined, 'unexaminedOpenObligationIds');
    final packUnexamined = pack.unexaminedOpenObligationIds.toSet();
    if (!unexamined.every(packUnexamined.contains) ||
        unexamined.toSet().length != packUnexamined.length) {
      throw const MemoryConsolidationResponseFormatException(
        'Response does not preserve the pack obligation boundary.',
      );
    }

    final rawEvent = decoded['event'];
    final event = rawEvent == null
        ? null
        : _parseEvent(rawEvent, pack, knownSources, sourceRefs.toSet());
    final links = _parseLinks(decoded['links'], pack, event?.eventId);
    if (outcome == 'unable_to_verify' && (event != null || links.isNotEmpty)) {
      throw const MemoryConsolidationResponseFormatException(
        'Unable-to-verify response cannot change the graph.',
      );
    }
    if (outcome != 'unable_to_verify' && event == null) {
      throw const MemoryConsolidationResponseFormatException(
        'A confirmed response must contain one event operation.',
      );
    }
    final hasIndependentSimilarity = links.any(
      (link) => link.relation == 'independent_similarity',
    );
    if ((outcome == 'independent_similarity') != hasIndependentSimilarity) {
      throw const MemoryConsolidationResponseFormatException(
        'Independent similarity outcome and relation must agree.',
      );
    }
    return MemoryConsolidationResponse(
      contract: contract,
      version: version,
      outcome: outcome,
      event: event,
      links: links,
      unverifiedSourceRefs: List.unmodifiable(sourceRefs),
      unexaminedOpenObligationIds: List.unmodifiable(unexamined),
    );
  }

  static Map<String, dynamic> _decode(String raw) {
    var text = raw.trim();
    final fence = RegExp(
      r'^```(?:json)?\s*([\s\S]*?)\s*```$',
      caseSensitive: false,
    ).firstMatch(text);
    if (fence != null) text = fence.group(1)!.trim();
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        throw const FormatException('Root is not an object.');
      }
      return Map<String, dynamic>.from(decoded);
    } on FormatException catch (error) {
      throw MemoryConsolidationResponseFormatException(error.message);
    } on Object {
      throw const MemoryConsolidationResponseFormatException(
        'Response is not valid JSON.',
      );
    }
  }

  static MemoryConsolidationEventOperation _parseEvent(
    Object? raw,
    MemoryConsolidationSourcePack pack,
    Set<String> knownSources,
    Set<String> unverifiedSourceRefs,
  ) {
    if (raw is! Map) {
      throw const MemoryConsolidationResponseFormatException(
        'Event operation must be an object.',
      );
    }
    final map = Map<String, dynamic>.from(raw);
    _expectKeys(map, {
      'eventId',
      'kind',
      'description',
      'state',
      'sourceRefs',
      'boundary',
    });
    final eventId = _boundedString(map, 'eventId', 128);
    if (eventId != pack.proposedEventId) {
      throw const MemoryConsolidationResponseFormatException(
        'Event operation does not match the proposed event ID.',
      );
    }
    final kind = _string(map, 'kind');
    final state = _string(map, 'state');
    if (!MemoryEventRegistryRepo.eventKinds.contains(kind) ||
        !MemoryEventRegistryRepo.eventStates.contains(state)) {
      throw const MemoryConsolidationResponseFormatException(
        'Event kind or state is not allowed.',
      );
    }
    final description = _boundedString(map, 'description', 2000);
    final refs = _stringList(map, 'sourceRefs');
    if (refs.isEmpty) {
      throw const MemoryConsolidationResponseFormatException(
        'Event must cite at least one source.',
      );
    }
    _unique(refs, 'sourceRefs');
    if (!refs.every(knownSources.contains)) {
      throw const MemoryConsolidationResponseFormatException(
        'Event references an unknown source.',
      );
    }
    if (refs.any(unverifiedSourceRefs.contains)) {
      throw const MemoryConsolidationResponseFormatException(
        'Event cites a source marked unverified.',
      );
    }
    final boundary = _parseBoundary(map['boundary'], pack, refs);
    return MemoryConsolidationEventOperation(
      eventId: eventId,
      kind: kind,
      description: description,
      state: state,
      sourceRefs: List.unmodifiable(refs),
      boundaryMessageId: boundary?.messageId,
      boundarySwipeId: boundary?.swipeId,
      boundaryAgentSwipeId: boundary?.agentSwipeId,
      boundaryOrdinal: boundary?.ordinal,
    );
  }

  static List<MemoryConsolidationLinkOperation> _parseLinks(
    Object? raw,
    MemoryConsolidationSourcePack pack,
    String? newEventId,
  ) {
    if (raw is! List) {
      throw const MemoryConsolidationResponseFormatException(
        'Links must be an array.',
      );
    }
    final known = {
      ...pack.candidates.map((candidate) => candidate.id),
      ?newEventId,
    };
    final links = <MemoryConsolidationLinkOperation>[];
    final ids = <String>{};
    for (final item in raw) {
      if (item is! Map) {
        throw const MemoryConsolidationResponseFormatException(
          'Link operation must be an object.',
        );
      }
      final map = Map<String, dynamic>.from(item);
      _expectKeys(map, {'linkId', 'fromEventId', 'toEventId', 'relation'});
      final linkId = _boundedString(map, 'linkId', 128);
      final from = _boundedString(map, 'fromEventId', 128);
      final to = _boundedString(map, 'toEventId', 128);
      final relation = _string(map, 'relation');
      if (!ids.add(linkId) ||
          from == to ||
          !known.contains(from) ||
          !known.contains(to) ||
          newEventId == null ||
          (from != newEventId && to != newEventId) ||
          !MemoryEventRegistryRepo.relations.contains(relation)) {
        throw const MemoryConsolidationResponseFormatException(
          'Invalid or unrelated link operation.',
        );
      }
      links.add(
        MemoryConsolidationLinkOperation(
          linkId: linkId,
          fromEventId: from,
          toEventId: to,
          relation: relation,
        ),
      );
    }
    return List.unmodifiable(links);
  }

  static _MemoryConsolidationBoundary? _parseBoundary(
    Object? raw,
    MemoryConsolidationSourcePack pack,
    List<String> sourceRefs,
  ) {
    if (raw == null) return null;
    if (raw is! Map) {
      throw const MemoryConsolidationResponseFormatException(
        'Boundary must be an object or null.',
      );
    }
    final map = Map<String, dynamic>.from(raw);
    _expectKeys(map, {'messageId', 'swipeId', 'agentSwipeId', 'ordinal'});
    final messageId = _boundedString(map, 'messageId', 256);
    final swipeId = _int(map, 'swipeId');
    final agentSwipeId = _int(map, 'agentSwipeId');
    final ordinal = _int(map, 'ordinal');
    if (swipeId < 0 || agentSwipeId < 0 || ordinal < 0) {
      throw const MemoryConsolidationResponseFormatException(
        'Boundary coordinates must be non-negative.',
      );
    }
    final sourceSet = sourceRefs.toSet();
    final matches = pack.sources.any(
      (source) =>
          sourceSet.contains(source.ref) &&
          source.sourceManifest.messages.any(
            (stamp) =>
                stamp.messageId == messageId &&
                stamp.swipeId == swipeId &&
                stamp.agentSwipeId == agentSwipeId,
          ),
    );
    if (!matches) {
      throw const MemoryConsolidationResponseFormatException(
        'Boundary is not present in a cited source.',
      );
    }
    return _MemoryConsolidationBoundary(
      messageId: messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
      ordinal: ordinal,
    );
  }

  static String _string(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is! String || value.trim().isEmpty || value != value.trim()) {
      throw MemoryConsolidationResponseFormatException('Invalid $key.');
    }
    return value;
  }

  static String _boundedString(
    Map<String, dynamic> map,
    String key,
    int maxLength,
  ) {
    final value = _string(map, key);
    if (value.length > maxLength) {
      throw MemoryConsolidationResponseFormatException('$key is too long.');
    }
    return value;
  }

  static int _int(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is! int) {
      throw MemoryConsolidationResponseFormatException('Invalid $key.');
    }
    return value;
  }

  static List<String> _stringList(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is! List || value.any((item) => item is! String)) {
      throw MemoryConsolidationResponseFormatException('Invalid $key.');
    }
    return [for (final item in value) _boundedListItem(item as String, key)];
  }

  static String _boundedListItem(String value, String key) {
    if (value.isEmpty || value != value.trim() || value.length > 256) {
      throw MemoryConsolidationResponseFormatException('Invalid $key item.');
    }
    return value;
  }

  static void _unique(List<String> values, String key) {
    if (values.toSet().length != values.length) {
      throw MemoryConsolidationResponseFormatException(
        '$key contains duplicates.',
      );
    }
  }

  static void _expectKeys(Map<String, dynamic> map, Set<String> expected) {
    if (map.keys.toSet().difference(expected).isNotEmpty ||
        expected.difference(map.keys.toSet()).isNotEmpty) {
      throw const MemoryConsolidationResponseFormatException(
        'Response shape contains unknown or missing fields.',
      );
    }
  }
}

class _MemoryConsolidationBoundary {
  final String messageId;
  final int swipeId;
  final int agentSwipeId;
  final int ordinal;

  const _MemoryConsolidationBoundary({
    required this.messageId,
    required this.swipeId,
    required this.agentSwipeId,
    required this.ordinal,
  });
}
