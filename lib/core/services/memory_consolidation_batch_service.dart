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
  /// job. Re-enqueuing the same sources returns the existing job; the
  /// repository rejects a request key bound to a different snapshot.
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
    return jobRepo.createOrGet(
      sessionId: sessionId,
      branchId: branchId,
      requestKey: _requestKey(sessionId, branchId, items),
      items: items,
    );
  }

  /// Claims the oldest pending package and runs its whole generation: claims
  /// every source item, builds one bounded pack, makes exactly one network
  /// call, and persists the reviewed envelope. Returns true when a package
  /// reached review; false when no pending job was claimable.
  Future<bool> runOnce({
    required String ownerId,
    required int leaseDurationSeconds,
    required MemoryBookApiSettings settings,
    required MemoryDraftApiSourceResolver apiResolver,
    required NativeConnectionStamp? originalStamp,
    MemoryCustomApiInvocation? originalCustomApi,
    required bool Function() isCurrent,
    CancelToken? cancelToken,
  }) async {
    await jobRepo.recoverExpiredLeases();
    final job = await jobRepo.claimNext(
      ownerId: ownerId,
      leaseDurationSeconds: leaseDurationSeconds,
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
