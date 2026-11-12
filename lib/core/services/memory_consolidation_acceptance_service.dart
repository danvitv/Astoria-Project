import 'dart:convert';

import 'package:collection/collection.dart';

import '../db/repositories/memory_event_registry_repo.dart';
import '../llm/memory_consolidation_response_parser.dart';
import '../llm/memory_consolidation_package_parser.dart';
import '../models/memory_consolidation.dart';

/// Parses and transactionally accepts one reviewed consolidation response.
///
/// This is intentionally not an LLM client. The caller owns model transport,
/// cancellation and UI draft state; this service is the narrow bridge where a
/// strict response becomes durable registry data.
class MemoryConsolidationAcceptanceService {
  final MemoryEventRegistryRepo registry;

  const MemoryConsolidationAcceptanceService(this.registry);

  MemoryConsolidationResponse parseDraft({
    required String rawResponse,
    required MemoryConsolidationSourcePack pack,
  }) => MemoryConsolidationResponseParser.parse(rawResponse, pack);

  MemoryConsolidationPackageResponse parsePackageDraft({
    required String rawResponse,
    required MemoryConsolidationSourcePack pack,
  }) => MemoryConsolidationPackageParser.parse(rawResponse, pack);

  Future<bool> acceptReviewedPackage({
    required MemoryConsolidationPackageResponse response,
    required MemoryConsolidationSourcePack pack,
    required bool Function() isCurrent,
    String acceptedBy = 'user',
  }) async {
    final canonical = MemoryConsolidationPackageParser.parse(
      jsonEncode(response.toStrictJson()),
      pack,
    );
    if (canonical.outcome == 'unable_to_verify') return false;
    final accepted = await registry.acceptPackage(
      events: canonical.toRegistryEvents(pack),
      links: canonical.toRegistryLinks(pack),
      isCurrent: isCurrent,
      acceptedBy: acceptedBy,
    );
    if (!accepted) {
      throw StateError('Consolidation package became stale before acceptance.');
    }
    return true;
  }

  Future<bool> acceptReviewed({
    required MemoryConsolidationResponse response,
    required MemoryConsolidationSourcePack pack,
    required bool Function() isCurrent,
    String acceptedBy = 'user',
  }) async {
    if (response.contract != MemoryConsolidationResponseParser.contract ||
        response.version != MemoryConsolidationResponseParser.version ||
        (response.outcome != 'unable_to_verify' &&
            response.event?.eventId != pack.proposedEventId) ||
        !const SetEquality<String>().equals(
          response.unexaminedOpenObligationIds.toSet(),
          pack.unexaminedOpenObligationIds.toSet(),
        )) {
      throw ArgumentError('Response does not belong to this review pack.');
    }
    if (response.outcome == 'unable_to_verify') return false;
    // Re-run the strict parser over the structured object to prevent callers
    // from constructing a forged response DTO instead of a parsed draft.
    final canonical = MemoryConsolidationResponseParser.parse(
      jsonEncode(_responseJson(response)),
      pack,
    );
    final change = canonical.toRegistryChange(pack);
    final accepted = await registry.accept(
      event: change.event,
      links: change.links,
      isCurrent: isCurrent,
      acceptedBy: acceptedBy,
    );
    if (!accepted) {
      throw StateError(
        'Consolidation response became stale before acceptance.',
      );
    }
    return true;
  }

  static Map<String, dynamic> _responseJson(
    MemoryConsolidationResponse value,
  ) => {
    'contract': value.contract,
    'version': value.version,
    'outcome': value.outcome,
    'event': value.event == null
        ? null
        : {
            'eventId': value.event!.eventId,
            'kind': value.event!.kind,
            'description': value.event!.description,
            'state': value.event!.state,
            'sourceRefs': value.event!.sourceRefs,
            'boundary': value.event!.boundaryMessageId == null
                ? null
                : {
                    'messageId': value.event!.boundaryMessageId,
                    'swipeId': value.event!.boundarySwipeId,
                    'agentSwipeId': value.event!.boundaryAgentSwipeId,
                    'ordinal': value.event!.boundaryOrdinal,
                  },
          },
    'links': [
      for (final link in value.links)
        {
          'linkId': link.linkId,
          'fromEventId': link.fromEventId,
          'toEventId': link.toEventId,
          'relation': link.relation,
        },
    ],
    'unverifiedSourceRefs': value.unverifiedSourceRefs,
    'unexaminedOpenObligationIds': value.unexaminedOpenObligationIds,
  };
}
