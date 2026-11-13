import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../db/repositories/card_evolution_observation_repo.dart';
import '../../db/repositories/card_evolution_collector_run_repo.dart';
import '../../db/repositories/card_evolution_repo.dart';
import '../../db/repositories/card_evolution_writer_call_repo.dart';
import '../../db/repositories/llm_request_capture_repo.dart';
import '../../db/app_db.dart';
import 'card_evolution_cadence.dart';
import 'card_evolution_collector_coordinator.dart';
import 'card_evolution_writer_coordinator.dart';
import 'card_evolution_diagnostics.dart';
import 'durable_writer_call_runner.dart';
import 'manual_rewrite_service.dart';
import 'writer_context_consolidator.dart';

const _writerLeaseSeconds = 600;

enum AutomatedCardEvolutionStage { observation, cardRewriter }

/// Dedicated review-only automation lane. Claim and final commit are repository
/// operations; the only work between them is shared-context prompt assembly and
/// two bounded, cancellable writer calls.
class AutomatedCardEvolutionService {
  AutomatedCardEvolutionService({
    required this.repo,
    required this.resolveModel,
    required this.resolveCollectorModel,
    required this._executor,
    this.isEnabled,
    this.isStillCurrent,
    this.isCommitCurrent,
    this.isLorebookEvolutionEnabled,
    this.timeoutMs = 180000,
    this.leaseSeconds = _writerLeaseSeconds,
    CardEvolutionObservationRepo? observationRepo,
    CardEvolutionCollectorRunRepo? collectorRunRepo,
    CardEvolutionWriterCallRepo? writerCallRepo,
    LlmRequestCaptureRepo? requestCaptureRepo,
    CardEvolutionDiagnostics? diagnostics,
    DurableWriterCallRunner? writerCallRunner,
    WriterContextConsolidator? writerContextConsolidator,
    CardEvolutionWriterCoordinator? writerCoordinator,
    CardEvolutionCollectorCoordinator? collectorCoordinator,
    this.observationPromotionThreshold,
    this.observationMinConfidence,
    this.observationExpiryRuns,
  }) : observationRepo =
           observationRepo ?? CardEvolutionObservationRepo(repo.db),
       collectorRunRepo =
           collectorRunRepo ?? CardEvolutionCollectorRunRepo(repo.db),
       writerCallRepo = writerCallRepo ?? CardEvolutionWriterCallRepo(repo.db),
       requestCaptureRepo =
           requestCaptureRepo ?? LlmRequestCaptureRepo(repo.db),
       _diagnostics = diagnostics ?? CardEvolutionDiagnostics(repo) {
    if (writerCoordinator != null) {
      _writerCoordinator = writerCoordinator;
    } else {
      final effectiveWriterCallRunner =
          writerCallRunner ??
          DurableWriterCallRunner(
            repo: repo,
            writerCallRepo: this.writerCallRepo,
            executor: _executeIfCurrent,
            diagnostics: _diagnostics,
            timeoutMs: timeoutMs,
            leaseSeconds: leaseSeconds,
          );
      _writerCoordinator = CardEvolutionWriterCoordinator(
        repo: repo,
        writerCallRepo: this.writerCallRepo,
        resolveModel: resolveModel,
        diagnostics: _diagnostics,
        writerCallRunner: effectiveWriterCallRunner,
        writerContextConsolidator: writerContextConsolidator,
        leaseSeconds: leaseSeconds,
        isLorebookEvolutionEnabled: isLorebookEvolutionEnabled,
        isStillCurrent: _isCurrent,
        isCommitCurrent: isCommitCurrent,
      );
    }
    _collectorCoordinator =
        collectorCoordinator ??
        CardEvolutionCollectorCoordinator(
          repo: repo,
          observationRepo: this.observationRepo,
          collectorRunRepo: this.collectorRunRepo,
          requestCaptureRepo: this.requestCaptureRepo,
          resolveModel: resolveCollectorModel,
          executor: _executeIfCurrent,
          diagnostics: _diagnostics,
          timeoutMs: timeoutMs,
          leaseSeconds: leaseSeconds,
          continueWriterAfterCollectors: _continueWriterAfterCollectors,
          observationPromotionThreshold: observationPromotionThreshold,
          observationMinConfidence: observationMinConfidence,
          observationExpiryRuns: observationExpiryRuns,
          isStillCurrent: _isCurrent,
          isCommitCurrent: isCommitCurrent,
        );
  }

