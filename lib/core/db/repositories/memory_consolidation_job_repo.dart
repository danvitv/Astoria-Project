import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';

import '../../models/chat_message.dart';
import '../../models/memory_book.dart';
import '../../models/memory_entry_revisions.dart';
import '../../models/memory_source_manifest.dart';
import '../../utils/id_generator.dart';
import '../../utils/time_helpers.dart';
import '../app_db.dart';
import 'memory_event_registry_repo.dart';
import 'chat_message_storage_repo.dart';

typedef MemoryConsolidationSourceIdentity = ({
  String memoryEntryId,
  String revisionId,
  String fingerprint,
});

class MemoryConsolidationJobItemInput {
  const MemoryConsolidationJobItemInput({
    required this.memoryEntryId,
    required this.revisionId,
    required this.fingerprint,
    required this.proposedEventId,
  });

  final String memoryEntryId;
  final String revisionId;
  final String fingerprint;
  final String proposedEventId;

  MemoryConsolidationSourceIdentity get sourceIdentity => (
    memoryEntryId: memoryEntryId,
    revisionId: revisionId,
    fingerprint: fingerprint,
  );
}

class MemoryConsolidationJobRepo {
  const MemoryConsolidationJobRepo(this.db, {this._clock});

  final AppDatabase db;
  final int Function()? _clock;
  int get _now => _clock?.call() ?? currentTimestampSeconds();

  /// Failed packages retain their sources for failed-only retry. Cancelled
  /// packages release them; another revision or branch is a different source.
  Future<Set<MemoryConsolidationSourceIdentity>> getReservedSources({
    required String sessionId,
    required String branchId,
    bool includeCancelled = false,
  }) async {
    final jobs = db.memoryConsolidationJobRows;
    final items = db.memoryConsolidationJobItemRows;
    final query = db.selectOnly(items)
      ..addColumns([items.memoryEntryId, items.revisionId, items.fingerprint])
      ..join([innerJoin(jobs, jobs.id.equalsExp(items.jobId))])
      ..where(
        jobs.sessionId.equals(sessionId) &
            jobs.branchId.equals(branchId) &
            jobs.status.isIn([
              'pending',
              'running',
              'review_pending',
              'failed',
              if (includeCancelled) 'cancelled',
            ]),
      );
    return {
      for (final row in await query.get())
        (
          memoryEntryId: row.read(items.memoryEntryId)!,
          revisionId: row.read(items.revisionId)!,
          fingerprint: row.read(items.fingerprint)!,
        ),
    };
  }

  /// Rechecks accepted coverage and queue reservations in the same transaction
  /// that creates the jobs. A stale dry run or a simultaneous threshold enqueue
  /// can only claim the still-unreserved snapshots, never duplicate a package.
  /// [requestKeyForItems] must be a pure identity calculation (no I/O).
  Future<List<MemoryConsolidationJobRow>> createUnreservedPackages({
    required String sessionId,
    required String branchId,
    required List<List<MemoryConsolidationJobItemInput>> packages,
    required String Function(List<MemoryConsolidationJobItemInput>)
    requestKeyForItems,
    int minCount = 1,
    bool reviveCancelled = true,
  }) {
    if (minCount < 1) {
      throw ArgumentError.value(minCount, 'minCount', 'must be at least 1');
    }
    return db.transaction(() async {
      final covered = await MemoryEventRegistryRepo(
        db,
      ).getCoveredEntryIds(sessionId: sessionId, branchId: branchId);
      final reserved = await getReservedSources(
        sessionId: sessionId,
        branchId: branchId,
        includeCancelled: !reviveCancelled,
      );
      final rows = <MemoryConsolidationJobRow>[];
      final availableByPackage = <List<MemoryConsolidationJobItemInput>>[];
      for (final package in packages) {
        final available = package
            .where(
              (item) =>
                  !covered.contains(item.memoryEntryId) &&
                  !reserved.contains(item.sourceIdentity),
            )
            .toList();
        availableByPackage.add(available);
      }
      if (availableByPackage.fold<int>(0, (sum, value) => sum + value.length) <
          minCount) {
        return rows;
      }
      for (final available in availableByPackage) {
        if (available.isEmpty) continue;
        final job = await createOrGet(
          sessionId: sessionId,
          branchId: branchId,
          requestKey: requestKeyForItems(available),
          items: available,
        );
        if (job.status == 'cancelled' && !reviveCancelled) continue;
        final active = job.status == 'cancelled' ? await revive(job.id) : job;
        rows.add(active);
        reserved.addAll(available.map((item) => item.sourceIdentity));
      }
      return rows;
    });
  }

