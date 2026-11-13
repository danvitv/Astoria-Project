import 'dart:math';

import 'package:drift/drift.dart';

import '../app_db.dart';

enum CardEvolutionJobStatus {
  pending,
  running,
  completed,
  failed,
  cancelled,
  stale;

  bool get isTerminal => this != pending && this != running;
}

/// Sole SQL owner of the local, review-only evolution queue.
///
/// Enqueue only after the exact reconciliation commit. The caller supplies an
/// already sanitized nonsecret routing snapshot/hash; these strings are opaque
/// here (no provider resolution, credentials, prompts or network work). A repeat
/// reservation returns the original snapshot, including terminal outcomes.
///
/// All times are epoch seconds. Claim returns a fresh cross-process nonce:
/// retain it for heartbeat/finish, and stop publishing when either returns false.
/// This lease protects queue state, not rewrite output: integration must guard
/// any separate proposal write with its own source/cancellation fence. Completion
/// means review preparation only, never permission to apply a card change.
class CardEvolutionJobRepo {
  CardEvolutionJobRepo(this.db);

  final AppDatabase db;
  static const delaySeconds = 2;

  // Successful runs are immutable but can be removed or invalidated. They have
  // no character column, so character ownership is the exact live session join.
  static const _sourceCurrent = '''
    EXISTS (
      SELECT 1 FROM reconciliation_successful_runs r
      JOIN chat_sessions s ON s.session_id = r.session_id
      JOIN characters c ON c.char_id = s.character_id
      WHERE r.id = card_evolution_jobs.reconciliation_run_id
        AND r.session_id = card_evolution_jobs.session_id
        AND s.character_id = card_evolution_jobs.character_id
        AND r.chain_hash = card_evolution_jobs.reconciliation_chain_hash
        AND NOT EXISTS (
          SELECT 1 FROM reconciliation_run_invalidations i
          WHERE i.session_id = r.session_id AND i.run_id = r.id
        )
    )
  ''';

  Future<CardEvolutionJobRow?> getById(String id) => (db.select(
    db.cardEvolutionJobs,
  )..where((row) => row.id.equals(id))).getSingleOrNull();

  /// Includes future reservations and live leases for startup recovery/UI.
  Future<List<CardEvolutionJobRow>> listUnfinished() => _unfinished().get();

  Stream<List<CardEvolutionJobRow>> watchUnfinished() => _unfinished().watch();

  Stream<List<CardEvolutionJobRow>> watchSessionJobs(String sessionId) =>
      (db.select(db.cardEvolutionJobs)
            ..where((row) => row.sessionId.equals(sessionId))
            ..orderBy([
              (row) => OrderingTerm.desc(row.updatedAt),
              (row) => OrderingTerm.desc(row.id),
            ])
            ..limit(30))
          .watch();

  SimpleSelectStatement<$CardEvolutionJobsTable, CardEvolutionJobRow>
  _unfinished() => db.select(db.cardEvolutionJobs)
    ..where((row) => row.status.isIn(const ['pending', 'running']))
    ..orderBy([
      (row) => OrderingTerm.asc(row.availableAt),
      (row) => OrderingTerm.asc(row.id),
    ]);

  /// Recheck immediately before a separate guarded result write. This is an
  /// observation, not a transaction spanning the caller's later work.
  Future<bool> isOwned({
    required String id,
    required String ownerNonce,
    required int now,
  }) => db.transaction(() async {
    await _staleInvalidSource(id, now);
    return (await db
            .customSelect(
              'SELECT id FROM card_evolution_jobs '
              "WHERE id = ? AND status = 'running' AND owner_nonce = ? "
              'AND lease_until > ? AND $_sourceCurrent',
              variables: [
                Variable.withString(id),
                Variable.withString(ownerNonce),
                Variable.withInt(now),
              ],
              readsFrom: {db.cardEvolutionJobs},
            )
            .getSingleOrNull()) !=
        null;
  });

