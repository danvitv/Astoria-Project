import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/card_rewrite/card_rewriter_recovery_view_service.dart';
import '../../features/chat/services/collector_view_service.dart';
import '../../features/chat/services/prompt_capture_view_service.dart';
import '../../features/chat/state/chat_native_owner_registry.dart';
import '../db/app_db.dart';
import '../db/repositories/card_evolution_job_repo.dart';
import '../db/repositories/card_evolution_repo.dart';
import '../llm/aux_llm_client.dart';
import '../llm/card_rewrite_slot_resolver.dart';
import '../llm/studio_turn_config_snapshot.dart';
import '../navigation/rewrite_review_navigation.dart';
import '../services/card_rewriter/automated_card_evolution_service.dart';
import '../services/card_rewriter/card_evolution_job_context.dart';
import '../services/card_rewriter/card_evolution_worker.dart';
import '../services/generation_notification_service.dart';
import '../utils/time_helpers.dart';
import '../utils/cast_helpers.dart';
import 'card_rewriter_providers.dart';
import 'db_provider.dart';
import 'studio_turn_config_resolver.dart';

final cardEvolutionJobRepoProvider = Provider<CardEvolutionJobRepo>(
  (ref) => CardEvolutionJobRepo(ref.watch(appDbProvider)),
);

final cardEvolutionJobsProvider =
    StreamProvider.family<List<CardEvolutionJobRow>, String>(
      (ref, sessionId) =>
          ref.watch(cardEvolutionJobRepoProvider).watchSessionJobs(sessionId),
    );

/// Separate from chat/AbortHandler ownership. New Send/foreground Stop cannot
/// cancel a previous turn's review-only work; the queue exposes explicit Cancel.
final class CardEvolutionBackgroundController {
  CardEvolutionBackgroundController(this._ref, this.repo) {
    worker = CardEvolutionWorker(
      repo: repo,
      createExecution: _createExecution,
      onFinished: _finished,
    );
  }

  final Ref _ref;
  final CardEvolutionJobRepo repo;
  late final CardEvolutionWorker worker;
  final _contexts = <String, CardEvolutionJobContext>{};
  final _authorities = <String, ActiveChatContext?>{};

  /// Prepare credentials/settings before model work. The returned callback is
  /// repository-only and runs inside the reconciliation commit transaction.
  Future<void> Function(LedgerReconciliationSuccessfulRunRow)
  prepareReservation({
    required String sessionId,
    required String characterId,
    required StudioTurnConfigSnapshot turn,
  }) {
    final context = CardEvolutionJobContext.capture(turn);
    final authority = captureAutomaticRewriteReviewAuthority(
      charId: characterId,
      sessionId: sessionId,
    );
    return (run) async {
      final job = await repo.enqueue(
        sessionId: sessionId,
        characterId: characterId,
        reconciliationRunId: run.id,
        routingSnapshotJson: context.descriptorJson,
        routingSnapshotHash: computeHash(context.descriptorJson),
        now: currentTimestampSeconds(),
      );
      if (!_ref.mounted) return;
      if (job.status == 'pending' && context.matches(job.routingSnapshotJson)) {
        _contexts.putIfAbsent(job.id, () => context);
        _authorities.putIfAbsent(job.id, () => authority);
      }
    };
  }

  void notifyCommitted() {
    if (_ref.mounted) unawaited(worker.notifyPending());
  }

  Future<void> recoverAndDrain() => worker.recoverAndDrain();

  Future<void> cancel(String id) async {
    _contexts.remove(id);
    _authorities.remove(id);
    await worker.cancel(id);
  }

