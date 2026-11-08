import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';

import '../db/app_db.dart';
import '../db/repositories/memory_consolidation_job_repo.dart';
import '../db/repositories/memory_consolidation_pack_builder.dart';
import '../db/repositories/memory_event_registry_repo.dart';
import '../llm/memory_book_api_config_resolver.dart';
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
  });

  final List<MemoryEntry> entries;
  final int estimatedChars;
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
  });

  final List<MemoryConsolidationScanPackage> packages;
  final int eligibleCount;
  final int coveredCount;
  final int ineligibleCount;
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
  });

  final AppDatabase db;
  final MemoryConsolidationJobRepo jobRepo;
  final MemoryConsolidationPackBuilder packBuilder;
  final MemoryConsolidationService service;
  final MemoryConsolidationAcceptanceService acceptance;

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

  /// Enqueues one package for the eligible entries that are not already
  /// covered by a current accepted event, gated by [minCount] (the
  /// consolidation threshold; 1 for manual runs). Returns null when there is
  /// nothing new to consolidate.
  Future<MemoryConsolidationJobRow?> enqueuePending({
    required String sessionId,
    required String branchId,
    required List<MemoryEntry> entries,
    int minCount = 1,
  }) async {
    if (minCount < 1) {
      throw ArgumentError.value(minCount, 'minCount', 'must be at least 1');
    }
    final covered = await coveredEntryIds(
      sessionId: sessionId,
      branchId: branchId,
    );
    final pending = entries
        .where(
          (entry) =>
              entry.status == 'active' &&
              isEligibleSource(entry, sessionId) &&
              !covered.contains(entry.id),
        )
        .toList();
    if (pending.length < minCount) return null;
    return enqueue(sessionId: sessionId, branchId: branchId, entries: pending);
  }

  /// Memory-entry IDs that already participate in a current, non-invalidated
  /// accepted event. Such entries are consolidated; re-drafting them would
  /// only duplicate the registry.
  Future<Set<String>> coveredEntryIds({
    required String sessionId,
    required String branchId,
  }) async {
    final registry = MemoryEventRegistryRepo(db);
    final events = await registry.getActiveEvents(
      sessionId: sessionId,
      branchId: branchId,
    );
    if (events.isEmpty) return const <String>{};
    final rows =
        await (db.select(db.memoryEventSourceRows)..where(
              (row) =>
                  row.sessionId.equals(sessionId) &
                  row.branchId.equals(branchId) &
                  row.eventId.isIn(events.map((event) => event.id)),
            ))
            .get();
    return rows.map((row) => row.memoryEntryId).toSet();
  }

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
    int maxPackageChars = 90000,
  }) async {
    if (maxEntriesPerPackage < 1) {
      throw ArgumentError.value(
        maxEntriesPerPackage,
        'maxEntriesPerPackage',
        'must be at least 1',
      );
    }
    if (maxPackageChars < 1000) {
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
    var coveredCount = 0;
    var ineligibleCount = 0;
    final eligible = <MemoryEntry>[];
    for (final entry in entries) {
      if (covered.contains(entry.id)) {
        coveredCount++;
        continue;
      }
      if (entry.status == 'active' && isEligibleSource(entry, sessionId)) {
        eligible.add(entry);
      } else {
        ineligibleCount++;
      }
    }
    eligible.sort((a, b) {
      final byCreated = (a.createdAt ?? 0).compareTo(b.createdAt ?? 0);
      return byCreated != 0 ? byCreated : a.id.compareTo(b.id);
    });
    final packages = <MemoryConsolidationScanPackage>[];
    var current = <MemoryEntry>[];
    var chars = 0;
    for (final entry in eligible) {
      final estimate = estimatedEntryChars(entry);
      if (current.isNotEmpty &&
          (current.length >= maxEntriesPerPackage ||
              chars + estimate > maxPackageChars)) {
        packages.add(
          MemoryConsolidationScanPackage(
            entries: current,
            estimatedChars: chars,
          ),
        );
        current = <MemoryEntry>[];
        chars = 0;
      }
      current.add(entry);
      chars += estimate;
    }
    if (current.isNotEmpty) {
      packages.add(
        MemoryConsolidationScanPackage(entries: current, estimatedChars: chars),
      );
    }
    return MemoryConsolidationScanPlan(
      packages: List.unmodifiable(packages),
      eligibleCount: eligible.length,
      coveredCount: coveredCount,
      ineligibleCount: ineligibleCount,
    );
  }

  /// Conservative serialized-size estimate of one entry inside a source pack:
  /// the pack ships the full revision text plus the provenance manifest, so
  /// roughly double the plain title and content, plus fixed metadata.
  static int estimatedEntryChars(MemoryEntry entry) =>
      (entry.title.length + entry.content.length) * 2 + 400;

  /// Turns a confirmed scan plan into durable package jobs, oldest package
  /// first. Idempotent per package: re-enqueueing an unchanged plan returns
  /// the existing jobs, and a rejected package with the same snapshot is
  /// revived for redrafting instead of duplicating.
  Future<List<MemoryConsolidationJobRow>> enqueueScan({
    required String sessionId,
    required String branchId,
    required MemoryConsolidationScanPlan plan,
  }) async {
    final rows = <MemoryConsolidationJobRow>[];
    for (final package in plan.packages) {
      rows.add(
        await enqueue(
          sessionId: sessionId,
          branchId: branchId,
          entries: package.entries,
        ),
      );
    }
    return rows;
  }

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
  }) async {
    await jobRepo.recoverExpiredLeases();
    final job = await jobRepo.claimNext(
      ownerId: ownerId,
      leaseDurationSeconds: leaseDurationSeconds,
      sessionId: sessionId,
    );
    if (job == null) return false;
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
      final memoryEntryIds = [for (final item in items) item.memoryEntryId];
      final proposedEventIds = [for (final item in items) item.proposedEventId];
      final pack = await packBuilder.build(
        sessionId: job.sessionId,
        branchId: job.branchId,
        proposedEventId: proposedEventIds.first,
        proposedEventIds: proposedEventIds,
        memoryEntryIds: memoryEntryIds,
      );
      if (pack == null) {
        throw StateError('Package sources are not eligible for a source pack.');
      }
      final resolved = await apiResolver.resolve(
        settings: settings,
        originalStamp: originalStamp,
        originalCustomApi: originalCustomApi,
        isCurrent: () => isCurrent() && cancelToken?.isCancelled != true,
      );
      final response = await service.generatePackageDraft(
        pack: pack,
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
      final saved = await jobRepo.savePackageDraft(
        jobId: job.id,
        ownerId: ownerId,
        draftJson: _encodeEnvelope(pack, response),
      );
      if (!saved) {
        throw StateError('Lease was lost while saving the package draft.');
      }
      return true;
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
  Future<bool> reject(String jobId) => jobRepo.cancel(jobId);

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