  Future<MemoryConsolidationJobRow> createOrGet({
    required String sessionId,
    required String branchId,
    required String requestKey,
    required List<MemoryConsolidationJobItemInput> items,
  }) {
    if (sessionId.trim().isEmpty ||
        branchId.trim().isEmpty ||
        requestKey.trim().isEmpty ||
        items.isEmpty) {
      throw ArgumentError('A durable package needs identity and source items.');
    }
    final itemIds = items.map((item) => item.memoryEntryId).toSet();
    final eventIds = items.map((item) => item.proposedEventId).toSet();
    if (itemIds.length != items.length ||
        eventIds.length != items.length ||
        items.length > 100 ||
        items.any(
          (item) =>
              item.memoryEntryId.trim().isEmpty ||
              item.revisionId.trim().isEmpty ||
              !RegExp(r'^[a-f0-9]{64}$').hasMatch(item.fingerprint) ||
              item.proposedEventId.trim().isEmpty,
        )) {
      throw ArgumentError(
        'Package sources and proposed events must be unique and identified.',
      );
    }
    return db.transaction(() async {
      final jobs = db.memoryConsolidationJobRows;
      final existing = await (db.select(
        jobs,
      )..where((row) => row.requestKey.equals(requestKey))).getSingleOrNull();
      if (existing != null) {
        await _verifyExistingRequest(existing, sessionId, branchId, items);
        return existing;
      }

      final now = _now;
      final id = 'memory-consolidation-job-${generateId()}';
      await db
          .into(jobs)
          .insert(
            MemoryConsolidationJobRowsCompanion.insert(
              id: id,
              sessionId: sessionId,
              branchId: branchId,
              requestKey: requestKey,
              createdAt: now,
              updatedAt: now,
            ),
            onConflict: DoNothing(target: [jobs.requestKey]),
          );
      final job = await (db.select(
        jobs,
      )..where((row) => row.requestKey.equals(requestKey))).getSingle();
      if (job.id != id) {
        await _verifyExistingRequest(job, sessionId, branchId, items);
        return job;
      }

      for (final item in items) {
        await db
            .into(db.memoryConsolidationJobItemRows)
            .insert(
              MemoryConsolidationJobItemRowsCompanion.insert(
                id: 'memory-consolidation-item-${generateId()}',
                jobId: id,
                memoryEntryId: item.memoryEntryId,
                revisionId: item.revisionId,
                fingerprint: item.fingerprint,
                proposedEventId: item.proposedEventId,
                createdAt: now,
                updatedAt: now,
              ),
            );
      }
      return job;
    });
  }

  /// Claims the earliest pending (or lease-expired running) job, optionally
  /// restricted to one session. UI-driven runs pass [sessionId] so a tap never
  /// executes another session's package.
  Future<MemoryConsolidationJobRow?> claimNext({
    required String ownerId,
    required int leaseDurationSeconds,
    String? sessionId,
  }) {
    if (ownerId.trim().isEmpty || leaseDurationSeconds <= 0) {
      throw ArgumentError('Lease owner and positive duration are required.');
    }
    return db.transaction(() async {
      final now = _now;
      final table = db.memoryConsolidationJobRows;
      final sessionScope = sessionId == null
          ? null
          : table.sessionId.equals(sessionId);
      final candidates =
          await (db.select(table)
                ..where((row) {
                  final claimable =
                      row.status.equals('pending') |
                      (row.status.equals('running') &
                          row.leaseExpiresAt.isSmallerOrEqualValue(now));
                  return sessionScope == null
                      ? claimable
                      : claimable & sessionScope;
                })
                ..orderBy([(row) => OrderingTerm.asc(row.createdAt)]))
              .get();
      MemoryConsolidationJobRow? candidate;
      for (final queued in candidates) {
        final activeSessionJob =
            await (db.select(table)
                  ..where(
                    (row) =>
                        row.sessionId.equals(queued.sessionId) &
                        row.status.equals('running') &
                        row.leaseExpiresAt.isBiggerThanValue(now),
                  )
                  ..limit(1))
                .getSingleOrNull();
        if (activeSessionJob == null) {
          candidate = queued;
          break;
        }
      }
      final selected = candidate;
      if (selected == null) return null;
      final changed =
          await (db.update(table)..where(
                (row) =>
                    row.id.equals(selected.id) &
                    row.version.equals(selected.version) &
                    (row.status.equals('pending') |
                        (row.status.equals('running') &
                            row.leaseExpiresAt.isSmallerOrEqualValue(now))),
              ))
              .write(
                MemoryConsolidationJobRowsCompanion(
                  status: const Value('running'),
                  leaseOwnerId: Value(ownerId),
                  leaseExpiresAt: Value(now + leaseDurationSeconds),
                  attemptCount: Value(selected.attemptCount + 1),
                  version: Value(selected.version + 1),
                  lastError: const Value(null),
                  updatedAt: Value(now),
                ),
              );
      if (changed != 1) return null;
      await (db.update(db.memoryConsolidationJobItemRows)..where(
            (row) =>
                row.jobId.equals(selected.id) & row.status.equals('running'),
          ))
          .write(
            MemoryConsolidationJobItemRowsCompanion(
              status: const Value('pending'),
              lastError: const Value('lease_expired'),
              updatedAt: Value(now),
            ),
          );
      return (db.select(
        table,
      )..where((row) => row.id.equals(selected.id))).getSingle();
    });
  }

  Future<List<MemoryConsolidationJobItemRow>> getItems(String jobId) =>
      (db.select(db.memoryConsolidationJobItemRows)
            ..where((row) => row.jobId.equals(jobId))
            ..orderBy([(row) => OrderingTerm.asc(row.createdAt)]))
          .get();

  /// Freezes the exact candidate-enriched source pack before transport using
  /// the existing local-only package payload column. A successful response
  /// replaces it with the review envelope; a failed/ambiguous call leaves the
  /// exact attempted input available for diagnosis and explicit retry.
  Future<bool> saveFrozenPackage({
    required String jobId,
    required String ownerId,
    required String packJson,
  }) async {
    if (packJson.trim().isEmpty) {
      throw ArgumentError.value(packJson, 'packJson', 'must not be empty');
    }
    final now = _now;
    final job = await _ownedLease(jobId, ownerId, now);
    if (job == null) return false;
    final changed =
        await (db.update(db.memoryConsolidationJobRows)..where(
              (row) =>
                  row.id.equals(jobId) &
                  row.version.equals(job.version) &
                  row.status.equals('running') &
                  row.leaseOwnerId.equals(ownerId),
            ))
            .write(
              MemoryConsolidationJobRowsCompanion(
                packageDraftJson: Value(packJson),
                updatedAt: Value(now),
              ),
            );
    return changed == 1;
  }