  final CardEvolutionRepo repo;
  final CardEvolutionObservationRepo observationRepo;
  final CardEvolutionCollectorRunRepo collectorRunRepo;
  final CardEvolutionWriterCallRepo writerCallRepo;
  final LlmRequestCaptureRepo requestCaptureRepo;
  final CardEvolutionDiagnostics _diagnostics;
  late final CardEvolutionWriterCoordinator _writerCoordinator;
  late final CardEvolutionCollectorCoordinator _collectorCoordinator;
  final CardRewriteModelResolver resolveModel;
  final CardEvolutionCollectorModelResolver resolveCollectorModel;
  final CardRewriteLlmExecutor _executor;
  final bool Function()? isEnabled;
  final bool Function()? isStillCurrent;
  final Future<bool> Function()? isCommitCurrent;
  final bool Function()? isLorebookEvolutionEnabled;
  final int timeoutMs;
  final int leaseSeconds;
  final int Function()? observationPromotionThreshold;
  final double Function()? observationMinConfidence;
  final int Function()? observationExpiryRuns;
  final Map<String, Future<CardEvolutionFinalizeOutcome>> _inFlight = {};
  final Map<String, int> _cancellationEpochs = {};
  bool _disposed = false;

  bool _isCurrent() => !_disposed && isStillCurrent?.call() != false;

  // Capture once per invocation, not once per stage. Stop in the collector /
  // writer handoff must not give the writer a fresh cancellation lifetime.
  bool Function() _invocation(String sessionId, {Map<String, int>? epochs}) {
    final epoch = (epochs ?? _cancellationEpochs)[sessionId] ?? 0;
    var active = true;
    return () => active =
        active &&
        _isCurrent() &&
        (_cancellationEpochs[sessionId] ?? 0) == epoch;
  }

  CardRewriteLlmExecutor get _executeIfCurrent =>
      ({
        required config,
        required prompt,
        required maxTokens,
        required temperature,
        required timeoutMs,
        cancelToken,
        captureContext,
      }) async {
        if (!_isCurrent() || cancelToken?.isCancelled == true) {
          cancelToken?.cancel('generationAborted');
          throw DioException.requestCancelled(
            requestOptions: RequestOptions(),
            reason: 'Evolution invocation is no longer current',
          );
        }
        final outcome = await _executor(
          config: config,
          prompt: prompt,
          maxTokens: maxTokens,
          temperature: temperature,
          timeoutMs: timeoutMs,
          cancelToken: cancelToken,
          captureContext: captureContext,
        );
        if (!_isCurrent()) cancelToken?.cancel('generationAborted');
        return outcome;
      };

  Future<CardEvolutionFinalizeOutcome> runOneBatch(
    String sessionId, {
    void Function(AutomatedCardEvolutionStage stage)? onStage,
  }) {
    if (!_isCurrent()) {
      return Future.value(const CardEvolutionFinalizeOutcome('cancelled'));
    }
    if (isEnabled?.call() == false) {
      return Future.value(const CardEvolutionFinalizeOutcome('disabled'));
    }
    final active = _inFlight[sessionId];
    if (active != null) return active;
    final future = _runManual(
      sessionId,
      current: _invocation(sessionId),
      onStage: onStage,
    );
    _inFlight[sessionId] = future;
    return future.whenComplete(() => _inFlight.remove(sessionId));
  }