  Future<CardEvolutionJobExecution> _createExecution(
    CardEvolutionJobRow job,
    bool Function() isCurrent,
  ) async {
    Future<void> requireOwned() async {
      if (!isCurrent() ||
          !_ref.mounted ||
          !await repo.isOwned(
            id: job.id,
            ownerNonce: job.ownerNonce!,
            now: currentTimestampSeconds(),
          )) {
        throw const StaleCardEvolutionJob();
      }
    }

    await requireOwned();
    if (computeHash(job.routingSnapshotJson) != job.routingSnapshotHash) {
      throw const StaleCardEvolutionJob();
    }
    var context = _contexts.remove(job.id);
    if (context == null) {
      final turn = await _ref
          .read(studioTurnConfigResolverProvider)
          .resolve(job.sessionId);
      await requireOwned();
      context = CardEvolutionJobContext.capture(turn);
      // Never silently replay old work using today's different model/settings.
      if (!context.matches(job.routingSnapshotJson)) {
        throw const StaleCardEvolutionJob();
      }
    }
    final captured = context;
    final runs = await _ref
        .read(ledgerReconciliationRunRepoProvider)
        .readSession(job.sessionId);
    await requireOwned();
    final run = runs
        .where((run) => run.id == job.reconciliationRunId)
        .firstOrNull;
    if (run == null) throw const StaleCardEvolutionJob();
    final llm = AuxLlmClient(
      sources: _ref.read(nativeProviderRuntimeProvider)?.sources,
    );
    final service = AutomatedCardEvolutionService(
      repo: _ref.read(cardEvolutionRepoProvider),
      writerCallRepo: _ref.read(cardEvolutionWriterCallRepoProvider),
      requestCaptureRepo: _ref.read(llmRequestCaptureRepoProvider),
      isStillCurrent: () => isCurrent() && _ref.mounted,
      isCommitCurrent: () async =>
          isCurrent() &&
          _ref.mounted &&
          await repo.isOwned(
            id: job.id,
            ownerNonce: job.ownerNonce!,
            now: currentTimestampSeconds(),
          ),
      resolveCollectorModel: (_) async {
        await requireOwned();
        return captured.collector;
      },
      resolveModel: () async {
        await requireOwned();
        return captured.writer ??
            (throw const CardRewriteModelNotConfigured(
              'Captured writer slot is not configured',
            ));
      },
      isEnabled: () => captured.settings.enabled,
      isLorebookEvolutionEnabled: () =>
          captured.settings.lorebookEvolutionEnabled,
      timeoutMs: captured.settings.timeoutMs,
      observationPromotionThreshold: () =>
          captured.settings.observationPromotionThreshold,
      observationMinConfidence: () =>
          captured.settings.observationMinConfidence,
      observationExpiryRuns: () => captured.settings.observationExpiryRuns,
      executor:
          ({
            required config,
            required prompt,
            required maxTokens,
            required temperature,
            required timeoutMs,
            cancelToken,
            captureContext,
          }) async {
            await requireOwned();
            final result = await llm.callOnceWithLog(
              config: config,
              prompt: prompt,
              maxTokens: maxTokens,
              temperature: temperature,
              timeoutMs: timeoutMs,
              cancelToken: cancelToken,
              captureContext: captureContext,
            );
            await requireOwned();
            return result;
          },
    );
    return _Execution(service, run);
  }

  void _finished(
    CardEvolutionJobRow job,
    CardEvolutionFinalizeOutcome outcome,
  ) {
    if (!_ref.mounted) return;
    _ref.invalidate(collectorViewProvider(job.sessionId));
    _ref.invalidate(promptCaptureViewsProvider(job.sessionId));
    _ref.invalidate(cardRewriteDebugRunsProvider(job.sessionId));
    _ref.invalidate(cardRewriterRecoveryViewsProvider(job.sessionId));
    final authority = _authorities.remove(job.id);
    // A completed old review must not pull the user out of a newer generation.
    final busy = _ref
        .read(chatNativeOwnerRegistryProvider)
        .loaded
        .any((owner) => owner.sessionId() == job.sessionId && !owner.isIdle());
    if (!busy) {
      emitAutomaticRewriteReviewIntent(
        _ref,
        outcome: outcome,
        capturedAuthority: authority,
      );
    }
  }

  void dispose() {
    worker.dispose();
    _contexts.clear();
    _authorities.clear();
  }
}

final class _Execution implements CardEvolutionJobExecution {
  _Execution(this.service, this.runHead);
  final AutomatedCardEvolutionService service;
  final LedgerReconciliationSuccessfulRunRow runHead;

  @override
  Future<CardEvolutionFinalizeOutcome> run(
    void Function(AutomatedCardEvolutionStage) onStage,
  ) => service.runAfterReconciliation(runHead, onStage: onStage);
  @override
  void dispose() => service.dispose();
}

final cardEvolutionBackgroundProvider =
    Provider<CardEvolutionBackgroundController>((ref) {
      final controller = CardEvolutionBackgroundController(
        ref,
        ref.watch(cardEvolutionJobRepoProvider),
      );
      ref.onDispose(controller.dispose);
      return controller;
    });
