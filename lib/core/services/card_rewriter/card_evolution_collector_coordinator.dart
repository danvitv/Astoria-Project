import 'dart:convert';

import '../../llm/canon_evidence_text.dart';

import 'package:dio/dio.dart';

import '../../db/app_db.dart';
import '../../db/repositories/card_evolution_collector_run_repo.dart';
import '../../db/repositories/card_evolution_observation_repo.dart';
import '../../db/repositories/card_evolution_repo.dart';
import '../../db/repositories/llm_request_capture_repo.dart';
import '../../llm/aux_llm_client.dart';
import '../../llm/transport/llm_capture_context.dart';
import '../../models/agent_operation_record.dart';
import '../../models/card_evolution_observation.dart';
import '../../utils/cast_helpers.dart';
import '../../utils/id_generator.dart';
import '../../utils/time_helpers.dart';
import 'card_evolution_diagnostics.dart';
import 'card_rewrite_prompt_builder.dart';
import 'manual_rewrite_service.dart';
import 'observation_response_parser.dart';

typedef CardEvolutionWriterContinuation =
    Future<CardEvolutionFinalizeOutcome> Function(String sessionId);

typedef CardEvolutionCollectorModelResolver =
    Future<AuxApiConfig> Function(String sessionId);

/// Owns the automatic Card Evolution collector lane and its observation state.
class CardEvolutionCollectorCoordinator {
  CardEvolutionCollectorCoordinator({
    required this.repo,
    required this.observationRepo,
    required this.collectorRunRepo,
    required this.requestCaptureRepo,
    required this.resolveModel,
    required this._executor,
    required this._diagnostics,
    required this.timeoutMs,
    required this.leaseSeconds,
    required this.continueWriterAfterCollectors,
    this.parser = const ObservationResponseParser(),
    this.observationPromotionThreshold,
    this.observationMinConfidence,
    this.observationExpiryRuns,
    this.isStillCurrent,
    this.isCommitCurrent,
  });

  final CardEvolutionRepo repo;
  final CardEvolutionObservationRepo observationRepo;
  final CardEvolutionCollectorRunRepo collectorRunRepo;
  final LlmRequestCaptureRepo requestCaptureRepo;
  final CardEvolutionCollectorModelResolver resolveModel;
  final CardRewriteLlmExecutor _executor;
  final CardEvolutionDiagnostics _diagnostics;
  final ObservationResponseParser parser;
  final int timeoutMs;
  final int leaseSeconds;
  final CardEvolutionWriterContinuation continueWriterAfterCollectors;
  final int Function()? observationPromotionThreshold;
  final double Function()? observationMinConfidence;
  final int Function()? observationExpiryRuns;
  final bool Function()? isStillCurrent;
  final Future<bool> Function()? isCommitCurrent;
  final Map<String, CancelToken> _observationTokens = {};
  final Map<String, int> _cancellationEpochs = {};
  bool _disposed = false;

  bool Function() _invocation(
    String sessionId,
    bool Function()? isInvocationCurrent,
  ) {
    final epoch = _cancellationEpochs[sessionId] ?? 0;
    var active = true;
    return () => active =
        active &&
        !_disposed &&
        (_cancellationEpochs[sessionId] ?? 0) == epoch &&
        isStillCurrent?.call() != false &&
        isInvocationCurrent?.call() != false;
  }

  void _requireCurrent(bool Function() current) {
    if (!current()) throw const _CollectorCancelled();
  }

  Future<void> _requireCommitCurrent(bool Function() current) async {
    _requireCurrent(current);
    if (isCommitCurrent != null && !await isCommitCurrent!()) {
      throw const _CollectorCancelled();
    }
    _requireCurrent(current);
  }