  Future<CardEvolutionFinalizeOutcome> _runManual(
    String sessionId, {
    required bool Function() current,
    void Function(AutomatedCardEvolutionStage stage)? onStage,
  }) async {
    // Explicit "Run now" retains its historical convenience: on each complete
    // reconciliation batch it also refreshes observations. Automatic cadence
    // never uses this path.
    try {
      final count = await repo.countSuccessfulReconciliations(sessionId);
      if (!current()) return const CardEvolutionFinalizeOutcome('cancelled');
      if (count > 0 && count % collectorReconciliationBatchSize == 0) {
        onStage?.call(AutomatedCardEvolutionStage.observation);
        final snapshot = await repo.buildObservationSnapshot(sessionId);
        if (!current()) return const CardEvolutionFinalizeOutcome('cancelled');
        if (snapshot != null) {
          var collectorAborted = false;
          await _collectorCoordinator.runObservationPass(
            sessionId,
            snapshot,
            count ~/ collectorReconciliationBatchSize,
            isInvocationCurrent: current,
            onFailure: ({required code, detail, callId}) async {
              collectorAborted = code == 'aborted' || code == 'cancelled';
            },
          );
          if (!current() || collectorAborted) {
            return const CardEvolutionFinalizeOutcome('cancelled');
          }
          await _collectorCoordinator.checkPromotions(
            sessionId,
            isInvocationCurrent: current,
          );
        }
      }
    } catch (error) {
      if (error is DioException && CancelToken.isCancel(error)) {
        return const CardEvolutionFinalizeOutcome('cancelled');
      }
      // Manual observation refresh is best effort; writer remains available.
    }
    if (!current()) return const CardEvolutionFinalizeOutcome('cancelled');
    return _runWriter(sessionId, current: current, onStage: onStage);
  }

  /// Automatic lane: collect each completed batch of valid reconciliations,
  /// then run at most one overdue writer cycle per five collectors.
  Future<CardEvolutionFinalizeOutcome> runAfterReconciliation(
    LedgerReconciliationSuccessfulRunRow reconciliationRun, {
    void Function(AutomatedCardEvolutionStage stage)? onStage,
  }) {
    if (!_isCurrent()) {
      return Future.value(const CardEvolutionFinalizeOutcome('cancelled'));
    }
    if (isEnabled?.call() == false) {
      return Future.value(const CardEvolutionFinalizeOutcome('disabled'));
    }
    final sessionId = reconciliationRun.sessionId;
    final current = _invocation(sessionId);
    final active = _inFlight[sessionId];
    if (active != null) {
      // Do not silently absorb a newer reconciliation while the previous
      // collector is running. Re-enter after it finishes; the durable backlog
      // makes this idempotent when the newer callback names the same head.
      return () async {
        try {
          await active;
        } catch (_) {
          // A failed active attempt must not discard the newer durable head.
        }
        if (!current()) return const CardEvolutionFinalizeOutcome('cancelled');
        return runAfterReconciliation(reconciliationRun, onStage: onStage);
      }();
    }
    final future = _runAutomatic(
      reconciliationRun,
      current: current,
      onStage: onStage,
    );
    _inFlight[sessionId] = future;
    return future.whenComplete(() => _inFlight.remove(sessionId));
  }

  /// Recovery lane for valid reconciliation batches that automatic dispatch did
  /// not process. Existing failed or live claims remain on their explicit
  /// recovery paths and are never bypassed.
  Future<CardEvolutionFinalizeOutcome> runPendingCollectors(String sessionId) {
    if (!_isCurrent()) {
      return Future.value(const CardEvolutionFinalizeOutcome('cancelled'));
    }
    if (isEnabled?.call() == false) {
      return Future.value(const CardEvolutionFinalizeOutcome('disabled'));
    }
    final active = _inFlight[sessionId];
    if (active != null) return active;
    final future = _runPendingCollectors(
      sessionId,
      current: _invocation(sessionId),
    );
    _inFlight[sessionId] = future;
    return future.whenComplete(() => _inFlight.remove(sessionId));
  }

