import 'dart:async';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/credentials/memory_custom_api_credential_owner.dart';
import '../../../core/credentials/native_provider_credentials.dart';
import '../../../core/db/app_db.dart';
import '../../../core/db/repositories/memory_event_registry_repo.dart';
import '../../../core/llm/memory_consolidation_batch_planner.dart';
import '../../../core/llm/memory_book_api_config_resolver.dart';
import '../../../core/llm/memory_draft_api_source.dart';
import '../../../core/llm/memory_retrieval_mode.dart';
import '../../../core/models/memory_book.dart';
import '../../../core/models/memory_book_api_settings.dart';
import '../../../core/models/pipeline_settings.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/memory_custom_api_credentials_provider.dart';
import '../../../core/state/memory_settings_provider.dart';
import '../../../core/utils/id_generator.dart';
import '../../settings/api_list_provider.dart';
import 'memory_active_drafts_provider.dart';

/// App-scoped owner of automatic MemoryBook package consolidation.
///
/// The durable job repository remains the only queue. This class merely
/// coalesces session notifications, waits for memory-draft leases to settle,
/// and drains pending package jobs into reviewable drafts.
final class MemoryConsolidationWorker {
  MemoryConsolidationWorker(this._ref);

  static const _leaseDurationSeconds = 900;
  static const _leaseHeartbeat = Duration(seconds: 300);

  final Ref _ref;
  final String _workerNonce = _newWorkerNonce();
  final Map<String, _SessionDrain> _sessions = {};
  bool _disposed = false;
  Future<void>? _recovery;

  /// Called only after a memory draft approval has committed.
  void notifyApproval(String sessionId) =>
      _schedule(sessionId, enqueueApprovedEntries: true);

  /// Wakes an already-durable pending queue without creating or retrying jobs.
  void notifyPending(String sessionId) =>
      _schedule(sessionId, enqueueApprovedEntries: false);

  void _schedule(String sessionId, {required bool enqueueApprovedEntries}) {
    if (_disposed || sessionId.isEmpty) return;
    var session = _sessions[sessionId];
    if (session == null) {
      session = _SessionDrain();
      _sessions[sessionId] = session;
      _watchSessionJobs(sessionId, session);
    }
    session.dirty = true;
    session.enqueueApprovedEntries |= enqueueApprovedEntries;
    if (session.running) return;
    session.running = true;
    unawaited(_drain(sessionId, session));
  }

  void _watchSessionJobs(String sessionId, _SessionDrain session) {
    session.jobsSubscription = _ref
        .read(memoryConsolidationJobRepoProvider)
        .watchSessionJobs(sessionId)
        .listen((jobs) {
          final claimedJobId = session.claimedJobId;
          if (claimedJobId != null &&
              jobs.any(
                (job) => job.id == claimedJobId && job.status == 'cancelled',
              )) {
            session.token?.cancel('Durable consolidation job was cancelled');
          }
          if (jobs.any((job) => job.status == 'pending')) {
            notifyPending(sessionId);
          }
        });
  }

  /// Startup/resume recovery is intentionally narrow: only expired leases are
  /// made pending. Failed, cancelled and review-pending jobs are never revived.
  Future<void> recoverAndDrain() {
    final active = _recovery;
    if (active != null) return active;
    final run = _recoverAndDrain();
    _recovery = run.whenComplete(() => _recovery = null);
    return _recovery!;
  }

  Future<void> _recoverAndDrain() async {
    if (_disposed) return;
    try {
      await _ref
          .read(memoryConsolidationJobRepoProvider)
          .recoverExpiredLeases();
      if (_disposed || !_ref.mounted) return;
      final books = await _ref.read(memoryBookRepoProvider).getAll();
      if (_disposed || !_ref.mounted) return;
      for (final book in books) {
        if (_consolidationEnabled(book.settings)) {
          // This also closes the crash window between durable approval and its
          // enqueue notification. Exact reservations keep existing pending or
          // reviewed work idempotent, while cancelled/rejected jobs stay dead.
          notifyApproval(book.sessionId);
        }
      }
    } catch (error, stackTrace) {
      debugPrint('Memory consolidation recovery failed: $error\n$stackTrace');
    }
  }