  Future<bool> runCollector(
    CardEvolutionCollectorBatch batch, {
    void Function()? onObservationStage,
    bool Function()? isInvocationCurrent,
  }) async {
    final reconciliationRun = batch.boundary;
    final sessionId = reconciliationRun.sessionId;
    final current = _invocation(sessionId, isInvocationCurrent);
    String? claimId;
    String? ownerId;
    try {
      _requireCurrent(current);
      final snapshot = await repo.buildObservationSnapshotForRuns(batch.runs);
      _requireCurrent(current);
      if (snapshot == null) return false;
      ownerId = 'collector-owner-${generateId()}';
      final now = currentTimestampSeconds();
      final claim = await collectorRunRepo.claim(
        reconciliationRun: reconciliationRun,
        characterId: snapshot.character.id,
        inputHash: computeHash(snapshot.selectedInputJson),
        ownerId: ownerId,
        now: now,
        leaseSeconds: leaseSeconds,
        rangeHash: batch.rangeHash,
      );
      if (claim.canRun && claim.row != null) claimId = claim.row!.id;
      _requireCurrent(current);
      if (claim.kind == 'completed') return true;
      if (!claim.canRun || claim.row == null) return false;
      onObservationStage?.call();
      final output = await runObservationPass(
        sessionId,
        snapshot,
        claim.row!.collectorOrdinal,
        pipelineRunId: claim.row!.id,
        isInvocationCurrent: current,
        onFailure: ({required code, detail, callId}) async {
          await collectorRunRepo.markFailed(
            id: claimId!,
            ownerId: ownerId!,
            now: currentTimestampSeconds(),
            code: code,
            detail: detail,
            callId: callId,
          );
        },
        finalize: (output, applyEffects) async {
          _requireCurrent(current);
          return repo.db.transaction(() async {
            await _requireCommitCurrent(current);
            final completed = await collectorRunRepo.completeWithEffects(
              id: claimId!,
              ownerId: ownerId!,
              modelOutputHash: computeHash(output),
              now: currentTimestampSeconds(),
              validateEvidence: () async {
                _requireCurrent(current);
                final logical = await collectorRunRepo.runsForCollectors(
                  sessionId,
                  [claim.row!],
                );
                _requireCurrent(current);
                return _sameRuns(logical, batch.runs);
              },
              applyEffects: applyEffects,
            );
            await _requireCommitCurrent(current);
            return completed;
          });
        },
      );
      _requireCurrent(current);
      if (output == null) {
        await collectorRunRepo.markFailed(
          id: claimId!,
          ownerId: ownerId,
          now: currentTimestampSeconds(),
          code: 'collectorFailed',
          detail: 'Collector did not produce a valid response',
        );
        return false;
      }
      await checkPromotions(sessionId, isInvocationCurrent: current);
      _requireCurrent(current);
      claimId = null;
      return true;
    } catch (error) {
      if (current() && claimId != null && ownerId != null) {
        await collectorRunRepo.markFailed(
          id: claimId,
          ownerId: ownerId,
          now: currentTimestampSeconds(),
          code: 'unexpectedFailure',
          detail: error.toString(),
        );
      }
      return false;
    } finally {
      if (claimId != null && ownerId != null) {
        await collectorRunRepo.abandon(id: claimId, ownerId: ownerId);
      }
    }
  }

