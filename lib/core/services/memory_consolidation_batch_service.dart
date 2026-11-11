import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';

import '../db/app_db.dart';
import '../db/repositories/memory_consolidation_job_repo.dart';
import '../db/repositories/memory_consolidation_pack_builder.dart';
import '../db/repositories/memory_event_registry_repo.dart';
import '../db/repositories/tracker_repo.dart';
import '../llm/game_time.dart';
import '../llm/memory_book_api_config_resolver.dart';
import '../llm/memory_consolidation_batch_planner.dart';
import '../llm/memory_consolidation_package_parser.dart';
import '../llm/memory_draft_api_source.dart';
import '../models/memory_book.dart';
import '../models/memory_book_api_settings.dart';
import '../models/memory_consolidation.dart';
import '../credentials/memory_custom_api_credential_owner.dart';
import '../credentials/native_provider_credentials.dart';
import 'memory_consolidation_acceptance_service.dart';
import 'memory_consolidation_service.dart';

/// One reviewable package draft: the frozen pack the model actually saw plus
/// its strict parsed response. The registry transaction re-verifies every
/// live source at acceptance time, so this pair is display and parse context
/// only — never authority.
final class MemoryConsolidationPackageReview {
  const MemoryConsolidationPackageReview({
    required this.jobId,
    required this.pack,
    required this.response,
  });

  final String jobId;
  final MemoryConsolidationSourcePack pack;
  final MemoryConsolidationPackageResponse response;
}

/// One bounded slice of the initial book scan: the entries that would be
/// consolidated together in a single package job.
final class MemoryConsolidationScanPackage {
  const MemoryConsolidationScanPackage({
    required this.entries,
    required this.estimatedChars,
    this.oversized = false,
  });

  final List<MemoryEntry> entries;
  final int estimatedChars;
  final bool oversized;
}

/// Dry-run plan for the one-time initial pass over an existing book: which
/// eligible, uncovered entries would be consolidated and how they split into
/// bounded packages. [MemoryConsolidationBatchService.planScan] writes
/// nothing; [MemoryConsolidationBatchService.enqueueScan] turns a confirmed
/// plan into durable, idempotent jobs.
final class MemoryConsolidationScanPlan {
  const MemoryConsolidationScanPlan({
    required this.packages,
    required this.eligibleCount,
    required this.coveredCount,
    required this.ineligibleCount,
    this.reservedCount = 0,
  });

  final List<MemoryConsolidationScanPackage> packages;
  final int eligibleCount;
  final int coveredCount;
  final int ineligibleCount;
  final int reservedCount;
}

/// Connects durable consolidation jobs to generation and reviewed acceptance.
///
/// One package job makes exactly one network call for all of its sources.
/// A crashed run is recovered through the job lease; a rejected or cancelled
/// package never writes registry rows; acceptance is always explicit and
/// re-verified inside the job repository's transaction.
class MemoryConsolidationBatchService {
  MemoryConsolidationBatchService({
    required this.db,
    required this.jobRepo,
    required this.packBuilder,
    required this.service,
    required this.acceptance,
    this.planner = const MemoryConsolidationBatchPlanner(),
  });

  final AppDatabase db;
  final MemoryConsolidationJobRepo jobRepo;
  final MemoryConsolidationPackBuilder packBuilder;
  final MemoryConsolidationService service;
  final MemoryConsolidationAcceptanceService acceptance;
  final MemoryConsolidationBatchPlanner planner;

  /// Snapshots active eligible entries into a durable, idempotent package
  /// job. A cancelled package with the same snapshot is revived: enqueueing
  /// the same sources again means the caller wants them drafted, not that the
  /// old rejection should stand forever. Re-enqueuing live sources returns the
  /// existing job; the repository rejects a request key bound to a different
  /// snapshot.
  Future<MemoryConsolidationJobRow> enqueue({
    required String sessionId,
    required String branchId,
    required List<MemoryEntry> entries,
  }) async {
    if (entries.isEmpty) {
      throw ArgumentError('A consolidation package needs at least one source.');
    }
    final items = _sourceItems(sessionId, branchId, entries);
    final job = await jobRepo.createOrGet(
      sessionId: sessionId,
      branchId: branchId,
      requestKey: _requestKey(sessionId, branchId, items),
      items: items,
    );
    if (job.status == 'cancelled') {
      return jobRepo.revive(job.id);
    }
    return job;
  }