  /// Persists the single response for a source package. Item rows remain the
  /// immutable source snapshot; no per-source model calls are implied.
  Future<bool> savePackageDraft({
    required String jobId,
    required String ownerId,
    required String draftJson,
  }) => db.transaction(() async {
    final now = _now;
    final job = await _ownedLease(jobId, ownerId, now);
    if (job == null) return false;
    final items = await getItems(jobId);
    if (items.isEmpty || items.any((item) => item.status != 'running')) {
      throw StateError('Every package source must be claimed before drafting.');
    }
    final changed =
        await (db.update(db.memoryConsolidationJobRows)..where(
              (row) =>
                  row.id.equals(jobId) &
                  row.version.equals(job.version) &
                  row.status.equals('running') &
                  row.leaseOwnerId.equals(ownerId),
            ))
            .write(
              MemoryConsolidationJobRowsCompanion(
                status: const Value('review_pending'),
                packageDraftJson: Value(draftJson),
                leaseOwnerId: const Value(null),
                leaseExpiresAt: const Value(null),
                version: Value(job.version + 1),
                updatedAt: Value(now),
              ),
            );
    if (changed != 1) return false;
    final changedItems =
        await (db.update(db.memoryConsolidationJobItemRows)..where(
              (row) => row.jobId.equals(jobId) & row.status.equals('running'),
            ))
            .write(
              MemoryConsolidationJobItemRowsCompanion(
                status: const Value('review_pending'),
                updatedAt: Value(now),
              ),
            );
    if (changedItems == 0) {
      throw StateError('Pre-network package failure has no running sources.');
    }
    return true;
  });

  /// Accepts the one reviewed package graph change and completes the job in
  /// the same transaction. The callback must use this database instance and
  /// perform no network work.
  Future<bool> acceptReviewedPackage({
    required String jobId,
    required Future<void> Function(String draftJson) acceptReviewed,
  }) => db.transaction(() async {
    final job =
        await (db.select(db.memoryConsolidationJobRows)..where(
              (row) =>
                  row.id.equals(jobId) &
                  row.status.equals('review_pending') &
                  row.packageDraftJson.isNotNull(),
            ))
            .getSingleOrNull();
    if (job == null) return false;
    await acceptReviewed(job.packageDraftJson!);
    final now = _now;
    final changedItems =
        await (db.update(db.memoryConsolidationJobItemRows)..where(
              (row) =>
                  row.jobId.equals(jobId) & row.status.equals('review_pending'),
            ))
            .write(
              MemoryConsolidationJobItemRowsCompanion(
                status: const Value('accepted'),
                updatedAt: Value(now),
              ),
            );
    if (changedItems == 0) {
      throw StateError('Reviewed package has no source items to accept.');
    }
    final changed =
        await (db.update(db.memoryConsolidationJobRows)..where(
              (row) =>
                  row.id.equals(jobId) &
                  row.version.equals(job.version) &
                  row.status.equals('review_pending') &
                  row.packageDraftJson.equals(job.packageDraftJson!),
            ))
            .write(
              MemoryConsolidationJobRowsCompanion(
                status: const Value('completed'),
                version: Value(job.version + 1),
                updatedAt: Value(now),
              ),
            );
    if (changed != 1) {
      throw StateError('Reviewed package changed during acceptance.');
    }
    return true;
  });

  Future<void> _verifyExistingRequest(
    MemoryConsolidationJobRow job,
    String sessionId,
    String branchId,
    List<MemoryConsolidationJobItemInput> requestedItems,
  ) async {
    final storedItems = await getItems(job.id);
    final stored = {
      for (final item in storedItems)
        item.memoryEntryId: (
          item.revisionId,
          item.fingerprint,
          item.proposedEventId,
        ),
    };
    final requested = {
      for (final item in requestedItems)
        item.memoryEntryId: (
          item.revisionId,
          item.fingerprint,
          item.proposedEventId,
        ),
    };
    if (job.sessionId != sessionId ||
        job.branchId != branchId ||
        stored.length != requested.length ||
        stored.entries.any((entry) => requested[entry.key] != entry.value)) {
      throw StateError(
        'Request key is already bound to a different package snapshot.',
      );
    }
  }

  Future<MemoryConsolidationJobItemRow?> claimNextItem({
    required String jobId,
    required String ownerId,
  }) => db.transaction(() async {
    final now = _now;
    if (await _ownedLease(jobId, ownerId, now) == null) return null;
    final table = db.memoryConsolidationJobItemRows;
    final item =
        await (db.select(table)
              ..where(
                (row) => row.jobId.equals(jobId) & row.status.equals('pending'),
              )
              ..orderBy([(row) => OrderingTerm.asc(row.createdAt)])
              ..limit(1))
            .getSingleOrNull();
    if (item == null) return null;
    final changed =
        await (db.update(table)..where(
              (row) =>
                  row.id.equals(item.id) &
                  row.jobId.equals(jobId) &
                  row.status.equals('pending'),
            ))
            .write(
              MemoryConsolidationJobItemRowsCompanion(
                status: const Value('running'),
                attemptCount: Value(item.attemptCount + 1),
                lastError: const Value(null),
                updatedAt: Value(now),
              ),
            );
    if (changed != 1) return null;
    return (db.select(
      table,
    )..where((row) => row.id.equals(item.id))).getSingle();
  });