  Future<String?> runObservationPass(
    String sessionId,
    CardEvolutionObservationSnapshot snapshot,
    int runOrdinal, {
    bool Function()? isInvocationCurrent,
    String? pipelineRunId,
    Future<void> Function({
      required String code,
      String? detail,
      String? callId,
    })?
    onFailure,
    Future<bool> Function(String output, Future<void> Function() applyEffects)?
    finalize,
  }) async {
    final current = _invocation(sessionId, isInvocationCurrent);
    if (!current()) return null;
    final token = CancelToken();
    _observationTokens[sessionId] = token;
    try {
      final config = await resolveModel(sessionId);
      if (!current()) return null;
      if (token.isCancelled) {
        await onFailure?.call(code: 'cancelled');
        return null;
      }
      final prompt = _buildObservationPrompt(snapshot);
      final outcome = await _executor(
        config: config,
        prompt: prompt,
        maxTokens: config.maxTokens,
        temperature: 0.2,
        timeoutMs: timeoutMs,
        cancelToken: token,
        captureContext: LlmCaptureContext(
          stage: 'card.collector',
          sessionId: sessionId,
          pipelineRunId: pipelineRunId ?? 'collector:$runOrdinal',
          logicalCallId: pipelineRunId ?? 'collector:$runOrdinal',
          relatedArtifactId: pipelineRunId,
          stageOrdinal: runOrdinal,
        ),
      );
      if (!current()) return null;
      if (token.isCancelled) {
        await onFailure?.call(code: 'cancelled');
        return null;
      }
      if (outcome.status == AgentOperationStatus.aborted ||
          !outcome.isOk ||
          outcome.text == null) {
        await onFailure?.call(
          code: outcome.status.name,
          detail: outcome.lastError?.toString(),
          callId: outcome.selectedCaptureContext?.callId,
        );
        return null;
      }
      final actions = parser.parse(outcome.text!);
      if (actions == null) {
        await _diagnostics.recordCollectorParserVerdict(
          context: outcome.selectedCaptureContext,
          accepted: false,
          code: 'invalidOutput',
          detail: 'Collector response is not valid JSON',
          source: 'model',
        );
        if (!current() || token.isCancelled) return null;
        await onFailure?.call(
          code: 'parserRejected',
          detail: 'Collector response is not valid JSON',
          callId: outcome.selectedCaptureContext?.callId,
        );
        return null;
      }
      final validEvidenceIds = _chatMessageIds(snapshot.selectedInputJson);
      if (validEvidenceIds == null) {
        await onFailure?.call(
          code: 'invalidSelectedInput',
          detail: 'Collector input has no valid immutable chat history',
          callId: outcome.selectedCaptureContext?.callId,
        );
        return null;
      }
      final retrievalTargets = _retrievalTargets(snapshot.selectedInputJson);
      if (retrievalTargets == null) {
        await onFailure?.call(
          code: 'invalidSelectedInput',
          detail: 'Collector input has no valid retrieval targets',
          callId: outcome.selectedCaptureContext?.callId,
        );
        return null;
      }
      await _diagnostics.recordCollectorParserVerdict(
        context: outcome.selectedCaptureContext,
        accepted: true,
        code: 'accepted',
        source: 'model',
      );
      if (!current() || token.isCancelled) return null;
      Future<void> applyEffects() async {
        await _requireCommitCurrent(current);
        await _applyCollectorActions(
          sessionId: sessionId,
          snapshot: snapshot,
          runOrdinal: runOrdinal,
          actions: actions,
          validEvidenceIds: validEvidenceIds,
          retrievalTargets: retrievalTargets,
          current: current,
        );
        await _requireCommitCurrent(current);
      }

      if (finalize != null) {
        if (!await finalize(outcome.text!, applyEffects)) return null;
      } else {
        // Manual observation refresh has no collector claim transaction. Keep
        // its effects atomic so cancellation during a repository await rolls
        // back, rather than leaving a partial observation set behind.
        await repo.db.transaction(applyEffects);
      }
      if (!current() || token.isCancelled) return null;
      return outcome.text;
    } finally {
      if (identical(_observationTokens[sessionId], token)) {
        _observationTokens.remove(sessionId);
      }
    }
  }