  /// A package must wait until all memory-generation owners release the
  /// session. No timer is needed: the provider listener wakes the dirty session
  /// when the final lease settles, including after partial generation failure.
  void activeDraftsChanged(Set<String> active) {
    if (_disposed) return;
    for (final entry in _sessions.entries.toList()) {
      final session = entry.value;
      if (session.waitingForDrafts && !active.contains(entry.key)) {
        session.waitingForDrafts = false;
        _schedule(
          entry.key,
          enqueueApprovedEntries: session.enqueueApprovedEntries,
        );
      }
    }
  }

  /// Invalidates transport and durable ownership after mode/API/source changes.
  void invalidateContexts() {
    for (final sessionId in _sessions.keys.toList()) {
      cancelSession(sessionId, reason: 'Memory consolidation context changed');
    }
  }

  void cancelSession(String sessionId, {String reason = 'Cancelled'}) {
    final session = _sessions[sessionId];
    if (session == null) return;
    session.epoch++;
    session.dirty = false;
    session.enqueueApprovedEntries = false;
    session.heartbeat?.cancel();
    session.heartbeat = null;
    session.token?.cancel(reason);
    final jobId = session.claimedJobId;
    if (jobId != null && _ref.mounted) {
      unawaited(
        _ref.read(memoryConsolidationJobRepoProvider).cancel(jobId).catchError((
          Object error,
        ) {
          debugPrint('Memory consolidation durable cancel failed: $error');
          return false;
        }),
      );
    }
  }

  void bookContextChanged(String sessionId) {
    cancelSession(sessionId, reason: 'MemoryBook source context changed');
  }

  Future<void> _drain(String sessionId, _SessionDrain session) async {
    try {
      while (!_disposed && _ref.mounted && session.dirty) {
        final enqueueApprovedEntries = session.enqueueApprovedEntries;
        session.dirty = false;
        session.enqueueApprovedEntries = false;

        if (_ref.read(memoryActiveDraftsProvider).contains(sessionId)) {
          session.waitingForDrafts = true;
          session.dirty = true;
          session.enqueueApprovedEntries |= enqueueApprovedEntries;
          return;
        }

        final repo = _ref.read(memoryBookRepoProvider);
        final book = await repo.getBySessionId(sessionId);
        if (_disposed || !_ref.mounted) return;
        if (book == null || !_consolidationEnabled(book.settings)) {
          cancelSession(sessionId, reason: 'Memory consolidation mode is off');
          return;
        }

        final pipeline = _ref.read(pipelineSettingsProvider);
        final apiSettings = pipeline.memoryBookApi;
        if (enqueueApprovedEntries) {
          await _enqueueThresholdPackage(book, apiSettings);
          if (_disposed || !_ref.mounted) return;
        }

        while (!_disposed && _ref.mounted) {
          final latest = await repo.getBySessionId(sessionId);
          if (_disposed || !_ref.mounted) return;
          if (latest == null || !_consolidationEnabled(latest.settings)) {
            cancelSession(
              sessionId,
              reason: 'Memory consolidation mode is off',
            );
            return;
          }
          final ran = await _runOnce(sessionId, latest, apiSettings, session);
          if (!ran) break;
        }
      }
    } catch (error, stackTrace) {
      // The durable job records its own failed state. Automatic work stops here;
      // only an explicit retry may make that job pending again.
      debugPrint('Memory consolidation worker failed: $error\n$stackTrace');
    } finally {
      session.running = false;
      session.token = null;
      session.claimedJobId = null;
      if (!_disposed && session.dirty && !session.waitingForDrafts) {
        _schedule(
          sessionId,
          enqueueApprovedEntries: session.enqueueApprovedEntries,
        );
      }
    }
  }

  Future<void> _enqueueThresholdPackage(
    MemoryBook book,
    MemoryBookApiSettings apiSettings,
  ) async {
    final configs = await _ref.read(apiListProvider.future);
    if (_disposed || !_ref.mounted) return;
    final selected = apiSettings.generationSource == 'custom'
        ? null
        : MemoryBookApiConfigResolver(
            apiConfigs: configs,
            activeConfig: _ref.read(activeApiConfigProvider),
          ).resolve(apiSettings);
    await _ref
        .read(memoryConsolidationBatchProvider)
        .enqueuePending(
          sessionId: book.sessionId,
          branchId: book.sessionId,
          entries: book.entries,
          minCount: book.settings.consolidationThreshold,
          budget: MemoryConsolidationRequestBudget.forApi(
            settings: apiSettings,
            config: selected,
          ),
        );
  }