  Future<bool> saveDraft({
    required String jobId,
    required String itemId,
    required String ownerId,
    required String draftJson,
  }) => db.transaction(() async {
    final now = _now;
    final job = await _ownedLease(jobId, ownerId, now);
    if (job == null) return false;
    final itemTable = db.memoryConsolidationJobItemRows;
    final changed =
        await (db.update(itemTable)..where(
              (row) =>
                  row.id.equals(itemId) &
                  row.jobId.equals(jobId) &
                  row.status.equals('running'),
            ))
            .write(
              MemoryConsolidationJobItemRowsCompanion(
                status: const Value('review_pending'),
                draftJson: Value(draftJson),
                lastError: const Value(null),
                updatedAt: Value(now),
              ),
            );
    if (changed == 1) await _refreshJobStatus(job, ownerId, now);
    return changed == 1;
  });

  Future<bool> failItem({
    required String jobId,
    required String itemId,
    required String ownerId,
    required String reason,
  }) => db.transaction(() async {
    if (reason.trim().isEmpty) {
      throw ArgumentError.value(reason, 'reason', 'must not be empty');
    }
    final now = _now;
    final job = await _ownedLease(jobId, ownerId, now);
    if (job == null) return false;
    final table = db.memoryConsolidationJobItemRows;
    final changed =
        await (db.update(table)..where(
              (row) =>
                  row.id.equals(itemId) &
                  row.jobId.equals(jobId) &
                  row.status.equals('running'),
            ))
            .write(
              MemoryConsolidationJobItemRowsCompanion(
                status: const Value('failed'),
                lastError: Value(reason),
                updatedAt: Value(now),
              ),
            );
    if (changed == 1) await _refreshJobStatus(job, ownerId, now);
    return changed == 1;
  });

  /// Records a planner/pack failure before transport while retaining the
  /// immutable source reservation for an explicit failed-only retry.
  Future<bool> failRunningPackage({
    required String jobId,
    required String ownerId,
    required String reason,
  }) => db.transaction(() async {
    if (reason.trim().isEmpty) {
      throw ArgumentError.value(reason, 'reason', 'must not be empty');
    }
    final now = _now;
    final job = await _ownedLease(jobId, ownerId, now);
    if (job == null) return false;
    await (db.update(db.memoryConsolidationJobItemRows)..where(
          (row) => row.jobId.equals(jobId) & row.status.equals('running'),
        ))
        .write(
          MemoryConsolidationJobItemRowsCompanion(
            status: const Value('failed'),
            lastError: Value(reason),
            updatedAt: Value(now),
          ),
        );
    final changed =
        await (db.update(db.memoryConsolidationJobRows)..where(
              (row) =>
                  row.id.equals(jobId) &
                  row.version.equals(job.version) &
                  row.status.equals('running') &
                  row.leaseOwnerId.equals(ownerId),
            ))
            .write(
              MemoryConsolidationJobRowsCompanion(
                status: const Value('failed'),
                leaseOwnerId: const Value(null),
                leaseExpiresAt: const Value(null),
                lastError: Value(reason),
                version: Value(job.version + 1),
                updatedAt: Value(now),
              ),
            );
    return changed == 1;
  });

  /// Accepts the reviewed registry change and marks its item accepted atomically.
  /// [acceptReviewed] must use the same [db] instance and must perform no network
  /// work so its writes participate in this transaction.
  Future<bool> acceptReviewedItem({
    required String jobId,
    required String itemId,
    required Future<void> Function(String draftJson) acceptReviewed,
  }) => db.transaction(() async {
    final now = _now;
    final itemTable = db.memoryConsolidationJobItemRows;
    final item =
        await (db.select(itemTable)..where(
              (row) =>
                  row.id.equals(itemId) &
                  row.jobId.equals(jobId) &
                  row.status.equals('review_pending') &
                  row.draftJson.isNotNull(),
            ))
            .getSingleOrNull();
    if (item == null) return false;

    await acceptReviewed(item.draftJson!);
    final changed =
        await (db.update(itemTable)..where(
              (row) =>
                  row.id.equals(itemId) &
                  row.jobId.equals(jobId) &
                  row.status.equals('review_pending') &
                  row.draftJson.equals(item.draftJson!),
            ))
            .write(
              MemoryConsolidationJobItemRowsCompanion(
                status: const Value('accepted'),
                updatedAt: Value(now),
              ),
            );
    if (changed != 1) {
      throw StateError('Reviewed package item changed during acceptance.');
    }
    final remaining =
        await (db.selectOnly(itemTable)
              ..addColumns([itemTable.id.count()])
              ..where(
                itemTable.jobId.equals(jobId) &
                    itemTable.status.isNotIn(const ['accepted', 'cancelled']),
              ))
            .map((row) => row.read(itemTable.id.count()) ?? 0)
            .getSingle();
    if (remaining == 0) {
      final job = await (db.select(
        db.memoryConsolidationJobRows,
      )..where((row) => row.id.equals(jobId))).getSingleOrNull();
      if (job == null) {
        throw StateError('Reviewed package disappeared during acceptance.');
      }
      final completed =
          await (db.update(db.memoryConsolidationJobRows)..where(
                (row) =>
                    row.id.equals(jobId) &
                    row.version.equals(job.version) &
                    row.status.isIn(const ['review_pending', 'failed']),
              ))
              .write(
                MemoryConsolidationJobRowsCompanion(
                  status: const Value('completed'),
                  version: Value(job.version + 1),
                  updatedAt: Value(now),
                ),
              );
      if (completed != 1) {
        throw StateError('Package changed during final acceptance.');
      }
    } else {
      final failedCount =
          await (db.selectOnly(itemTable)
                ..addColumns([itemTable.id.count()])
                ..where(
                  itemTable.jobId.equals(jobId) &
                      itemTable.status.equals('failed'),
                ))
              .map((row) => row.read(itemTable.id.count()) ?? 0)
              .getSingle();
      if (failedCount == 0) {
        final job = await (db.select(
          db.memoryConsolidationJobRows,
        )..where((row) => row.id.equals(jobId))).getSingleOrNull();
        if (job == null) {
          throw StateError('Reviewed package disappeared during acceptance.');
        }
        await (db.update(db.memoryConsolidationJobRows)..where(
              (row) =>
                  row.id.equals(jobId) &
                  row.version.equals(job.version) &
                  row.status.equals('failed'),
            ))
            .write(
              MemoryConsolidationJobRowsCompanion(
                status: const Value('review_pending'),
                lastError: const Value(null),
                version: Value(job.version + 1),
                updatedAt: Value(now),
              ),
            );
      }
    }
    return true;
  });