  Future<CardEvolutionFinalizeOutcome> recoverFailedCollectorUnshared(
    CardEvolutionCollectorRunRow failed, {
    String? manualResponse,
    bool Function()? isInvocationCurrent,
    CardEvolutionWriterContinuation? continueWriter,
  }) async {
    final current = _invocation(failed.sessionId, isInvocationCurrent);
    if (!current()) return const CardEvolutionFinalizeOutcome('cancelled');
    final runs = await collectorRunRepo.runsForCollectors(failed.sessionId, [
      failed,
    ]);
    if (!current()) return const CardEvolutionFinalizeOutcome('cancelled');
    if (runs.length != collectorReconciliationBatchSize) {
      return const CardEvolutionFinalizeOutcome('collectorEvidenceStale');
    }
    final batch = CardEvolutionCollectorBatch(runs);
    final snapshot = await repo.buildObservationSnapshotForRuns(runs);
    if (!current()) return const CardEvolutionFinalizeOutcome('cancelled');
    if (snapshot == null ||
        computeHash(snapshot.selectedInputJson) != failed.inputHash) {
      return const CardEvolutionFinalizeOutcome('staleInput');
    }

    String? prompt;
    if (manualResponse == null) {
      final currentPrompt = _buildObservationPrompt(snapshot);
      final failedCallId = failed.lastCallId;
      if (failedCallId != null) {
        final capture = await requestCaptureRepo.exactPromptForCall(
          callId: failedCallId,
          sessionId: failed.sessionId,
          pipelineRunId: failed.id,
          stage: 'card.collector',
        );
        if (!current()) return const CardEvolutionFinalizeOutcome('cancelled');
        prompt = capture?.prompt;
      }
      if (prompt != null && prompt != currentPrompt) {
        // A pre-upgrade capture can contain assistant forecasts and obsolete
        // attribution rules. Preserve it, but do not replay it as new evidence
        // or spend a model call under a different prompt contract.
        return const CardEvolutionFinalizeOutcome(
          'collectorPromptChanged',
          null,
          'Captured collector prompt differs from current evidence rules; '
              'exact retry refused. Review the immutable capture explicitly.',
        );
      }
      prompt ??= currentPrompt;
    }

    final ownerId = 'collector-recovery-${generateId()}';
    final claim = await collectorRunRepo.claimFailed(
      id: failed.id,
      ownerId: ownerId,
      now: currentTimestampSeconds(),
      leaseSeconds: leaseSeconds,
    );
    if (!current()) {
      if (claim.canRun && claim.row != null) {
        await collectorRunRepo.markFailed(
          id: failed.id,
          ownerId: ownerId,
          now: currentTimestampSeconds(),
          code: 'cancelled',
          callId: failed.lastCallId,
        );
      }
      return const CardEvolutionFinalizeOutcome('cancelled');
    }
    if (!claim.canRun || claim.row == null) {
      return CardEvolutionFinalizeOutcome(claim.kind);
    }
    final context = LlmCaptureContext(
      stage: 'card.collector',
      sessionId: failed.sessionId,
      pipelineRunId: failed.id,
      callId: manualResponse == null ? null : 'llm-call-${generateId()}',
      parentCallId: failed.lastCallId,
      logicalCallId:
          '${failed.id}:${manualResponse == null ? 'retry' : 'manual'}',
      relatedArtifactId: failed.id,
      stageOrdinal: failed.collectorOrdinal,
      attempt: manualResponse == null ? null : 1,
    );
    String? output = manualResponse;
    LlmCaptureContext? selectedContext = context;
    var completed = false;
    CancelToken? token;
    try {
      _requireCurrent(current);
      if (output == null) {
        token = CancelToken();
        _observationTokens[failed.sessionId] = token;
        final config = await resolveModel(failed.sessionId);
        _requireCurrent(current);
        final outcome = await _executor(
          config: config,
          prompt: prompt!,
          maxTokens: config.maxTokens,
          temperature: 0.2,
          timeoutMs: timeoutMs,
          cancelToken: token,
          captureContext: context,
        );
        _requireCurrent(current);
        selectedContext = outcome.selectedCaptureContext;
        if (token.isCancelled ||
            outcome.status == AgentOperationStatus.aborted ||
            !outcome.isOk ||
            outcome.text == null) {
          final code =
              token.isCancelled ||
                  outcome.status == AgentOperationStatus.aborted
              ? 'cancelled'
              : outcome.status.name;
          await collectorRunRepo.markFailed(
            id: failed.id,
            ownerId: ownerId,
            now: currentTimestampSeconds(),
            code: code,
            detail: outcome.lastError?.toString(),
            callId: selectedContext?.callId ?? failed.lastCallId,
          );
          return CardEvolutionFinalizeOutcome(code);
        }
        output = outcome.text;
      }

      final finalized = await _finalizeCollectorOutput(
        sessionId: failed.sessionId,
        snapshot: snapshot,
        runOrdinal: failed.collectorOrdinal,
        batch: batch,
        collectorId: failed.id,
        ownerId: ownerId,
        output: output!,
        captureContext: selectedContext,
        source: manualResponse == null ? 'exact_retry' : 'manual_correction',
        current: current,
      );
      _requireCurrent(current);
      if (!finalized.success) {
        await collectorRunRepo.markFailed(
          id: failed.id,
          ownerId: ownerId,
          now: currentTimestampSeconds(),
          code: finalized.code,
          detail: finalized.detail,
          callId: manualResponse == null
              ? selectedContext?.callId ?? failed.lastCallId
              : failed.lastCallId,
        );
        return CardEvolutionFinalizeOutcome(
          finalized.code,
          null,
          finalized.detail,
        );
      }
      completed = true;
      await checkPromotions(failed.sessionId, isInvocationCurrent: current);
      _requireCurrent(current);
      return (continueWriter ?? continueWriterAfterCollectors)(
        failed.sessionId,
      );
    } catch (error) {
      if (!current()) {
        if (!completed) {
          await collectorRunRepo.markFailed(
            id: failed.id,
            ownerId: ownerId,
            now: currentTimestampSeconds(),
            code: 'cancelled',
            callId: selectedContext?.callId ?? failed.lastCallId,
          );
        }
        return const CardEvolutionFinalizeOutcome('cancelled');
      }
      if (!completed) {
        await collectorRunRepo.markFailed(
          id: failed.id,
          ownerId: ownerId,
          now: currentTimestampSeconds(),
          code: 'unexpectedFailure',
          detail: error.toString(),
          callId: selectedContext?.callId ?? failed.lastCallId,
        );
      }
      return CardEvolutionFinalizeOutcome(
        completed ? 'collectorCompleted' : 'unexpectedFailure',
        null,
        error.toString(),
      );
    } finally {
      if (identical(_observationTokens[failed.sessionId], token)) {
        _observationTokens.remove(failed.sessionId);
      }
    }
  }

