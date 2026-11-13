import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../db/app_db.dart';
import '../../db/repositories/card_evolution_job_repo.dart';
import '../../db/repositories/card_evolution_repo.dart';
import '../../utils/time_helpers.dart';
import 'automated_card_evolution_service.dart';

typedef CardEvolutionJobFactory =
    Future<CardEvolutionJobExecution> Function(
      CardEvolutionJobRow job,
      bool Function() isCurrent,
    );

/// One execution owns its own service and cancellation tokens. It must not use
/// the manual/session-wide service: foreground Stop does not own these jobs.
abstract interface class CardEvolutionJobExecution {
  Future<CardEvolutionFinalizeOutcome> run(
    void Function(AutomatedCardEvolutionStage stage) onStage,
  );
  void dispose();
}

final class StaleCardEvolutionJob implements Exception {
  const StaleCardEvolutionJob();
}

/// App-scoped durable queue drain. The queue is in the repository, not a widget
/// or a chat generation. Automatic jobs are globally serialized (and repository
/// claims also enforce session exclusivity), without blocking foreground work.
final class CardEvolutionWorker {
  CardEvolutionWorker({
    required this.repo,
    required this.createExecution,
    this.onStage,
    this.onFinished,
    int Function()? now,
  }) : _now = now ?? currentTimestampSeconds;

  final CardEvolutionJobRepo repo;
  final CardEvolutionJobFactory createExecution;
  final void Function(CardEvolutionJobRow, AutomatedCardEvolutionStage)?
  onStage;
  final void Function(CardEvolutionJobRow, CardEvolutionFinalizeOutcome)?
  onFinished;
  final int Function() _now;
  final Set<String> _cancelled = {};
  bool _disposed = false;
  bool _dirty = false;
  Future<void>? _draining;
  Timer? _wakeTimer;
  Timer? _heartbeat;
  CardEvolutionJobRow? _active;
  CardEvolutionJobExecution? _execution;

  Future<void> recoverAndDrain() async {
    if (_disposed) return;
    await repo.recoverExpiredLeases(now: _now());
    if (_disposed) return;
    await notifyPending();
  }

  Future<void> notifyPending() {
    if (_disposed) return Future.value();
    _dirty = true;
    _wakeTimer?.cancel();
    final active = _draining;
    if (active != null) return active;
    final future = _drain();
    _draining = future;
    return future.whenComplete(() {
      _draining = null;
      if (_dirty && !_disposed) unawaited(notifyPending());
    });
  }

  Future<void> cancel(String id) async {
    _cancelled.add(id);
    if (_active?.id == id) _execution?.dispose();
    await repo.cancel(id: id, now: _now(), resultDetail: 'cancelled_by_user');
    if (_active?.id != id) _cancelled.remove(id);
    if (!_disposed) unawaited(notifyPending());
  }

  bool _isCurrent(CardEvolutionJobRow job) =>
      !_disposed && _active?.id == job.id && !_cancelled.contains(job.id);

  Future<void> _drain() async {
    try {
      while (!_disposed) {
        _dirty = false;
        final jobs = await repo.listUnfinished();
        if (_disposed || jobs.isEmpty) return;
        final now = _now();
        final ready = jobs
            .where((job) => job.status == 'pending' && job.availableAt <= now)
            .firstOrNull;
        if (ready == null) {
          final next = jobs
              .map(
                (job) => job.status == 'running'
                    ? job.leaseUntil ?? now + 1
                    : job.availableAt,
              )
              .reduce((a, b) => a < b ? a : b);
          _wakeTimer = Timer(Duration(seconds: (next - now).clamp(1, 900)), () {
            unawaited(recoverAndDrain());
          });
          return;
        }
        final claimed = await repo.claim(
          id: ready.id,
          now: now,
          leaseSeconds: 900,
        );
        if (_disposed) return;
        if (claimed == null) {
          // Another owner, stale source, or cancellation won admission. Re-read
          // only when notified, rather than spinning on an unclaimable row.
          _wakeTimer = Timer(const Duration(seconds: 2), () {
            unawaited(recoverAndDrain());
          });
          return;
        }
        _active = claimed;
        _heartbeat = Timer.periodic(const Duration(seconds: 120), (_) {
          unawaited(_renew(claimed));
        });
        try {
          final execution = await createExecution(
            claimed,
            () => _isCurrent(claimed),
          );
          _execution = execution;
          if (!_isCurrent(claimed)) {
            execution.dispose();
            continue;
          }
          final outcome = await execution.run((stage) {
            if (_isCurrent(claimed)) onStage?.call(claimed, stage);
          });
          if (!_isCurrent(claimed)) continue;
          final accepted = await repo.finish(
            id: claimed.id,
            ownerNonce: claimed.ownerNonce!,
            now: _now(),
            status: _success.contains(outcome.kind)
                ? CardEvolutionJobStatus.completed
                : CardEvolutionJobStatus.failed,
            resultDetail: outcome.kind,
          );
          if (accepted && _isCurrent(claimed)) {
            onFinished?.call(claimed, outcome);
          }
        } on StaleCardEvolutionJob {
          if (_isCurrent(claimed)) {
            await repo.finish(
              id: claimed.id,
              ownerNonce: claimed.ownerNonce!,
              now: _now(),
              status: CardEvolutionJobStatus.stale,
              resultDetail: 'source_or_routing_changed',
            );
          }
        } catch (error, stack) {
          debugPrint('[CardEvolutionWorker] job failed: $error\n$stack');
          if (_isCurrent(claimed)) {
            await repo.finish(
              id: claimed.id,
              ownerNonce: claimed.ownerNonce!,
              now: _now(),
              status: CardEvolutionJobStatus.failed,
              resultDetail: 'execution_failed',
            );
          }
        } finally {
          _heartbeat?.cancel();
          _heartbeat = null;
          _execution?.dispose();
          _execution = null;
          _active = null;
          _cancelled.remove(claimed.id);
        }
      }
    } catch (error, stack) {
      debugPrint('[CardEvolutionWorker] drain stopped: $error\n$stack');
    }
  }

  Future<void> _renew(CardEvolutionJobRow job) async {
    try {
      if (!_isCurrent(job)) return;
      final renewed = await repo.heartbeat(
        id: job.id,
        ownerNonce: job.ownerNonce!,
        now: _now(),
        leaseSeconds: 900,
      );
      if (!renewed && _isCurrent(job)) {
        _cancelled.add(job.id);
        _execution?.dispose();
      }
    } catch (_) {
      if (_isCurrent(job)) {
        _cancelled.add(job.id);
        _execution?.dispose();
      }
    }
  }

  static const _success = {
    'persisted',
    'emptyModelProposal',
    'collectorCompleted',
    'collectorUpToDate',
    'disabled',
  };

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _wakeTimer?.cancel();
    _heartbeat?.cancel();
    _execution?.dispose();
  }
}