  Future<CardEvolutionJobRow> enqueue({
    required String sessionId,
    required String characterId,
    required String reconciliationRunId,
    required String routingSnapshotJson,
    required String routingSnapshotHash,
    required int now,
  }) => db.transaction(() async {
    await db.customInsert(
      '''
      INSERT INTO card_evolution_jobs
        (id, session_id, character_id, reconciliation_run_id,
         reconciliation_chain_hash, routing_snapshot_json,
         routing_snapshot_hash, available_at, created_at, updated_at)
      SELECT ?, ?, ?, r.id, r.chain_hash, ?, ?, ?, ?, ?
      FROM reconciliation_successful_runs r
      JOIN chat_sessions s ON s.session_id = r.session_id
      JOIN characters c ON c.char_id = s.character_id
      WHERE r.id = ? AND r.session_id = ? AND s.character_id = ?
        AND NOT EXISTS (
          SELECT 1 FROM reconciliation_run_invalidations i
          WHERE i.session_id = r.session_id AND i.run_id = r.id
        )
      ON CONFLICT (reconciliation_run_id) DO NOTHING
      ''',
      variables: [
        Variable.withString('evolution-job-$reconciliationRunId'),
        Variable.withString(sessionId),
        Variable.withString(characterId),
        Variable.withString(routingSnapshotJson),
        Variable.withString(routingSnapshotHash),
        Variable.withInt(now + delaySeconds),
        Variable.withInt(now),
        Variable.withInt(now),
        Variable.withString(reconciliationRunId),
        Variable.withString(sessionId),
        Variable.withString(characterId),
      ],
      updates: {db.cardEvolutionJobs},
    );
    final row =
        await (db.select(db.cardEvolutionJobs)..where(
              (row) => row.reconciliationRunId.equals(reconciliationRunId),
            ))
            .getSingleOrNull();
    if (row == null ||
        row.sessionId != sessionId ||
        row.characterId != characterId) {
      throw StateError('Exact committed reconciliation source unavailable');
    }
    await _staleInvalidSource(row.id, now);
    return (await getById(row.id))!;
  });

  /// Includes delayed pending jobs so a scheduler can use their availableAt.
  /// Expired running rows may be claimed directly or recovered in bounded batches.
  Future<List<CardEvolutionJobRow>> listRecoverable({
    required int now,
    int limit = 100,
  }) {
    _checkLimit(limit);
    return (db.select(db.cardEvolutionJobs)
          ..where(
            (row) =>
                row.status.equals('pending') |
                (row.status.equals('running') &
                    row.leaseUntil.isSmallerOrEqualValue(now)),
          )
          ..orderBy([
            (row) => OrderingTerm.asc(row.availableAt),
            (row) => OrderingTerm.asc(row.id),
          ])
          ..limit(limit))
        .get();
  }

  /// One conditional SQL write arbitrates both ownership and per-session live
  /// exclusivity across repository instances/processes. Null means not claimed;
  /// a changed/missing source is durably marked stale, never rebound.
  Future<CardEvolutionJobRow?> claim({
    required String id,
    required int now,
    int leaseSeconds = 60,
  }) {
    _checkLease(leaseSeconds);
    final random = Random.secure();
    final nonce = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return db.transaction(() async {
      await _staleInvalidSource(id, now);
      final count = await db.customUpdate(
        '''
        UPDATE card_evolution_jobs
        SET status = 'running', owner_nonce = ?, lease_until = ?, updated_at = ?
        WHERE id = ? AND available_at <= ?
          AND (status = 'pending' OR (status = 'running' AND lease_until <= ?))
          AND $_sourceCurrent
          AND NOT EXISTS (
            SELECT 1 FROM card_evolution_jobs other
            WHERE other.session_id = card_evolution_jobs.session_id
              AND other.id <> card_evolution_jobs.id
              AND other.status = 'running' AND other.lease_until > ?
          )
        ''',
        variables: [
          Variable.withString(nonce),
          Variable.withInt(now + leaseSeconds),
          Variable.withInt(now),
          Variable.withString(id),
          Variable.withInt(now),
          Variable.withInt(now),
          Variable.withInt(now),
        ],
        updates: {db.cardEvolutionJobs},
      );
      return count == 1 ? getById(id) : null;
    });
  }

