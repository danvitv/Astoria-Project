part of '../support_repo.dart';

/// Local mutation audit and report receipts, independent of feature state.
final class _SupportJournalStore {
  _SupportJournalStore(this.db, this.cipher, this.mapper, this.sessions);
  final AppDatabase db;
  final SupportPayloadCipher cipher;
  final _SupportRowMapper mapper;
  final _SupportSessionStore sessions;
  Future<SupportMutationJournalRow?> _mutationRow(String id) => (db.select(
    db.supportMutationJournal,
  )..where((t) => t.id.equals(id))).getSingleOrNull();
  Future<SupportMutationRecord> putMutation(SupportMutationRecord record) =>
      db.transaction(() async {
        _requireUnlocked(record.isLocked);
        await sessions.requireParent(record.sessionId);
        final existing = await _mutationRow(record.id);
        if (existing != null) {
          _requireSameSession(existing.sessionId, record.sessionId);
          _requireUnlocked((await mapper.mutation(existing)).isLocked);
        }
        final before = await cipher.encrypt(
          plaintext: record.beforeJson,
          table: 'support_mutation_journal',
          rowId: record.id,
          sessionId: record.sessionId,
          field: 'before_ciphertext',
        );
        final after = await cipher.encrypt(
          plaintext: record.afterJson,
          table: 'support_mutation_journal',
          rowId: record.id,
          sessionId: record.sessionId,
          field: 'after_ciphertext',
        );
        await db
            .into(db.supportMutationJournal)
            .insertOnConflictUpdate(
              SupportMutationJournalCompanion(
                id: Value(record.id),
                sessionId: Value(record.sessionId),
                domain: Value(record.domain),
                targetId: Value(record.targetId),
                beforeCiphertext: Value(before),
                afterCiphertext: Value(after),
                status: Value(record.status),
                createdAt: Value(record.createdAt),
              ),
            );
        return mapper.mutation((await _mutationRow(record.id))!);
      });
  Future<SupportMutationRecord?> getMutation(String id) async {
    final row = await _mutationRow(id);
    return row == null ? null : mapper.mutation(row);
  }

  Future<List<SupportMutationRecord>> mutations(String sessionId) async {
    final rows =
        await (db.select(db.supportMutationJournal)
              ..where((t) => t.sessionId.equals(sessionId))
              ..orderBy([
                (t) => OrderingTerm.desc(t.createdAt),
                (t) => OrderingTerm.desc(t.id),
              ]))
            .get();
    final result = <SupportMutationRecord>[];
    for (final row in rows) {
      result.add(await mapper.mutation(row));
    }
    return result;
  }

  Future<SupportMutationRecord?> updateMutationStatus(
    String id,
    String status,
  ) => db.transaction(() async {
    final row = await _mutationRow(id);
    if (row == null) return null;
    await sessions.requireParent(row.sessionId, unlocked: false);
    await (db.update(db.supportMutationJournal)..where((t) => t.id.equals(id)))
        .write(SupportMutationJournalCompanion(status: Value(status)));
    return mapper.mutation((await _mutationRow(id))!);
  });
  Future<SupportReportRow?> _reportRow(String id) => (db.select(
    db.supportReports,
  )..where((t) => t.id.equals(id))).getSingleOrNull();
  Future<SupportReportRecord> putReport(SupportReportRecord report) =>
      db.transaction(() async {
        await sessions.requireParent(report.sessionId, unlocked: false);
        final existing = await _reportRow(report.id);
    if (existing != null) {
      _requireSameSession(existing.sessionId, report.sessionId);
    }
        await db
            .into(db.supportReports)
            .insertOnConflictUpdate(
              SupportReportsCompanion(
                id: Value(report.id),
                sessionId: Value(report.sessionId),
                fileHash: Value(report.fileHash),
                status: Value(report.status),
                createdAt: Value(report.createdAt),
              ),
            );
        return mapper.report((await _reportRow(report.id))!);
      });
  Future<SupportReportRecord?> getReport(String id) async {
    final row = await _reportRow(id);
    return row == null ? null : mapper.report(row);
  }

  Future<List<SupportReportRecord>> reports(String sessionId) async {
    final rows =
        await (db.select(db.supportReports)
              ..where((t) => t.sessionId.equals(sessionId))
              ..orderBy([
                (t) => OrderingTerm.desc(t.createdAt),
                (t) => OrderingTerm.desc(t.id),
              ]))
            .get();
    return rows.map(mapper.report).toList(growable: false);
  }
}
