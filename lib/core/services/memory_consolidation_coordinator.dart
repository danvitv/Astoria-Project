import 'package:dio/dio.dart';

import '../db/repositories/memory_consolidation_pack_builder.dart';
import '../llm/aux_llm_client.dart';
import '../llm/memory_book_api_config_resolver.dart';
import '../llm/memory_draft_api_source.dart';
import '../models/memory_book_api_settings.dart';
import '../models/memory_consolidation.dart';
import '../credentials/memory_custom_api_credential_owner.dart';
import '../credentials/native_provider_credentials.dart';
import 'memory_consolidation_acceptance_service.dart';
import 'memory_consolidation_service.dart';

/// One reviewed consolidation run: immutable pack plus its parsed model draft.
final class MemoryConsolidationDraft {
  const MemoryConsolidationDraft({required this.pack, required this.response});

  final MemoryConsolidationSourcePack pack;
  final MemoryConsolidationResponse response;
}

/// Coordinates pack creation, network drafting, and explicit reviewed acceptance.
/// API credentials/configuration are resolved by the caller through the existing
/// MemoryBook source owner and are never read or reconstructed here.
final class MemoryConsolidationCoordinator {
  final MemoryConsolidationPackBuilder packBuilder;
  final MemoryConsolidationService service;
  final MemoryConsolidationAcceptanceService acceptance;

  const MemoryConsolidationCoordinator({
    required this.packBuilder,
    required this.service,
    required this.acceptance,
  });

  Future<MemoryConsolidationDraft?> generateDraft({
    required String sessionId,
    required String branchId,
    required String proposedEventId,
    required List<String> memoryEntryIds,
    required AuxApiConfig config,
    required int maxTokens,
    required double temperature,
    required int timeoutMs,
    required bool Function() isCurrent,
    int maxCandidates = 12,
    int maxContextCharacters = 120000,
    CancelToken? cancelToken,
  }) async {
    if (!isCurrent() || cancelToken?.isCancelled == true) {
      throw StateError('Consolidation run became stale or was cancelled.');
    }
    final pack = await packBuilder.build(
      sessionId: sessionId,
      branchId: branchId,
      proposedEventId: proposedEventId,
      memoryEntryIds: memoryEntryIds,
      maxCandidates: maxCandidates,
      maxContextCharacters: maxContextCharacters,
    );
    if (pack == null) return null;
    if (!isCurrent() || cancelToken?.isCancelled == true) {
      throw StateError('Consolidation run became stale or was cancelled.');
    }
    final response = await service.generateDraft(
      pack: pack,
      config: config,
      maxTokens: maxTokens,
      temperature: temperature,
      timeoutMs: timeoutMs,
      isCurrent: isCurrent,
      cancelToken: cancelToken,
    );
    return MemoryConsolidationDraft(pack: pack, response: response);
  }

  Future<bool> acceptReviewed({
    required MemoryConsolidationDraft draft,
    required bool Function() isCurrent,
    String acceptedBy = 'user',
  }) => acceptance.acceptReviewed(
    response: draft.response,
    pack: draft.pack,
    isCurrent: isCurrent,
    acceptedBy: acceptedBy,
  );

  /// Resolves the same saved/custom MemoryBook source used by draft generation,
  /// then runs the normal pack and draft path with its effective limits.
  Future<MemoryConsolidationDraft?> generateDraftWithSettings({
    required String sessionId,
    required String branchId,
    required String proposedEventId,
    required List<String> memoryEntryIds,
    required MemoryBookApiSettings settings,
    required MemoryDraftApiSourceResolver apiResolver,
    required NativeConnectionStamp? originalStamp,
    required bool Function() isCurrent,
    MemoryCustomApiInvocation? originalCustomApi,
    int maxCandidates = 12,
    int maxContextCharacters = 120000,
    CancelToken? cancelToken,
  }) async {
    final resolved = await apiResolver.resolve(
      settings: settings,
      originalStamp: originalStamp,
      originalCustomApi: originalCustomApi,
      isCurrent: () => isCurrent() && cancelToken?.isCancelled != true,
    );
    return generateDraft(
      sessionId: sessionId,
      branchId: branchId,
      proposedEventId: proposedEventId,
      memoryEntryIds: memoryEntryIds,
      config: resolved.config,
      maxTokens: MemoryBookApiConfigResolver.maxTokensFor(
        settings,
        resolved.configuration,
      ),
      temperature: MemoryBookApiConfigResolver.temperatureFor(settings),
      timeoutMs: resolved.receiveTimeoutMs ?? 0,
      isCurrent: isCurrent,
      maxCandidates: maxCandidates,
      maxContextCharacters: maxContextCharacters,
      cancelToken: cancelToken,
    );
  }
}