  Future<bool> renewLease({
    required String jobId,
    required String ownerId,
    required int leaseDurationSeconds,
  }) async {
    if (leaseDurationSeconds <= 0) {
      throw ArgumentError.value(leaseDurationSeconds, 'leaseDurationSeconds');
    }
    final now = _now;
    final changed =
        await (db.update(db.memoryConsolidationJobRows)..where(
              (row) =>
                  row.id.equals(jobId) &
                  row.status.equals('running') &
                  row.leaseOwnerId.equals(ownerId) &
                  row.leaseExpiresAt.isBiggerThanValue(now),
            ))
            .write(
              MemoryConsolidationJobRowsCompanion(
                leaseExpiresAt: Value(now + leaseDurationSeconds),
                updatedAt: Value(now),
              ),
            );
    return changed == 1;
  }

  Future<bool> recoverExpiredLeases() {
    final now = _now;
    return db.transaction(() async {
      final expired =
          await (db.select(db.memoryConsolidationJobRows)..where(
                (row) =>
                    row.status.equals('running') &
                    row.leaseExpiresAt.isSmallerOrEqualValue(now),
              ))
              .get();
      var recovered = false;
      for (final job in expired) {
        final changed =
            await (db.update(db.memoryConsolidationJobRows)..where(
                  (row) =>
                      row.id.equals(job.id) &
                      row.version.equals(job.version) &
                      row.status.equals('running') &
                      row.leaseExpiresAt.isSmallerOrEqualValue(now),
                ))
                .write(
                  MemoryConsolidationJobRowsCompanion(
                    status: const Value('pending'),
                    leaseOwnerId: const Value(null),
                    leaseExpiresAt: const Value(null),
                    lastError: const Value('lease_expired'),
                    version: Value(job.version + 1),
                    updatedAt: Value(now),
                  ),
                );
        if (changed == 1) {
          recovered = true;
          await (db.update(db.memoryConsolidationJobItemRows)..where(
                (row) =>
                    row.jobId.equals(job.id) & row.status.equals('running'),
              ))
              .write(
                MemoryConsolidationJobItemRowsCompanion(
                  status: const Value('pending'),
                  lastError: const Value('lease_expired'),
                  updatedAt: Value(now),
                ),
              );
        }
      }
      return recovered;
    });
  }

  /// Retires device-local work whose frozen inputs were superseded by sync.
  /// Accepted registry rows are compared by their complete deterministic source
  /// identity; unrelated local review packages remain available.
  Future<void> reconcileAfterSync(
    String sessionId, {
    required bool sourceContextChanged,
    required bool registryChanged,
  }) => db.transaction(() async {
    final jobs =
        await (db.select(db.memoryConsolidationJobRows)..where(
              (row) =>
                  row.sessionId.equals(sessionId) &
                  row.status.isIn(const [
                    'pending',
                    'running',
                    'review_pending',
                    'failed',
                  ]),
            ))
            .get();
    if (jobs.isEmpty) return;

    Map<String, MemoryEntry>? currentEntries;
    List<ChatMessage>? currentHistory;
    if (sourceContextChanged) {
      try {
        final session = await (db.select(
          db.chatSessions,
        )..where((row) => row.sessionId.equals(sessionId))).getSingleOrNull();
        final book = await (db.select(
          db.memoryBookRows,
        )..where((row) => row.sessionId.equals(sessionId))).getSingleOrNull();
        if (session != null && book != null) {
          final history = await ChatMessageStorageRepo(
            db,
          ).loadMessagesBySessionId(sessionId);
          final entriesJson = jsonDecode(book.entriesJson);
          if (history != null && entriesJson is List) {
            currentHistory = history;
            final decodedEntries = <String, MemoryEntry>{};
            for (final item in entriesJson) {
              final memoryEntry = MemoryEntry.fromJson(
                Map<String, dynamic>.from(item as Map),
              );
              decodedEntries[memoryEntry.id] = memoryEntry;
            }
            currentEntries = decodedEntries;
          }
        }
      } on Object {
        currentEntries = null;
        currentHistory = null;
      }
    }

    final acceptedSources = <(String, String, String, String)>{};
    final occupiedEventIds = <String>{};
    if (registryChanged) {
      final invalidated =
          await (db.select(db.memoryEventInvalidationRows)..where(
                (row) =>
                    row.sessionId.equals(sessionId) &
                    row.targetType.equals('event'),
              ))
              .get();
      final invalidatedIds = invalidated.map((row) => row.targetId).toSet();
      final events =
          await (db.select(db.memoryEventRows)..where(
                (row) =>
                    row.sessionId.equals(sessionId) &
                    row.status.equals('active'),
              ))
              .get();
      final activeIds = events
          .map((row) => row.id)
          .where((id) => !invalidatedIds.contains(id))
          .toSet();
      occupiedEventIds.addAll(activeIds);
      if (activeIds.isNotEmpty) {
        final sources = await (db.select(
          db.memoryEventSourceRows,
        )..where((row) => row.eventId.isIn(activeIds))).get();
        acceptedSources.addAll(
          sources.map(
            (row) => (
              row.eventId,
              row.memoryEntryId,
              row.revisionId,
              row.fingerprint,
            ),
          ),
        );
      }
    }

    final now = _now;
    for (final job in jobs) {
      final items = await getItems(job.id);
      final exactCovered = items
          .where(
            (item) => acceptedSources.contains((
              item.proposedEventId,
              item.memoryEntryId,
              item.revisionId,
              item.fingerprint,
            )),
          )
          .length;
      final collidesWithAccepted = items.any(
        (item) => occupiedEventIds.contains(item.proposedEventId),
      );
      final completedRemotely =
          items.isNotEmpty && exactCovered == items.length;
      final sourcesStillCurrent =
          !sourceContextChanged ||
          (currentEntries != null &&
              currentHistory != null &&
              _sourcesAreCurrent(items, currentEntries, currentHistory));
      if (!completedRemotely && sourcesStillCurrent && !collidesWithAccepted) {
        continue;
      }
      final nextStatus = completedRemotely ? 'completed' : 'cancelled';
      final nextItemStatus = completedRemotely ? 'accepted' : 'cancelled';
      final reason = completedRemotely ? null : 'source_context_changed';
      final changed =
          await (db.update(db.memoryConsolidationJobRows)..where(
                (row) =>
                    row.id.equals(job.id) &
                    row.version.equals(job.version) &
                    row.status.equals(job.status),
              ))
              .write(
                MemoryConsolidationJobRowsCompanion(
                  status: Value(nextStatus),
                  leaseOwnerId: const Value(null),
                  leaseExpiresAt: const Value(null),
                  lastError: Value(reason),
                  version: Value(job.version + 1),
                  updatedAt: Value(now),
                ),
              );
      if (changed != 1) continue;
      await (db.update(
        db.memoryConsolidationJobItemRows,
      )..where((row) => row.jobId.equals(job.id))).write(
        MemoryConsolidationJobItemRowsCompanion(
          status: Value(nextItemStatus),
          lastError: Value(reason),
          updatedAt: Value(now),
        ),
      );
    }
  });