  List<MemoryConsolidationJobItemInput> _sourceItems(
    String sessionId,
    String branchId,
    List<MemoryEntry> entries,
  ) {
    final items = <MemoryConsolidationJobItemInput>[];
    for (final entry in entries) {
      final revision = _activeRevision(entry);
      final fingerprint = MemoryEventRegistryRepo.sourceFingerprint(
        revision,
        sourceSwipeId: entry.sourceSwipeId,
        sourceAgentSwipeId: entry.sourceAgentSwipeId,
      );
      final proposedEventId = _proposedEventId(
        sessionId,
        branchId,
        entry.id,
        revision.id,
        fingerprint,
      );
      items.add(
        MemoryConsolidationJobItemInput(
          memoryEntryId: entry.id,
          revisionId: revision.id,
          fingerprint: fingerprint,
          proposedEventId: proposedEventId,
        ),
      );
    }
    return items;
  }

  /// Enqueues one package for the eligible entries that are not already
  /// covered by an accepted event or reserved by a durable job, gated by
  /// [minCount] (the consolidation threshold; 1 for manual runs). Returns null
  /// when there is nothing new to consolidate.
  Future<MemoryConsolidationJobRow?> enqueuePending({
    required String sessionId,
    required String branchId,
    required List<MemoryEntry> entries,
    int minCount = 1,
    MemoryConsolidationRequestBudget? budget,
    int maxEntriesPerPackage = 10,
  }) async {
    if (minCount < 1) {
      throw ArgumentError.value(minCount, 'minCount', 'must be at least 1');
    }
    final pending = entries
        .where(
          (entry) =>
              entry.status == 'active' && isEligibleSource(entry, sessionId),
        )
        .toList();
    final packages = planner.plan(
      entries: pending,
      budget: budget ?? _fallbackBudget,
      maxEntriesPerPackage: maxEntriesPerPackage,
    );
    final rows = await jobRepo.createUnreservedPackages(
      sessionId: sessionId,
      branchId: branchId,
      packages: [
        for (final package in packages)
          _sourceItems(sessionId, branchId, package.entries),
      ],
      minCount: minCount,
      reviveCancelled: false,
      requestKeyForItems: (items) => _requestKey(sessionId, branchId, items),
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Memory-entry IDs that already participate in a current, non-invalidated
  /// accepted event. Such entries are consolidated; re-drafting them would
  /// only duplicate the registry.
  Future<Set<String>> coveredEntryIds({
    required String sessionId,
    required String branchId,
  }) => MemoryEventRegistryRepo(
    db,
  ).getCoveredEntryIds(sessionId: sessionId, branchId: branchId);

  /// Whether the entry's active revision carries a complete, non-invalidated
  /// provenance manifest rooted in [sessionId] — the same bar the single-entry
  /// manual review applies before it lets a source into a pack.
  static bool isEligibleSource(MemoryEntry entry, String sessionId) {
    final revisionId = entry.activeRevisionId;
    if (revisionId == null) return false;
    MemoryEntryRevision? activeRevision;
    for (final revision in entry.revisions) {
      if (revision.id == revisionId) {
        activeRevision = revision;
        break;
      }
    }
    if (activeRevision == null) return false;
    final manifest = activeRevision.sourceManifest;
    return manifest != null &&
        !manifest.invalidated &&
        manifest.version == 1 &&
        manifest.originSessionId == sessionId &&
        activeRevision.messageIds.isNotEmpty &&
        manifest.messages.length == activeRevision.messageIds.length &&
        activeRevision.messageIds.asMap().entries.every(
          (item) => manifest.messages[item.key].messageId == item.value,
        ) &&
        entry.messageIds.length == activeRevision.messageIds.length &&
        entry.messageIds.asMap().entries.every(
          (item) => activeRevision!.messageIds[item.key] == item.value,
        );
  }

  /// Computes the deterministic, bounded plan for the initial pass over an
  /// existing book. This is the saved-before-launch dry run: nothing is
  /// enqueued or generated until the caller confirms the estimate through
  /// [enqueueScan]. Slicing is stable (oldest entries first), so re-planning
  /// an unchanged book reproduces the same packages — and therefore the same
  /// idempotent request keys. A single entry larger than [maxPackageChars]
  /// still becomes its own package instead of being silently dropped; it will
  /// fail honestly at pack-build time if it truly cannot fit.
  Future<MemoryConsolidationScanPlan> planScan({
    required String sessionId,
    required String branchId,
    required List<MemoryEntry> entries,
    int maxEntriesPerPackage = 10,
    int? maxPackageChars,
    MemoryConsolidationRequestBudget? budget,
  }) async {
    if (maxEntriesPerPackage < 1) {
      throw ArgumentError.value(
        maxEntriesPerPackage,
        'maxEntriesPerPackage',
        'must be at least 1',
      );
    }
    if (maxPackageChars != null && maxPackageChars < 1000) {
      throw ArgumentError.value(
        maxPackageChars,
        'maxPackageChars',
        'must be at least 1000',
      );
    }
    final covered = await coveredEntryIds(
      sessionId: sessionId,
      branchId: branchId,
    );
    final reserved = await jobRepo.getReservedSources(
      sessionId: sessionId,
      branchId: branchId,
    );
    var coveredCount = 0;
    var ineligibleCount = 0;
    var reservedCount = 0;
    final eligible = <MemoryEntry>[];
    for (final entry in entries) {
      if (covered.contains(entry.id)) {
        coveredCount++;
        continue;
      }
      if (entry.status == 'active' && isEligibleSource(entry, sessionId)) {
        final identity = _sourceItems(sessionId, branchId, [
          entry,
        ]).single.sourceIdentity;
        if (reserved.contains(identity)) {
          reservedCount++;
        } else {
          eligible.add(entry);
        }
      } else {
        ineligibleCount++;
      }
    }
    final effectiveBudget =
        budget ??
        (maxPackageChars == null
            ? _fallbackBudget
            : MemoryConsolidationRequestBudget(
                contextTokens:
                    (maxPackageChars ~/ 4) +
                    kMemoryConsolidationFramingReserveTokens +
                    1,
                outputReserveTokens: 1,
              ));
    final planned = planner.plan(
      entries: eligible,
      budget: effectiveBudget,
      maxEntriesPerPackage: maxEntriesPerPackage,
    );
    final packages = [
      for (final package in planned)
        MemoryConsolidationScanPackage(
          entries: package.entries,
          estimatedChars: package.estimatedTokens * 4,
          oversized: package.oversized,
        ),
    ];
    return MemoryConsolidationScanPlan(
      packages: List.unmodifiable(packages),
      eligibleCount: eligible.length,
      coveredCount: coveredCount,
      ineligibleCount: ineligibleCount,
      reservedCount: reservedCount,
    );
  }

  /// Conservative serialized-size estimate of one entry inside a source pack:
  /// the pack ships the full revision text plus the provenance manifest, so
  /// roughly double the plain title and content, plus fixed metadata.
  static int estimatedEntryChars(MemoryEntry entry) =>
      MemoryConsolidationBatchPlanner.estimatedEntryTokens(entry) * 4;

  /// Turns a confirmed scan plan into durable package jobs, oldest package
  /// first. Only still-unreserved sources are enqueued: confirmation may race
  /// with threshold enqueue or reviewed acceptance. Existing jobs stay intact;
  /// a cancelled package with the same snapshot can be revived for redrafting.
  Future<List<MemoryConsolidationJobRow>> enqueueScan({
    required String sessionId,
    required String branchId,
    required MemoryConsolidationScanPlan plan,
  }) => jobRepo.createUnreservedPackages(
    sessionId: sessionId,
    branchId: branchId,
    packages: [
      for (final package in plan.packages)
        _sourceItems(sessionId, branchId, package.entries),
    ],
    requestKeyForItems: (items) => _requestKey(sessionId, branchId, items),
  );

  /// Claims the oldest pending package and runs its whole generation: claims
  /// every source item, builds one bounded pack, makes exactly one network
  /// call, and persists the reviewed envelope. Returns true when a package
  /// reached review; false when no pending job was claimable. [sessionId]
  /// restricts the claim to that session's queue — a UI run must execute the
  /// package the user is looking at.
  Future<bool> runOnce({
    required String ownerId,
    required int leaseDurationSeconds,
    required MemoryBookApiSettings settings,
    required MemoryDraftApiSourceResolver apiResolver,
    required NativeConnectionStamp? originalStamp,
    MemoryCustomApiInvocation? originalCustomApi,
    required bool Function() isCurrent,
    CancelToken? cancelToken,
    String? sessionId,
    void Function(String jobId)? onClaimed,
    Future<bool> Function()? beforeRequest,
    Future<bool> Function()? beforeSave,
  }) async {
    await jobRepo.recoverExpiredLeases();
    final job = await jobRepo.claimNext(
      ownerId: ownerId,
      leaseDurationSeconds: leaseDurationSeconds,
      sessionId: sessionId,
    );
    if (job == null) return false;
    onClaimed?.call(job.id);
    final items = await jobRepo.getItems(job.id);
    try {
      for (final _ in items) {
        final claimed = await jobRepo.claimNextItem(
          jobId: job.id,
          ownerId: ownerId,
        );
        if (claimed == null) {
          throw StateError(
            'Package sources could not be claimed for drafting.',
          );
        }
      }
      if (!isCurrent() || (beforeRequest != null && !await beforeRequest())) {
        throw StateError(
          'Package sources changed before the model request started.',
        );
      }
      final resolved = await apiResolver.resolve(
        settings: settings,
        originalStamp: originalStamp,
        originalCustomApi: originalCustomApi,
        isCurrent: () => isCurrent() && cancelToken?.isCancelled != true,
      );
      final requestBudget = MemoryConsolidationRequestBudget.forApi(
        settings: settings,
        config: resolved.configuration,
      );
      final memoryEntryIds = [for (final item in items) item.memoryEntryId];
      final proposedEventIds = [for (final item in items) item.proposedEventId];
      final pack = await packBuilder.build(
        sessionId: job.sessionId,
        branchId: job.branchId,
        proposedEventId: proposedEventIds.first,
        proposedEventIds: proposedEventIds,
        memoryEntryIds: memoryEntryIds,
        maxContextTokens: requestBudget.packTokenLimit,
      );
      if (pack == null) {
        throw StateError('Package sources are not eligible for a source pack.');
      }
      final frozen = await jobRepo.saveFrozenPackage(
        jobId: job.id,
        ownerId: ownerId,
        packJson: pack.toJsonString(),
      );
      if (!frozen) {
        throw StateError('Lease was lost while freezing the source pack.');
      }
      final gameTime = GameTimeState.fromTrackers(
        await TrackerRepo(db).getBySessionId(job.sessionId),
      );
      if (!isCurrent() || (beforeRequest != null && !await beforeRequest())) {
        throw StateError(
          'Package sources changed before the model request started.',
        );
      }
      final response = await service.generatePackageDraft(
        pack: pack,
        gameTime: gameTime,
        config: resolved.config,
        maxTokens: MemoryBookApiConfigResolver.maxTokensFor(
          settings,
          resolved.configuration,
        ),
        temperature: MemoryBookApiConfigResolver.temperatureFor(settings),
        timeoutMs: resolved.receiveTimeoutMs ?? 0,
        isCurrent: isCurrent,
        cancelToken: cancelToken,
      );
      if (!isCurrent() || (beforeSave != null && !await beforeSave())) {
        throw StateError(
          'Package context changed before the review draft was saved.',
        );
      }
      final saved = await jobRepo.savePackageDraft(
        jobId: job.id,
        ownerId: ownerId,
        draftJson: _encodeEnvelope(pack, response),
      );
      if (!saved) {
        throw StateError('Lease was lost while saving the package draft.');
      }
      return true;
    } on MemoryConsolidationPackTooLargeException {
      await jobRepo.failRunningPackage(
        jobId: job.id,
        ownerId: ownerId,
        reason: 'source_pack_exceeds_context_budget',
      );
      rethrow;
    } catch (error) {
      // The package lease still belongs to this run, so every remaining
      // running item is marked failed and the job becomes retryable.
      for (final item in await jobRepo.getItems(job.id)) {
        if (item.status == 'running') {
          await jobRepo.failItem(
            jobId: job.id,
            itemId: item.id,
            ownerId: ownerId,
            reason: 'package_generation_failed',
          );
        }
      }
      rethrow;
    }
  }

  static const _fallbackBudget = MemoryConsolidationRequestBudget(
    contextTokens: kMemoryConsolidationCustomContextFallback,
    outputReserveTokens: kMemoryDraftFallbackMaxTokens,
  );

  /// Loads the stored review envelope for UI display. Returns null unless the
  /// job is in the review-pending state with a persisted draft.
  Future<MemoryConsolidationPackageReview?> loadReview(String jobId) async {
    final job =
        await (db.select(db.memoryConsolidationJobRows)..where(
              (row) =>
                  row.id.equals(jobId) &
                  row.status.equals('review_pending') &
                  row.packageDraftJson.isNotNull(),
            ))
            .getSingleOrNull();
    if (job == null) return null;
    final review = _decodeEnvelope(job.id, job.packageDraftJson!);
    return MemoryConsolidationPackageReview(
      jobId: job.id,
      pack: review.pack,
      response: review.response,
    );
  }

  /// Loads the newest review-pending package of a session, so a UI run can
  /// open the package it just drafted even when the queue held an older one.
  Future<MemoryConsolidationPackageReview?> loadSessionReview(
    String sessionId,
  ) async {
    final job =
        await (db.select(db.memoryConsolidationJobRows)
              ..where(
                (row) =>
                    row.sessionId.equals(sessionId) &
                    row.status.equals('review_pending') &
                    row.packageDraftJson.isNotNull(),
              )
              ..orderBy([(row) => OrderingTerm.desc(row.createdAt)])
              ..limit(1))
            .getSingleOrNull();
    if (job == null) return null;
    final review = _decodeEnvelope(job.id, job.packageDraftJson!);
    return MemoryConsolidationPackageReview(
      jobId: job.id,
      pack: review.pack,
      response: review.response,
    );
  }

  /// Accepts the reviewed package graph atomically: the acceptance callback
  /// runs inside the job repository transaction on this same database and
  /// performs no network work.
  Future<bool> acceptReviewed({
    required String jobId,
    required bool Function() isCurrent,
    String acceptedBy = 'user',
  }) => jobRepo.acceptReviewedPackage(
    jobId: jobId,
    acceptReviewed: (draftJson) async {
      final review = _decodeEnvelope(jobId, draftJson);
      final accepted = await acceptance.acceptReviewedPackage(
        response: review.response,
        pack: review.pack,
        isCurrent: isCurrent,
        acceptedBy: acceptedBy,
      );
      if (!accepted) {
        throw StateError(
          'Consolidation package could not be verified for acceptance.',
        );
      }
    },
  );

  /// Rejects a reviewed package: the draft stays diagnosable in the row until
  /// cancellation clears it from the active flow, and nothing is written to
  /// the registry.
  /// A rejected review is also a user decision, but distinct from a plain
  /// cancel so the queue can tell "отклонено при проверке" from "отменено".
  Future<bool> reject(String jobId) =>
      jobRepo.cancel(jobId, reason: 'rejected_by_user');

  MemoryEntryRevision _activeRevision(MemoryEntry entry) {
    final revisionId = entry.activeRevisionId;
    if (revisionId == null || entry.status != 'active') {
      throw ArgumentError(
        'Only active entries with a current revision can be consolidated.',
      );
    }
    for (final revision in entry.revisions) {
      if (revision.id == revisionId) return revision;
    }
    throw ArgumentError('Entry revision disappeared while enqueuing.');
  }

  static String _proposedEventId(
    String sessionId,
    String branchId,
    String entryId,
    String revisionId,
    String fingerprint,
  ) {
    final digest = sha256
        .convert(utf8.encode('$sessionId|$branchId|$entryId|$revisionId'))
        .toString();
    return 'event-${digest.substring(0, 24)}';
  }

  static String _requestKey(
    String sessionId,
    String branchId,
    List<MemoryConsolidationJobItemInput> items,
  ) {
    final snapshot = [
      for (final item in items)
        '${item.memoryEntryId}|${item.revisionId}|'
            '${item.fingerprint}|${item.proposedEventId}',
    ]..sort();
    final digest = sha256
        .convert(utf8.encode('$sessionId|$branchId|${snapshot.join(';')}'))
        .toString();
    return 'pkg-$digest';
  }

  static String _encodeEnvelope(
    MemoryConsolidationSourcePack pack,
    MemoryConsolidationPackageResponse response,
  ) => jsonEncode({'pack': pack.toJson(), 'response': response.toStrictJson()});

  static MemoryConsolidationPackageReview _decodeEnvelope(
    String jobId,
    String draftJson,
  ) {
    final Map<String, dynamic> envelope;
    try {
      envelope = jsonDecode(draftJson) as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('Stored package draft is not valid JSON.');
    }
    final packJson = envelope['pack'];
    final responseJson = envelope['response'];
    if (packJson is! Map<String, dynamic> || responseJson is! Map) {
      throw const FormatException(
        'Stored package draft envelope is malformed.',
      );
    }
    final pack = MemoryConsolidationSourcePack.fromJson(packJson);
    final response = MemoryConsolidationPackageParser.parse(
      jsonEncode(responseJson),
      pack,
    );
    return MemoryConsolidationPackageReview(
      jobId: jobId,
      pack: pack,
      response: response,
    );
  }
}