  Future<CardEvolutionFinalizeOutcome> retryFailedCollector(
    String collectorRunId,
  ) => _recoverFailedCollector(collectorRunId);

  Future<CardEvolutionFinalizeOutcome> resumeFailedWriter(String claimId) =>
      _recoverWriter(claimId);

  Future<CardEvolutionDeleteOutcome> deleteFailedWriter(String claimId) async {
    if (!_isCurrent()) return const CardEvolutionDeleteOutcome('cancelled');
    final claim = await repo.getClaimById(claimId);
    if (!_isCurrent()) return const CardEvolutionDeleteOutcome('cancelled');
    if (claim == null) return const CardEvolutionDeleteOutcome('notFound');
    if (_inFlight.containsKey(claim.sessionId)) {
      return const CardEvolutionDeleteOutcome('busy');
    }
    return repo.deleteFailedWriterClaim(claimId);
  }

  Future<CardEvolutionFinalizeOutcome> retryFailedWriterCall(String callId) =>
      _recoverWriterCall(callId);

  Future<CardEvolutionFinalizeOutcome> correctFailedWriterCall(
    String callId, {
    required String response,
  }) => _recoverWriterCall(callId, manualResponse: response);

  Future<CardEvolutionFinalizeOutcome> _recoverWriterCall(
    String callId, {
    String? manualResponse,
  }) async {
    if (!_isCurrent()) return const CardEvolutionFinalizeOutcome('cancelled');
    final epochs = Map<String, int>.of(_cancellationEpochs);
    final call = await writerCallRepo.getById(callId);
    if (!_isCurrent()) return const CardEvolutionFinalizeOutcome('cancelled');
    if (call == null) {
      return const CardEvolutionFinalizeOutcome('writerCallNotFound');
    }
    if (call.status != 'failed') {
      return const CardEvolutionFinalizeOutcome('writerCallNotFailed');
    }
    final chain = await writerCallRepo.readChain(call.claimId);
    if (!_isCurrent()) return const CardEvolutionFinalizeOutcome('cancelled');
    final frontier = chain
        .where((row) => row.status != 'completed')
        .firstOrNull;
    if (frontier?.id != call.id) {
      return const CardEvolutionFinalizeOutcome('writerCallNotFrontier');
    }
    return _recoverWriter(
      call.claimId,
      requestedCallId: call.id,
      manualResponse: manualResponse,
      epochs: epochs,
    );
  }

  Future<CardEvolutionFinalizeOutcome> _recoverWriter(
    String claimId, {
    String? requestedCallId,
    String? manualResponse,
    Map<String, int>? epochs,
  }) async {
    if (!_isCurrent()) return const CardEvolutionFinalizeOutcome('cancelled');
    epochs ??= Map<String, int>.of(_cancellationEpochs);
    final initial = await repo.getClaimById(claimId);
    if (!_isCurrent()) return const CardEvolutionFinalizeOutcome('cancelled');
    if (initial == null) {
      return const CardEvolutionFinalizeOutcome('claimMissing');
    }
    final current = _invocation(initial.sessionId, epochs: epochs);
    if (!current()) return const CardEvolutionFinalizeOutcome('cancelled');
    if (initial.status != 'failed') {
      return const CardEvolutionFinalizeOutcome('writerNotFailed');
    }
    final active = _inFlight[initial.sessionId];
    if (active != null) return active;
    final future = _recoverWriterUnshared(
      initial,
      requestedCallId: requestedCallId,
      manualResponse: manualResponse,
      current: current,
    );
    _inFlight[initial.sessionId] = future;
    return future.whenComplete(() => _inFlight.remove(initial.sessionId));
  }

  Future<CardEvolutionFinalizeOutcome> _recoverWriterUnshared(
    CardEvolutionClaimRow failed, {
    required bool Function() current,
    String? requestedCallId,
    String? manualResponse,
  }) => _writerCoordinator.recoverWriterUnshared(
    failed,
    requestedCallId: requestedCallId,
    manualResponse: manualResponse,
    isInvocationCurrent: current,
  );

