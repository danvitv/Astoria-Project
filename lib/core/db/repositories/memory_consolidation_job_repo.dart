import 'package:drift/drift.dart';

import '../../utils/id_generator.dart';
import '../../utils/time_helpers.dart';
import '../app_db.dart';
import 'memory_event_registry_repo.dart';

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
      );
      final rows = <MemoryConsolidationJobRow>[];
      for (final package in packages) {
        final available = package
            .where(
              (item) =>
                  !covered.contains(item.memoryEntryId) &&
                  !reserved.contains(item.sourceIdentity),
            )
            .toList();
        if (available.length < minCount) continue;
        final job = await createOrGet(
          sessionId: sessionId,
          branchId: branchId,
          requestKey: requestKeyForItems(available),
          items: available,
        );
        rows.add(job.status == 'cancelled' ? await revive(job.id) : job);
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
                  row.packageDraftJson.isNull(),
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
    await (db.update(db.memoryConsolidationJobItemRows)..where(
          (row) => row.jobId.equals(jobId) & row.status.equals('running'),
        ))
        .write(
          MemoryConsolidationJobItemRowsCompanion(
            status: const Value('review_pending'),
            updatedAt: Value(now),
          ),
        );
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

  Future<bool> cancel(String jobId) => db.transaction(() async {
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
                lastError: const Value('cancelled_by_user'),
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
              lastError: const Value('cancelled_by_user'),
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