  Future<_CollectorFinalizeResult> _finalizeCollectorOutput({
    required String sessionId,
    required CardEvolutionObservationSnapshot snapshot,
    required int runOrdinal,
    required CardEvolutionCollectorBatch batch,
    required String collectorId,
    required String ownerId,
    required String output,
    required LlmCaptureContext? captureContext,
    required String source,
    required bool Function() current,
  }) async {
    _requireCurrent(current);
    final actions = parser.parse(output);
    if (actions == null) {
      await _diagnostics.recordCollectorParserVerdict(
        context: captureContext,
        accepted: false,
        code: 'invalidOutput',
        detail: 'Collector response is not valid JSON',
        responseText: source == 'manual_correction' ? output : null,
        source: source,
      );
      return const _CollectorFinalizeResult.failure(
        'parserRejected',
        'Collector response is not valid JSON',
      );
    }
    final validEvidenceIds = _chatMessageIds(snapshot.selectedInputJson);
    final retrievalTargets = _retrievalTargets(snapshot.selectedInputJson);
    if (validEvidenceIds == null || retrievalTargets == null) {
      return const _CollectorFinalizeResult.failure(
        'invalidSelectedInput',
        'Collector input cannot be validated',
      );
    }
    await _diagnostics.recordCollectorParserVerdict(
      context: captureContext,
      accepted: true,
      code: 'accepted',
      responseText: source == 'manual_correction' ? output : null,
      source: source,
    );
    _requireCurrent(current);
    final completed = await repo.db.transaction(() async {
      _requireCurrent(current);
      final completed = await collectorRunRepo.completeWithEffects(
        id: collectorId,
        ownerId: ownerId,
        modelOutputHash: computeHash(output),
        now: currentTimestampSeconds(),
        lastCallId: captureContext?.callId,
        validateEvidence: () async {
          _requireCurrent(current);
          final collector = await collectorRunRepo.getById(collectorId);
          _requireCurrent(current);
          if (collector == null) return false;
          final logical = await collectorRunRepo.runsForCollectors(sessionId, [
            collector,
          ]);
          _requireCurrent(current);
          if (!_sameRuns(logical, batch.runs)) {
            return false;
          }
          final currentSnapshot = await repo.buildObservationSnapshotForRuns(
            logical,
          );
          _requireCurrent(current);
          return currentSnapshot != null &&
              computeHash(currentSnapshot.selectedInputJson) ==
                  collector.inputHash &&
              collector.inputHash == computeHash(snapshot.selectedInputJson);
        },
        applyEffects: () => _applyCollectorActions(
          sessionId: sessionId,
          snapshot: snapshot,
          runOrdinal: runOrdinal,
          actions: actions,
          validEvidenceIds: validEvidenceIds,
          retrievalTargets: retrievalTargets,
          current: current,
        ),
      );
      _requireCurrent(current);
      return completed;
    });
    _requireCurrent(current);
    return completed
        ? const _CollectorFinalizeResult.success()
        : const _CollectorFinalizeResult.failure(
            'collectorEvidenceStale',
            'Collector lease or reconciliation evidence changed',
          );
  }