  Future<CardEvolutionFinalizeOutcome> correctFailedCollector(
    String collectorRunId, {
    required String response,
  }) => _recoverFailedCollector(collectorRunId, manualResponse: response);

  Future<CardEvolutionFinalizeOutcome> _recoverFailedCollector(
    String collectorRunId, {
    String? manualResponse,
  }) async {
    if (!_isCurrent()) return const CardEvolutionFinalizeOutcome('cancelled');
    final epochs = Map<String, int>.of(_cancellationEpochs);
    final initial = await collectorRunRepo.getById(collectorRunId);
    if (!_isCurrent()) return const CardEvolutionFinalizeOutcome('cancelled');
    if (initial == null) {
      return const CardEvolutionFinalizeOutcome('collectorNotFound');
    }
    final current = _invocation(initial.sessionId, epochs: epochs);
    if (!current()) return const CardEvolutionFinalizeOutcome('cancelled');
    if (initial.status != 'failed') {
      return const CardEvolutionFinalizeOutcome('collectorNotFailed');
    }
    final active = _inFlight[initial.sessionId];
    if (active != null) return active;
    final future = _recoverFailedCollectorUnshared(
      initial,
      manualResponse: manualResponse,
      current: current,
    );
    _inFlight[initial.sessionId] = future;
    return future.whenComplete(() => _inFlight.remove(initial.sessionId));
  }

  Future<CardEvolutionFinalizeOutcome> _recoverFailedCollectorUnshared(
    CardEvolutionCollectorRunRow failed, {
    required bool Function() current,
    String? manualResponse,
  }) => _collectorCoordinator.recoverFailedCollectorUnshared(
    failed,
    manualResponse: manualResponse,
    isInvocationCurrent: current,
    continueWriter: (sessionId) =>
        _continueWriterAfterCollectors(sessionId, current: current),
  );

  Future<CardEvolutionFinalizeOutcome> _runAutomatic(
    LedgerReconciliationSuccessfulRunRow reconciliationRun, {
    required bool Function() current,
    void Function(AutomatedCardEvolutionStage stage)? onStage,
  }) => _runPendingCollectors(
    reconciliationRun.sessionId,
    current: current,
    currentRun: reconciliationRun,
    onStage: onStage,
  );

  Future<CardEvolutionFinalizeOutcome> _runPendingCollectors(
    String sessionId, {
    required bool Function() current,
    LedgerReconciliationSuccessfulRunRow? currentRun,
    void Function(AutomatedCardEvolutionStage stage)? onStage,
  }) async {
    try {
      final pending = await collectorRunRepo.pendingValidPairs(
        sessionId,
        currentRun: currentRun,
      );
      if (!current()) return const CardEvolutionFinalizeOutcome('cancelled');
      if (pending.isEmpty && currentRun == null) {
        return const CardEvolutionFinalizeOutcome('collectorUpToDate');
      }
      for (final batch in pending) {
        final collected = await _collectorCoordinator.runCollector(
          batch,
          isInvocationCurrent: current,
          onObservationStage: () =>
              onStage?.call(AutomatedCardEvolutionStage.observation),
        );
        if (!current()) return const CardEvolutionFinalizeOutcome('cancelled');
        if (!collected) {
          return const CardEvolutionFinalizeOutcome('collectorUnavailable');
        }
      }
      return await _continueWriterAfterCollectors(
        sessionId,
        current: current,
        onStage: onStage,
        maxCollectorOrdinal: currentRun == null
            ? null
            : currentRun.ordinal ~/ collectorReconciliationBatchSize,
      );
    } catch (error, stackTrace) {
      if (!current()) return const CardEvolutionFinalizeOutcome('cancelled');
      debugPrint(
        '[CardRewriter] automatic lane failed before a durable writer result: '
        '$error\n$stackTrace',
      );
      await _diagnostics.saveSelectionBail(
        sessionId: sessionId,
        outcome: 'unexpectedFailure',
        reason: error.toString(),
        throughCollectorOrdinal: 0,
        reconciliationRunIds: currentRun == null ? const [] : [currentRun.id],
      );
      return CardEvolutionFinalizeOutcome(
        'unexpectedFailure',
        null,
        error.toString(),
      );
    }
  }