  static bool _sourcesAreCurrent(
    List<MemoryConsolidationJobItemRow> items,
    Map<String, MemoryEntry> entries,
    List<ChatMessage> history,
  ) {
    if (items.isEmpty) return false;
    for (final item in items) {
      final entry = entries[item.memoryEntryId];
      if (entry == null ||
          entry.status != 'active' ||
          !MemoryEntryRevisions.isUsable(entry)) {
        return false;
      }
      final revision = MemoryEntryRevisions.find(entry, item.revisionId);
      final manifest = revision?.sourceManifest;
      if (revision == null ||
          revision.id != entry.activeRevisionId ||
          manifest == null ||
          manifest != entry.sourceManifest ||
          !const ListEquality<String>().equals(
            entry.messageIds,
            revision.messageIds,
          ) ||
          manifest.validate(revision.messageIds, history) !=
              MemorySourceValidity.verified ||
          item.fingerprint !=
              MemoryEventRegistryRepo.sourceFingerprint(
                revision,
                sourceSwipeId: entry.sourceSwipeId,
                sourceAgentSwipeId: entry.sourceAgentSwipeId,
              )) {
        return false;
      }
    }
    return true;
  }

  Future<bool> retryFailed(String jobId) => db.transaction(() async {
    final now = _now;
    final jobTable = db.memoryConsolidationJobRows;
    final job = await (db.select(
      jobTable,
    )..where((row) => row.id.equals(jobId))).getSingleOrNull();
    if (job == null || job.status != 'failed') return false;
    final jobChanged =
        await (db.update(jobTable)..where(
              (row) =>
                  row.id.equals(jobId) &
                  row.version.equals(job.version) &
                  row.status.equals('failed'),
            ))
            .write(
              MemoryConsolidationJobRowsCompanion(
                status: const Value('pending'),
                leaseOwnerId: const Value(null),
                leaseExpiresAt: const Value(null),
                lastError: const Value(null),
                version: Value(job.version + 1),
                updatedAt: Value(now),
              ),
            );
    if (jobChanged != 1) return false;
    final failed = db.memoryConsolidationJobItemRows;
    await (db.update(failed)..where(
          (row) => row.jobId.equals(jobId) & row.status.equals('failed'),
        ))
        .write(
          MemoryConsolidationJobItemRowsCompanion(
            status: const Value('pending'),
            lastError: const Value(null),
            updatedAt: Value(now),
          ),
        );
    return true;
  });

  /// Cancels a job and its open items. [reason] is a machine-readable durable
  /// cause ('cancelled_by_user', 'source_context_changed', 'mode_disabled',
  /// 'rejected_by_user', ...); the UI localizes it, it never invents state.
  /// A real user cancellation is the default so existing callers stay honest.
  Future<bool> cancel(String jobId, {String reason = 'cancelled_by_user'}) =>
      db.transaction(() async {
        final now = _now;
        final job = await (db.select(
          db.memoryConsolidationJobRows,
        )..where((row) => row.id.equals(jobId))).getSingleOrNull();
        if (job == null) return false;
        final changed =
            await (db.update(db.memoryConsolidationJobRows)..where(
                  (row) =>
                      row.id.equals(jobId) &
                      row.version.equals(job.version) &
                      row.status.isIn(const [
                        'pending',
                        'running',
                        'review_pending',
                        'failed',
                      ]),
                ))
                .write(
                  MemoryConsolidationJobRowsCompanion(
                    status: const Value('cancelled'),
                    leaseOwnerId: const Value(null),
                    leaseExpiresAt: const Value(null),
                    version: Value(job.version + 1),
                    lastError: Value(reason),
                    updatedAt: Value(now),
                  ),
                );
        if (changed == 1) {
          await (db.update(db.memoryConsolidationJobItemRows)..where(
                (row) =>
                    row.jobId.equals(jobId) &
                    row.status.isIn(const [
                      'pending',
                      'running',
                      'failed',
                      'review_pending',
                    ]),
              ))
              .write(
                MemoryConsolidationJobItemRowsCompanion(
                  status: const Value('cancelled'),
                  lastError: Value(reason),
                  updatedAt: Value(now),
                ),
              );
        }
        return changed == 1;
      });