  Future<bool> heartbeat({
    required String id,
    required String ownerNonce,
    required int now,
    int leaseSeconds = 60,
  }) {
    _checkLease(leaseSeconds);
    return _writeOwned(
      id: id,
      ownerNonce: ownerNonce,
      now: now,
      assignments: 'lease_until = MAX(lease_until, ?), updated_at = ?',
      values: [Variable.withInt(now + leaseSeconds), Variable.withInt(now)],
    );
  }

  Future<bool> finish({
    required String id,
    required String ownerNonce,
    required int now,
    required CardEvolutionJobStatus status,
    String? resultDetail,
  }) {
    if (!status.isTerminal) {
      throw ArgumentError.value(status, 'status', 'Must be terminal');
    }
    return _writeOwned(
      id: id,
      ownerNonce: ownerNonce,
      now: now,
      assignments:
          'status = ?, result_detail = ?, updated_at = ?, '
          'owner_nonce = NULL, lease_until = NULL',
      values: [
        Variable.withString(status.name),
        Variable<String>(resultDetail),
        Variable.withInt(now),
      ],
    );
  }

  Future<bool> cancel({
    required String id,
    required int now,
    String? resultDetail,
  }) async =>
      await db.customUpdate(
        "UPDATE card_evolution_jobs SET status = 'cancelled', "
        'owner_nonce = NULL, lease_until = NULL, updated_at = ?, result_detail = ? '
        "WHERE id = ? AND status IN ('pending', 'running')",
        variables: [
          Variable.withInt(now),
          Variable<String>(resultDetail),
          Variable.withString(id),
        ],
        updates: {db.cardEvolutionJobs},
      ) ==
      1;

  Future<int> recoverExpiredLeases({required int now, int limit = 100}) {
    _checkLimit(limit);
    return db.customUpdate(
      '''
      UPDATE card_evolution_jobs
      SET status = CASE WHEN $_sourceCurrent THEN 'pending' ELSE 'stale' END,
          owner_nonce = NULL, lease_until = NULL, updated_at = ?
      WHERE id IN (
        SELECT id FROM card_evolution_jobs
        WHERE status = 'running' AND lease_until <= ?
        ORDER BY lease_until, id LIMIT ?
      ) AND status = 'running' AND lease_until <= ?
      ''',
      variables: [
        Variable.withInt(now),
        Variable.withInt(now),
        Variable.withInt(limit),
        Variable.withInt(now),
      ],
      updates: {db.cardEvolutionJobs},
    );
  }

  Future<bool> _writeOwned({
    required String id,
    required String ownerNonce,
    required int now,
    required String assignments,
    required List<Variable> values,
  }) => db.transaction(() async {
    await _staleInvalidSource(id, now);
    return await db.customUpdate(
          'UPDATE card_evolution_jobs SET $assignments '
          "WHERE id = ? AND status = 'running' AND owner_nonce = ? "
          'AND lease_until > ? AND $_sourceCurrent',
          variables: [
            ...values,
            Variable.withString(id),
            Variable.withString(ownerNonce),
            Variable.withInt(now),
          ],
          updates: {db.cardEvolutionJobs},
        ) ==
        1;
  });

  Future<int> _staleInvalidSource(String id, int now) => db.customUpdate(
    "UPDATE card_evolution_jobs SET status = 'stale', owner_nonce = NULL, "
    "lease_until = NULL, result_detail = 'source_context_changed', updated_at = ? "
    "WHERE id = ? AND status IN ('pending', 'running') AND NOT ($_sourceCurrent)",
    variables: [Variable.withInt(now), Variable.withString(id)],
    updates: {db.cardEvolutionJobs},
  );

  static void _checkLimit(int limit) {
    if (limit < 1 || limit > 1000) {
      throw RangeError.range(limit, 1, 1000, 'limit');
    }
  }

  static void _checkLease(int seconds) {
    if (seconds <= 0) throw ArgumentError.value(seconds, 'leaseSeconds');
  }
}