  Future<bool> _runOnce(
    String sessionId,
    MemoryBook book,
    MemoryBookApiSettings apiSettings,
    _SessionDrain session,
  ) async {
    final token = CancelToken();
    final epoch = ++session.epoch;
    final ownerId = 'app-memory-$_workerNonce-${generateId()}';
    final bookSettings = book.settings;
    session.token = token;
    session.claimedJobId = null;

    bool isCurrent() =>
        !_disposed &&
        _ref.mounted &&
        session.epoch == epoch &&
        identical(session.token, token) &&
        !token.isCancelled &&
        _ref.read(pipelineSettingsProvider).memoryBookApi == apiSettings &&
        _consolidationEnabled(bookSettings) &&
        _globalConsolidationEnabled;

    final customOwner = apiSettings.generationSource == 'custom'
        ? _ref.read(memoryCustomApiCredentialOwnerProvider)
        : null;
    final MemoryCustomApiInvocation? customInvocation = customOwner?.capture(
      apiSettings,
      isCurrent: isCurrent,
    );
    final sources = _ref.read(nativeProviderRuntimeProvider)?.sources;
    final NativeConnectionStamp? originalStamp =
        apiSettings.generationSource == 'custom'
        ? null
        : sources?.captureOriginalStamp();
    final resolver = MemoryDraftApiSourceResolver(
      sources: sources,
      loadApiConfigs: () async {
        await _ref.read(apiListProvider.future);
        if (!isCurrent()) return const [];
        return _ref.read(apiListProvider).value ?? const [];
      },
      readActiveApiConfig: () => _ref.read(activeApiConfigProvider),
    );

    try {
      return await _ref
          .read(memoryConsolidationBatchProvider)
          .runOnce(
            ownerId: ownerId,
            leaseDurationSeconds: _leaseDurationSeconds,
            sessionId: sessionId,
            settings: apiSettings,
            apiResolver: resolver,
            originalStamp: originalStamp,
            originalCustomApi: customInvocation,
            isCurrent: isCurrent,
            cancelToken: token,
            onClaimed: (jobId) {
              session.claimedJobId = jobId;
              _startLeaseHeartbeat(
                session: session,
                jobId: jobId,
                ownerId: ownerId,
                token: token,
              );
            },
            beforeRequest: () => _confirmCurrentSources(
              sessionId: sessionId,
              session: session,
              epoch: epoch,
              token: token,
            ),
            beforeSave: () => _confirmCurrentSources(
              sessionId: sessionId,
              session: session,
              epoch: epoch,
              token: token,
            ),
          );
    } finally {
      session.heartbeat?.cancel();
      session.heartbeat = null;
      if (identical(session.token, token)) session.token = null;
      session.claimedJobId = null;
    }
  }

  Future<bool> _confirmCurrentSources({
    required String sessionId,
    required _SessionDrain session,
    required int epoch,
    required CancelToken token,
  }) async {
    final jobId = session.claimedJobId;
    if (jobId == null ||
        session.epoch != epoch ||
        token.isCancelled ||
        _disposed ||
        !_ref.mounted) {
      return false;
    }
    final book = await _ref
        .read(memoryBookRepoProvider)
        .getBySessionId(sessionId);
    if (book == null || !_consolidationEnabled(book.settings)) {
      await _ref.read(memoryConsolidationJobRepoProvider).cancel(jobId);
      return false;
    }
    final entries = {for (final entry in book.entries) entry.id: entry};
    final items = await _ref
        .read(memoryConsolidationJobRepoProvider)
        .getItems(jobId);
    for (final item in items) {
      final entry = entries[item.memoryEntryId];
      if (entry == null ||
          entry.status != 'active' ||
          entry.activeRevisionId != item.revisionId) {
        await _ref.read(memoryConsolidationJobRepoProvider).cancel(jobId);
        return false;
      }
      final revision = entry.revisions
          .where((candidate) => candidate.id == item.revisionId)
          .firstOrNull;
      if (revision == null ||
          MemoryEventRegistryRepo.sourceFingerprint(
                revision,
                sourceSwipeId: entry.sourceSwipeId,
                sourceAgentSwipeId: entry.sourceAgentSwipeId,
              ) !=
              item.fingerprint) {
        await _ref.read(memoryConsolidationJobRepoProvider).cancel(jobId);
        return false;
      }
    }
    return session.epoch == epoch && !token.isCancelled;
  }