  /// Re-queues a cancelled package with the same immutable source snapshot.
  /// The stored draft is dropped: a revived package redrafts from the same
  /// sources, it never resurrects a reviewed proposal. A concurrent claim that
  /// already moved the row on loses to the CAS and returns the fresh row.
  Future<MemoryConsolidationJobRow> revive(String jobId) =>
      db.transaction(() async {
        final now = _now;
        final job = await (db.select(
          db.memoryConsolidationJobRows,
        )..where((row) => row.id.equals(jobId))).getSingle();
        if (job.status != 'cancelled') return job;
        final changed =
            await (db.update(db.memoryConsolidationJobRows)..where(
                  (row) =>
                      row.id.equals(jobId) &
                      row.version.equals(job.version) &
                      row.status.equals('cancelled'),
                ))
                .write(
                  MemoryConsolidationJobRowsCompanion(
                    status: const Value('pending'),
                    packageDraftJson: const Value(null),
                    leaseOwnerId: const Value(null),
                    leaseExpiresAt: const Value(null),
                    lastError: const Value(null),
                    version: Value(job.version + 1),
                    updatedAt: Value(now),
                  ),
                );
        if (changed != 1) {
          return (db.select(
            db.memoryConsolidationJobRows,
          )..where((row) => row.id.equals(jobId))).getSingle();
        }
        await (db.update(db.memoryConsolidationJobItemRows)..where(
              (row) =>
                  row.jobId.equals(jobId) &
                  row.status.isNotIn(const ['accepted']),
            ))
            .write(
              MemoryConsolidationJobItemRowsCompanion(
                status: const Value('pending'),
                draftJson: const Value(null),
                lastError: const Value(null),
                updatedAt: Value(now),
              ),
            );
        return (db.select(
          db.memoryConsolidationJobRows,
        )..where((row) => row.id.equals(jobId))).getSingle();
      });

  /// Watches this session's package jobs, newest first. Review and queue UI
  /// follow this stream instead of polling.
  Stream<List<MemoryConsolidationJobRow>> watchSessionJobs(String sessionId) =>
      (db.select(db.memoryConsolidationJobRows)
            ..where((row) => row.sessionId.equals(sessionId))
            ..orderBy([
              (row) => OrderingTerm.desc(row.createdAt),
              (row) => OrderingTerm.desc(row.id),
            ]))
          .watch();

  static const _supersededCancelled = '''
cancelled.status = 'cancelled'
  AND EXISTS (
    SELECT 1 FROM memory_consolidation_job_item_rows AS cancelled_item
    WHERE cancelled_item.job_id = cancelled.id
  )
  AND (
    NOT EXISTS (
      SELECT 1 FROM memory_consolidation_job_item_rows AS cancelled_item
      WHERE cancelled_item.job_id = cancelled.id
        AND NOT EXISTS (
          SELECT 1 FROM memory_consolidation_job_item_rows AS accepted_item
          INNER JOIN memory_consolidation_job_rows AS completed
            ON completed.id = accepted_item.job_id
          WHERE completed.session_id = cancelled.session_id
            AND completed.branch_id = cancelled.branch_id
            AND completed.status = 'completed'
            AND accepted_item.status = 'accepted'
            AND accepted_item.memory_entry_id = cancelled_item.memory_entry_id
            AND accepted_item.revision_id = cancelled_item.revision_id
            AND accepted_item.fingerprint = cancelled_item.fingerprint
        )
    )
    OR (
      EXISTS (
        SELECT 1 FROM memory_book_rows AS book
        WHERE book.session_id = cancelled.session_id
      )
      AND NOT EXISTS (
        SELECT 1
        FROM memory_consolidation_job_item_rows AS cancelled_item
        WHERE cancelled_item.job_id = cancelled.id
          AND EXISTS (
            SELECT 1
            FROM memory_book_rows AS book, json_each(book.entries_json) AS entry
            WHERE book.session_id = cancelled.session_id
              AND json_extract(entry.value, '\$.id') = cancelled_item.memory_entry_id
              AND COALESCE(json_extract(entry.value, '\$.status'), 'active') = 'active'
          )
          AND NOT EXISTS (
            SELECT 1
            FROM memory_event_source_rows AS event_source
            INNER JOIN memory_event_rows AS event
              ON event.id = event_source.event_id
            WHERE event_source.session_id = cancelled.session_id
              AND event_source.branch_id = cancelled.branch_id
              AND event_source.memory_entry_id = cancelled_item.memory_entry_id
              AND event.status = 'active'
              AND NOT EXISTS (
                SELECT 1
                FROM memory_event_invalidation_rows AS invalidation
                WHERE invalidation.session_id = cancelled.session_id
                  AND invalidation.branch_id = cancelled.branch_id
                  AND invalidation.target_type = 'event'
                  AND invalidation.target_id = event.id
              )
          )
      )
    )
  )
''';