  bool _sameRuns(
    List<LedgerReconciliationSuccessfulRunRow> left,
    List<LedgerReconciliationSuccessfulRunRow> right,
  ) =>
      left.length == right.length &&
      left.indexed.every((entry) => entry.$2.id == right[entry.$1].id);

  Future<void> _applyCollectorActions({
    required String sessionId,
    required CardEvolutionObservationSnapshot snapshot,
    required int runOrdinal,
    required List<ParsedObservationAction> actions,
    required Set<String> validEvidenceIds,
    required Map<String, String> retrievalTargets,
    required bool Function() current,
  }) async {
    _requireCurrent(current);
    final now = currentTimestampSeconds();
    for (final action in actions) {
      if (!validEvidenceIds.containsAll(action.evidenceMessageIds)) continue;
      if (!retrievalTargets.keys.toSet().containsAll(action.retrievalKeys)) {
        continue;
      }
      final loreIdentity = action.lorebookEntryId;
      final hasExactLoreTarget =
          loreIdentity != null &&
          action.retrievalKeys.contains(loreIdentity) &&
          retrievalTargets[loreIdentity] == 'injected_lorebook_entry';
      if ((action.targetKind == 'injected_lorebook_entry' &&
              !hasExactLoreTarget) ||
          (action.targetKind == 'main_character_card' &&
              (loreIdentity != null ||
                  action.retrievalKeys.any(
                    (key) => retrievalTargets[key] == 'injected_lorebook_entry',
                  )))) {
        continue;
      }
      await _applyObservationAction(
        sessionId: sessionId,
        characterId: snapshot.character.id,
        runOrdinal: runOrdinal,
        now: now,
        action: action,
        current: current,
      );
      _requireCurrent(current);
    }
    await observationRepo.expireUnconfirmed(
      sessionId: sessionId,
      currentRunOrdinal: runOrdinal,
      maxUnconfirmedRuns: observationExpiryRuns?.call() ?? 4,
      now: now,
    );
    _requireCurrent(current);
  }

  Future<void> _applyObservationAction({
    required String sessionId,
    required String characterId,
    required int runOrdinal,
    required int now,
    required ParsedObservationAction action,
    required bool Function() current,
  }) async {
    _requireCurrent(current);
    switch (action.action) {
      case 'confirm':
        final existing = await observationRepo.findByScopeKey(
          sessionId,
          action.scopeKey,
        );
        _requireCurrent(current);
        if (existing != null &&
            existing.status == 'active' &&
            (existing.targetKind == null ||
                existing.targetKind == action.targetKind) &&
            existing.lorebookEntryId == action.lorebookEntryId) {
          await observationRepo.confirmObservation(
            id: existing.id,
            runOrdinal: runOrdinal,
            confidence: action.confidence,
            now: now,
            evidenceMessageIds: action.evidenceMessageIds,
            retrievalKeys: action.retrievalKeys,
            targetKind: action.targetKind,
          );
        }
        break;
      case 'new':
        await observationRepo.insertOrReactivate(
          CardEvolutionObservation(
            id: 'observation-${generateId()}',
            sessionId: sessionId,
            characterId: characterId,
            runOrdinal: runOrdinal,
            semanticScopeKey: action.scopeKey,
            observedChange: action.observedChange,
            canonicalClaim: action.canonicalClaim,
            evidenceClusters: [action.evidenceMessageIds],
            retrievalKeys: action.retrievalKeys,
            targetKind: action.targetKind,
            cardFieldPath: action.cardFieldPath,
            lorebookEntryId: action.lorebookEntryId,
            confidence: action.confidence,
            status: 'active',
            firstSeenRun: runOrdinal,
            lastConfirmedRun: runOrdinal,
            createdAt: now,
            updatedAt: now,
          ),
        );
        break;
      case 'no_evidence':
        break;
      case 'contradict':
        final existing = await observationRepo.findByScopeKey(
          sessionId,
          action.scopeKey,
        );
        _requireCurrent(current);
        if (existing != null && existing.status == 'active') {
          await observationRepo.contradictObservation(existing.id, now: now);
        }
        break;
    }
  }