  Future<CardEvolutionFinalizeOutcome> _continueWriterAfterCollectors(
    String sessionId, {
    bool Function()? current,
    void Function(AutomatedCardEvolutionStage stage)? onStage,
    int? maxCollectorOrdinal,
  }) async {
    current ??= _invocation(sessionId);
    if (!current()) return const CardEvolutionFinalizeOutcome('cancelled');
    final delivered = await collectorRunRepo.latestDeliveredWriterBoundary(
      sessionId,
    );
    if (!current()) return const CardEvolutionFinalizeOutcome('cancelled');
    final collectorCount = CardEvolutionWriterCadence.current.collectorCount;
    final dueBoundary = delivered + collectorCount;
    if (maxCollectorOrdinal != null && dueBoundary > maxCollectorOrdinal) {
      return const CardEvolutionFinalizeOutcome('collectorCompleted');
    }
    final latest = await collectorRunRepo.latestCompletedOrdinal(sessionId);
    if (!current()) return const CardEvolutionFinalizeOutcome('cancelled');
    if (latest < dueBoundary) {
      return const CardEvolutionFinalizeOutcome('collectorCompleted');
    }
    final boundaryRuns = await collectorRunRepo.completedBoundary(
      sessionId,
      dueBoundary,
      count: collectorCount,
    );
    if (!current()) return const CardEvolutionFinalizeOutcome('cancelled');
    if (boundaryRuns.length != collectorCount) {
      return const CardEvolutionFinalizeOutcome('collectorUnavailable');
    }
    final reconciliationRuns = await collectorRunRepo.runsForCollectors(
      sessionId,
      boundaryRuns,
    );
    if (!current()) return const CardEvolutionFinalizeOutcome('cancelled');
    if (reconciliationRuns.length !=
        collectorCount * collectorReconciliationBatchSize) {
      return const CardEvolutionFinalizeOutcome('collectorUnavailable');
    }
    return _runWriter(
      sessionId,
      current: current,
      onStage: onStage,
      throughCollectorOrdinal: dueBoundary,
      collectorBoundaryHash: boundaryRuns.last.reconciliationChainHash,
      collectorBoundaryRuns: boundaryRuns,
      reconciliationRunIds: [for (final run in reconciliationRuns) run.id],
    );
  }

  Future<CardEvolutionFinalizeOutcome> _runWriter(
    String sessionId, {
    required bool Function() current,
    void Function(AutomatedCardEvolutionStage stage)? onStage,
    int throughCollectorOrdinal = 0,
    String collectorBoundaryHash = '',
    List<CardEvolutionCollectorRunRow> collectorBoundaryRuns = const [],
    List<String>? reconciliationRunIds,
  }) async {
    if (!current()) return const CardEvolutionFinalizeOutcome('cancelled');
    onStage?.call(AutomatedCardEvolutionStage.cardRewriter);
    if (!current()) return const CardEvolutionFinalizeOutcome('cancelled');
    return _writerCoordinator.runWriter(
      sessionId,
      isInvocationCurrent: current,
      throughCollectorOrdinal: throughCollectorOrdinal,
      collectorBoundaryHash: collectorBoundaryHash,
      collectorBoundaryRuns: collectorBoundaryRuns,
      reconciliationRunIds: reconciliationRunIds,
    );
  }

  void cancelSession(String sessionId) {
    _cancellationEpochs.update(
      sessionId,
      (epoch) => epoch + 1,
      ifAbsent: () => 1,
    );
    _collectorCoordinator.cancelSession(sessionId);
    _writerCoordinator.cancelSession(sessionId);
  }

  void dispose() {
    _disposed = true;
    _collectorCoordinator.dispose();
    _writerCoordinator.dispose();
  }
}