  /// Cancelled jobs that no longer contain rebuildable work. Exact completed
  /// snapshots qualify directly; so do jobs whose current entries are all
  /// covered by active registry events or have left the current Memory Book.
  Stream<Set<String>> watchSupersededCancelledJobIds(String sessionId) {
    final jobs = db.memoryConsolidationJobRows;
    final items = db.memoryConsolidationJobItemRows;
    final books = db.memoryBookRows;
    final events = db.memoryEventRows;
    final eventSources = db.memoryEventSourceRows;
    final invalidations = db.memoryEventInvalidationRows;
    return db
        .customSelect(
          '''
SELECT cancelled.id
FROM memory_consolidation_job_rows AS cancelled
WHERE cancelled.session_id = ?
  AND ($_supersededCancelled)
''',
          variables: [Variable.withString(sessionId)],
          readsFrom: {jobs, items, books, events, eventSources, invalidations},
        )
        .watch()
        .map((rows) => {for (final row in rows) row.read<String>('id')});
  }

  /// Source readers use the same exact rule as the queue. Decline the expensive
  /// match on large stores rather than call an incomplete search a non-match.
  /// The row position comes from a native, visibility-checked saved-data read.
  Future<String> readSavedCancellationCoverage(int rowPosition) async {
    final row = await db
        .customSelect(
          '''
      SELECT CASE
        WHEN EXISTS (SELECT 1 FROM memory_consolidation_job_rows LIMIT 1 OFFSET 512)
          OR EXISTS (SELECT 1 FROM memory_consolidation_job_item_rows LIMIT 1 OFFSET 8192)
          OR EXISTS (SELECT 1 FROM memory_consolidation_job_item_rows
                     WHERE job_id = cancelled.id LIMIT 1 OFFSET 64)
          OR EXISTS (SELECT 1 FROM memory_event_rows LIMIT 1 OFFSET 4096)
          OR EXISTS (SELECT 1 FROM memory_event_source_rows LIMIT 1 OFFSET 8192)
          OR EXISTS (SELECT 1 FROM memory_event_invalidation_rows LIMIT 1 OFFSET 4096)
          OR EXISTS (SELECT 1 FROM memory_book_rows
                     WHERE json_array_length(entries_json) > 1024)
          THEN 'unknown_work_limit'
        WHEN $_supersededCancelled THEN 'superseded'
        ELSE 'not_superseded'
      END AS coverage
      FROM memory_consolidation_job_rows AS cancelled
      WHERE rowid = ? AND status = 'cancelled'
      ''',
          variables: [Variable.withInt(rowPosition)],
        )
        .getSingleOrNull();
    return row?.read<String>('coverage') ?? 'unknown_changed';
  }

  /// One-shot read of this session's package jobs, newest first — the same
  /// ordering [watchSessionJobs] streams, for callers that need a snapshot
  /// (for example a scan dry run counting failed packages).
  Future<List<MemoryConsolidationJobRow>> getSessionJobs(String sessionId) =>
      (db.select(db.memoryConsolidationJobRows)
            ..where((row) => row.sessionId.equals(sessionId))
            ..orderBy([
              (row) => OrderingTerm.desc(row.createdAt),
              (row) => OrderingTerm.desc(row.id),
            ]))
          .get();

  Stream<List<MemoryConsolidationJobItemRow>> watchItems(String jobId) =>
      (db.select(db.memoryConsolidationJobItemRows)
            ..where((row) => row.jobId.equals(jobId))
            ..orderBy([(row) => OrderingTerm.asc(row.createdAt)]))
          .watch();

  /// Watches source counts per package job of one session — the queue rows
  /// show "Package N · K memories" without loading every item row.
  Stream<Map<String, int>> watchSessionItemCounts(String sessionId) {
    final items = db.memoryConsolidationJobItemRows;
    final jobs = db.memoryConsolidationJobRows;
    final count = items.id.count();
    final query =
        db.select(items).join([
            innerJoin(jobs, jobs.id.equalsExp(items.jobId), useColumns: false),
          ])
          ..where(jobs.sessionId.equals(sessionId))
          ..addColumns([count])
          ..groupBy([items.jobId]);
    return query.watch().map(
      (rows) => {
        for (final row in rows)
          row.readTable(items).jobId: row.read(count) ?? 0,
      },
    );
  }

  Future<MemoryConsolidationJobRow?> _ownedLease(
    String jobId,
    String ownerId,
    int now,
  ) async =>
      (await (db.select(db.memoryConsolidationJobRows)..where(
            (row) =>
                row.id.equals(jobId) &
                row.status.equals('running') &
                row.leaseOwnerId.equals(ownerId) &
                row.leaseExpiresAt.isBiggerThanValue(now),
          ))
          .getSingleOrNull());

  Future<void> _refreshJobStatus(
    MemoryConsolidationJobRow job,
    String ownerId,
    int now,
  ) async {
    final items = await getItems(job.id);
    final hasPending = items.any((item) => item.status == 'pending');
    final hasRunning = items.any((item) => item.status == 'running');
    final hasFailed = items.any((item) => item.status == 'failed');
    final status = hasPending || hasRunning
        ? 'running'
        : hasFailed
        ? 'failed'
        : 'review_pending';
    await (db.update(db.memoryConsolidationJobRows)..where(
          (row) =>
              row.id.equals(job.id) &
              row.status.equals('running') &
              row.leaseOwnerId.equals(ownerId) &
              row.version.equals(job.version),
        ))
        .write(
          MemoryConsolidationJobRowsCompanion(
            status: Value(status),
            leaseOwnerId: Value(status == 'running' ? ownerId : null),
            leaseExpiresAt: Value(
              status == 'running' ? job.leaseExpiresAt : null,
            ),
            lastError: Value(hasFailed ? 'item_failed' : null),
            version: Value(job.version + 1),
            updatedAt: Value(now),
          ),
        );
  }
}