  Future<void> checkPromotions(
    String sessionId, {
    bool Function()? isInvocationCurrent,
  }) async {
    final current = _invocation(sessionId, isInvocationCurrent);
    if (!current()) return;
    final now = currentTimestampSeconds();
    final threshold = observationPromotionThreshold?.call() ?? 3;
    final minConfidence = observationMinConfidence?.call() ?? 0.7;
    final promotable = await observationRepo.getPromotableObservations(
      sessionId,
      minRepeatCount: threshold,
      minConfidence: minConfidence,
    );
    if (!current()) return;
    for (final obs in promotable) {
      if (!current()) return;
      await repo.db.transaction(() async {
        await _requireCommitCurrent(current);
        await observationRepo.promoteObservation(obs.id, now: now);
        await _requireCommitCurrent(current);
      });
    }
  }

  List<Map<String, Object?>> extractAccumulatedObservations(
    String selectedInputJson,
  ) {
    try {
      final input = jsonDecode(selectedInputJson) as Map;
      final targets = input['accumulatedObservations'];
      if (targets is! List) return const [];
      return [
        for (final target in targets)
          if (target is Map<String, Object?>) target,
      ];
    } catch (_) {
      return const [];
    }
  }

  String _buildObservationPrompt(CardEvolutionObservationSnapshot snapshot) {
    final activeMaps = extractAccumulatedObservations(
      snapshot.selectedInputJson,
    ).where((observation) => observation['status'] == 'active').toList();
    return '${CardRewriterPromptBuilder.buildObservationPass(character: snapshot.character, activeObservations: activeMaps, instruction: 'Review the last 40 immutable chat messages and the current Ledger-backed canon below. For each active observation, decide whether the chat history still supports it. Identify any new repeatedly demonstrated shift in preference, attitude, relationship dynamics, or lasting character development. Do not record one-off events or temporary state. Be conservative.')}\n\n# Immutable chat history and effective canon\n${_collectorContext(snapshot.selectedInputJson)}';
  }

  void cancelSession(String sessionId) {
    _cancellationEpochs.update(
      sessionId,
      (epoch) => epoch + 1,
      ifAbsent: () => 1,
    );
    _observationTokens[sessionId]?.cancel('generationAborted');
  }

  void dispose() {
    _disposed = true;
    for (final token in _observationTokens.values) {
      token.cancel('serviceDisposed');
    }
    _observationTokens.clear();
  }

  static Set<String>? _chatMessageIds(String selectedInputJson) {
    try {
      final decoded = jsonDecode(selectedInputJson);
      if (decoded is! Map || decoded['chatHistory'] is! List) return null;
      final result = <String>{};
      for (final message in decoded['chatHistory'] as List) {
        if (message is! Map || message['messageId'] is! String) return null;
        if (message['role'] == 'assistant' &&
            message['content'] is String &&
            CanonEvidenceText.assistantNarrative(
              message['content'] as String,
            ).trim().isEmpty) {
          continue;
        }
        result.add(message['messageId'] as String);
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  static Map<String, String>? _retrievalTargets(String selectedInputJson) {
    try {
      final decoded = jsonDecode(selectedInputJson);
      if (decoded is! Map ||
          decoded['availableObservationRetrievalTargets'] is! List) {
        return null;
      }
      final result = <String, String>{};
      for (final target
          in decoded['availableObservationRetrievalTargets'] as List) {
        if (target is! Map ||
            target['key'] is! String ||
            target['kind'] is! String) {
          return null;
        }
        result[target['key'] as String] = target['kind'] as String;
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  static String _collectorContext(String selectedInputJson) {
    try {
      final decoded = Map<String, Object?>.from(
        jsonDecode(CanonEvidenceText.projectContextJson(selectedInputJson))
            as Map,
      )..remove('card');
      return jsonEncode(decoded);
    } catch (_) {
      return selectedInputJson;
    }
  }
}

final class _CollectorCancelled implements Exception {
  const _CollectorCancelled();
}

final class _CollectorFinalizeResult {
  const _CollectorFinalizeResult.success()
    : success = true,
      code = 'completed',
      detail = null;

  const _CollectorFinalizeResult.failure(this.code, this.detail)
    : success = false;

  final bool success;
  final String code;
  final String? detail;
}