  void _startLeaseHeartbeat({
    required _SessionDrain session,
    required String jobId,
    required String ownerId,
    required CancelToken token,
  }) {
    session.heartbeat?.cancel();
    session.heartbeat = Timer.periodic(_leaseHeartbeat, (_) {
      if (session.heartbeatRenewing ||
          session.claimedJobId != jobId ||
          token.isCancelled) {
        return;
      }
      session.heartbeatRenewing = true;
      unawaited(_renewLease(session, jobId, ownerId, token));
    });
  }

  Future<void> _renewLease(
    _SessionDrain session,
    String jobId,
    String ownerId,
    CancelToken token,
  ) async {
    try {
      final renewed = await _ref
          .read(memoryConsolidationJobRepoProvider)
          .renewLease(
            jobId: jobId,
            ownerId: ownerId,
            leaseDurationSeconds: _leaseDurationSeconds,
          );
      if (!renewed && session.claimedJobId == jobId && !token.isCancelled) {
        token.cancel('Memory consolidation lease was lost');
      }
    } catch (error) {
      if (session.claimedJobId == jobId && !token.isCancelled) {
        token.cancel('Memory consolidation lease renewal failed: $error');
      }
    } finally {
      session.heartbeatRenewing = false;
    }
  }

  bool _consolidationEnabled(MemoryBookSettings settings) =>
      settings.enabled &&
      MemoryRetrievalMode.fromValue(settings.memoryMode).isConsolidationMode &&
      _globalConsolidationEnabled;

  bool get _globalConsolidationEnabled {
    final global = _ref.read(memoryGlobalSettingsProvider);
    return global.enabled &&
        MemoryRetrievalMode.fromValue(global.memoryMode).isConsolidationMode;
  }

  static String _newWorkerNonce() {
    final random = Random.secure();
    return '${random.nextInt(1 << 32).toRadixString(36)}-'
        '${random.nextInt(1 << 32).toRadixString(36)}';
  }

  void dispose() {
    _disposed = true;
    for (final sessionId in _sessions.keys.toList()) {
      cancelSession(sessionId, reason: 'Memory consolidation worker disposed');
      final session = _sessions[sessionId];
      if (session != null) unawaited(session.dispose());
    }
  }
}

final class _SessionDrain {
  bool dirty = false;
  bool enqueueApprovedEntries = false;
  bool waitingForDrafts = false;
  bool running = false;
  int epoch = 0;
  CancelToken? token;
  String? claimedJobId;
  Timer? heartbeat;
  bool heartbeatRenewing = false;
  StreamSubscription<List<MemoryConsolidationJobRow>>? jobsSubscription;

  Future<void> dispose() async {
    heartbeat?.cancel();
    heartbeat = null;
    await jobsSubscription?.cancel();
    jobsSubscription = null;
  }
}

final memoryConsolidationWorkerProvider = Provider<MemoryConsolidationWorker>((
  ref,
) {
  final worker = MemoryConsolidationWorker(ref);
  ref.listen<Set<String>>(
    memoryActiveDraftsProvider,
    (_, next) => worker.activeDraftsChanged(next),
  );
  ref.listen<PipelineSettings>(pipelineSettingsProvider, (previous, next) {
    if (previous?.memoryBookApi != next.memoryBookApi) {
      worker.invalidateContexts();
    }
  });
  ref.listen<MemoryGlobalSettings>(memoryGlobalSettingsProvider, (
    previous,
    next,
  ) {
    if (previous?.memoryMode != next.memoryMode ||
        previous?.enabled != next.enabled) {
      worker.invalidateContexts();
    }
  });
  ref.onDispose(worker.dispose);
  return worker;
});
