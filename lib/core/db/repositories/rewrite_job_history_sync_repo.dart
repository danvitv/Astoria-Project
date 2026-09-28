import 'dart:convert';

import 'package:drift/drift.dart';

import '../../application/sync_repo_interfaces.dart';
import '../app_db.dart';

/// Per-session, insert-only history of terminal rewrite jobs. Active proposals
/// and writer calls stay on their originating device; importing a history row
/// cannot create an executable rewrite.
class RewriteJobHistorySyncRepo implements SyncRewriteJobHistoryStore {
  const RewriteJobHistorySyncRepo(this.db);

  final AppDatabase db;

  // Cancelled proposals are explicitly deletable; copying them merge-only
  // would resurrect a proposal the user removed on another device.
  static const _statuses = ['applied'];

  @override
  Future<List<String>> getAllSessionIds() async {
    final jobs = await (db.select(
      db.rewriteJobs,
    )..where((row) => row.status.isIn(_statuses))).get();
    return (jobs.map((row) => row.chatSessionId).toSet().toList()..sort());
  }

  @override
  Future<Map<String, dynamic>?> getBySessionId(String sessionId) async {
    final session = await (db.select(
      db.chatSessions,
    )..where((row) => row.sessionId.equals(sessionId))).getSingleOrNull();
    if (session == null) return null;
    final jobs =
        await (db.select(db.rewriteJobs)
              ..where(
                (row) =>
                    row.chatSessionId.equals(sessionId) &
                    row.status.isIn(_statuses),
              )
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();
    if (jobs.isEmpty) return null;
    final jobIds = jobs.map((row) => row.id).toList();
    final operations =
        await (db.select(db.rewriteOperations)
              ..where((row) => row.rewriteJobId.isIn(jobIds))
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();
    final ids = operations.map((row) => row.id).toList();
    final revisions = ids.isEmpty
        ? <RewriteOperationRevisionRow>[]
        : await (db.select(db.rewriteOperationRevisions)
                ..where((row) => row.rewriteOperationId.isIn(ids))
                ..orderBy([
                  (row) => OrderingTerm.asc(row.rewriteOperationId),
                  (row) => OrderingTerm.asc(row.revision),
                ]))
              .get();
    final evidence = ids.isEmpty
        ? <RewriteEvidenceRow>[]
        : await (db.select(db.rewriteEvidenceRows)
                ..where((row) => row.rewriteOperationId.isIn(ids))
                ..orderBy([(row) => OrderingTerm.asc(row.id)]))
              .get();
    return {
      '__rewriteJobHistory': true,
      'schemaVersion': 1,
      'sessionId': sessionId,
      'jobs': jobs.map((row) => row.toJson()).toList(),
      'operations': operations.map((row) => row.toJson()).toList(),
      'revisions': revisions.map((row) => row.toJson()).toList(),
      // The review UI needs the evidence count, not the selected chat and
      // writer input stored in evidenceJson. Those may be large and private.
      'evidence': evidence
          .map((row) => {...row.toJson(), 'evidenceJson': '{}'})
          .toList(),
    };
  }

  /// Atomic union of immutable terminal records. An identity collision with
  /// different data fails closed rather than replacing a local review or edit.
  @override
  Future<Map<String, dynamic>> mergeBySessionId(
    String sessionId,
    Map<String, dynamic> data,
  ) async {
    if (data['__rewriteJobHistory'] != true ||
        data['schemaVersion'] != 1 ||
        data['sessionId'] != sessionId) {
      throw const FormatException('Invalid rewrite history payload');
    }
    final jobs = _rows(data, 'jobs', RewriteJobRow.fromJson);
    final operations = _rows(data, 'operations', RewriteOperationRow.fromJson);
    final revisions = _rows(
      data,
      'revisions',
      RewriteOperationRevisionRow.fromJson,
    );
    final evidence = _rows(data, 'evidence', RewriteEvidenceRow.fromJson);
    final jobIds = <String>{};
    for (final job in jobs) {
      if (job.chatSessionId != sessionId ||
          !_statuses.contains(job.status) ||
          !jobIds.add(job.id)) {
        throw const FormatException('Foreign or nonterminal rewrite job');
      }
    }
    if (jobs.isEmpty) {
      throw const FormatException('Empty rewrite history payload');
    }
    final operationIds = <String>{};
    for (final operation in operations) {
      if (!jobIds.contains(operation.rewriteJobId) ||
          operation.chatSessionId != sessionId ||
          !operationIds.add(operation.id)) {
        throw const FormatException('Foreign or duplicate rewrite operation');
      }
    }
    final revisionKeys = <(String, int)>{};
    for (final revision in revisions) {
      if (!operationIds.contains(revision.rewriteOperationId) ||
          !revisionKeys.add((revision.rewriteOperationId, revision.revision))) {
        throw const FormatException('Foreign or duplicate operation revision');
      }
    }
    for (final operation in operations) {
      if (!revisions.any(
        (revision) =>
            revision.rewriteOperationId == operation.id &&
            revision.revision == operation.currentRevision &&
            revision.snapshotJson == operation.operationJson,
      )) {
        throw const FormatException('Missing current operation snapshot');
      }
    }
    final evidenceIds = <String>{};
    for (final item in evidence) {
      if (!operationIds.contains(item.rewriteOperationId) ||
          !evidenceIds.add(item.id) ||
          item.evidenceJson != '{}') {
        throw const FormatException('Foreign or duplicate rewrite evidence');
      }
    }

    final appliedOperationsByJob = <String, int>{};
    for (final operation in operations) {
      if (operation.status != 'applied' && operation.status != 'reviewable') {
        throw const FormatException('Invalid applied-job operation state');
      }
      if (operation.status == 'applied') {
        appliedOperationsByJob.update(
          operation.rewriteJobId,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      }
    }
    for (final job in jobs) {
      if (appliedOperationsByJob[job.id] == null) {
        throw const FormatException('Applied job has no applied operations');
      }
    }

    await db.transaction(() async {
      final session = await (db.select(
        db.chatSessions,
      )..where((row) => row.sessionId.equals(sessionId))).getSingleOrNull();
      if (session == null) {
        throw StateError('Rewrite history has no owning chat');
      }
      for (final job in jobs) {
        final existing = await (db.select(
          db.rewriteJobs,
        )..where((row) => row.id.equals(job.id))).getSingleOrNull();
        _verify(existing, job);
        if (existing == null) await db.into(db.rewriteJobs).insert(job);
      }
      for (final operation in operations) {
        final existing = await (db.select(
          db.rewriteOperations,
        )..where((row) => row.id.equals(operation.id))).getSingleOrNull();
        _verify(existing, operation);
        if (existing == null) {
          await db.into(db.rewriteOperations).insert(operation);
        }
      }
      for (final revision in revisions) {
        final existing =
            await (db.select(db.rewriteOperationRevisions)..where(
                  (row) =>
                      row.rewriteOperationId.equals(
                        revision.rewriteOperationId,
                      ) &
                      row.revision.equals(revision.revision),
                ))
                .getSingleOrNull();
        _verify(existing, revision);
        if (existing == null) {
          await db.into(db.rewriteOperationRevisions).insert(revision);
        }
      }
      for (final item in evidence) {
        final existing = await (db.select(
          db.rewriteEvidenceRows,
        )..where((row) => row.id.equals(item.id))).getSingleOrNull();
        _verify(existing?.copyWith(evidenceJson: '{}'), item);
        if (existing == null) {
          await db.into(db.rewriteEvidenceRows).insert(item);
        }
      }
    });
    return (await getBySessionId(sessionId)) ?? _empty(sessionId);
  }

  static Map<String, dynamic> _empty(String sessionId) => {
    '__rewriteJobHistory': true,
    'schemaVersion': 1,
    'sessionId': sessionId,
    'jobs': <Object>[],
    'operations': <Object>[],
    'revisions': <Object>[],
    'evidence': <Object>[],
  };

  static void _verify(DataClass? existing, DataClass incoming) {
    if (existing != null &&
        jsonEncode(existing.toJson()) != jsonEncode(incoming.toJson())) {
      throw StateError('Conflicting rewrite history identity');
    }
  }

  static List<T> _rows<T>(
    Map<String, dynamic> data,
    String key,
    T Function(Map<String, dynamic>) decode,
  ) {
    final raw = data[key];
    if (raw is! List) throw FormatException('Missing rewrite history $key');
    return raw.map((value) {
      if (value is! Map<String, dynamic>) {
        throw FormatException('Invalid rewrite history $key row');
      }
      return decode(value);
    }).toList();
  }
}
