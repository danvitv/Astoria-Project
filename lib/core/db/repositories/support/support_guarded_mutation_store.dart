part of '../support_repo.dart';

/// Owns the single create-only journal transaction and status-only exact CAS.
final class _SupportGuardedMutationStore {
  _SupportGuardedMutationStore(
    this.db,
    SupportPayloadCipher cipher,
    this.sessions,
  ) : checks = _SupportMutationChecks(db, cipher, sessions);
  final AppDatabase db;
  final _SupportSessionStore sessions;
  final _SupportMutationChecks checks;

  Future<T?> _transaction<T>(
    bool Function() current,
    Future<T> Function() work,
  ) async {
    try {
      checks.require(current());
      // Do NOT re-test admission after the durable commit and misreport it as a
      // refusal. Every inner await is guarded; this return is committed custody,
      // not permission to start/publish an external effect on a retired owner.
      return await db.transaction(() async {
        checks.require(current());
        final result = await work();
        checks.require(current());
        return result;
      });
    } on _SupportMutationRefused {
      return null;
    } on SupportCipherException {
      rethrow;
    } catch (_) {
      throw const SupportMutationJournalException();
    }
  }

  Future<SupportMutationJournalRow?> _row(
    String id,
    bool Function() current, {
    String? sessionId,
    String? domain,
    String? targetId,
  }) => checks.checked(
    current,
    () =>
        (db.select(db.supportMutationJournal)..where(
              (t) =>
                  t.id.equals(id) &
                  (sessionId == null
                      ? const Constant(true)
                      : t.sessionId.equals(sessionId)) &
                  (domain == null
                      ? const Constant(true)
                      : t.domain.equals(domain)) &
                  (targetId == null
                      ? const Constant(true)
                      : t.targetId.equals(targetId)),
            ))
            .getSingleOrNull(),
  );

  Future<void> _unchanged(
    SupportSessionRow parent,
    String id,
    SupportMutationJournalRow? row,
    bool Function() current,
  ) async {
    if (row == null) {
      checks.require(await checks.absent(id, current));
    } else {
      checks.require(
        await _row(
              id,
              current,
              sessionId: row.sessionId,
              domain: row.domain,
              targetId: row.targetId,
            ) ==
            row,
      );
    }
    checks.require(current());
    checks.require(
      await checks.checked(current, () => sessions.row(parent.id)) == parent,
    );
  }

  Future<SupportMutationReservation?> reserve(
    SupportMutationRecord record,
    bool Function() current,
  ) => _transaction(current, () async {
    checks.require(checks.record(record) && record.status == 'pending');
    final parent = await checks.parent(record.sessionId, current);
    checks.require(current());
    await _unchanged(parent, record.id, null, current);
    checks.require(current());
    Future<String> encrypt(String text, String field) => checks.checked(
      current,
      () => checks.cipher.encrypt(
        plaintext: text,
        table: 'support_mutation_journal',
        rowId: record.id,
        sessionId: record.sessionId,
        field: field,
      ),
    );
    final before = await encrypt(record.beforeJson, 'before_ciphertext');
    checks.require(current());
    final after = await encrypt(record.afterJson, 'after_ciphertext');
    checks.require(current());
    await _unchanged(parent, record.id, null, current);
    checks.require(current());
    await checks.checked(
      current,
      () => db
          .into(db.supportMutationJournal)
          .insert(
            SupportMutationJournalCompanion(
              id: Value(record.id),
              sessionId: Value(record.sessionId),
              domain: Value(record.domain),
              targetId: Value(record.targetId),
              beforeCiphertext: Value(before),
              afterCiphertext: Value(after),
              status: const Value('pending'),
              createdAt: Value(record.createdAt),
            ),
          ),
    );
    checks.require(current());
    final expected = SupportMutationJournalRow(
      id: record.id,
      sessionId: record.sessionId,
      domain: record.domain,
      targetId: record.targetId,
      beforeCiphertext: before,
      afterCiphertext: after,
      status: record.status,
      createdAt: record.createdAt,
    );
    return _mapped(parent, expected, record, current);
  });

  Future<SupportMutationReservation> _mapped(
    SupportSessionRow parent,
    SupportMutationJournalRow expected,
    SupportMutationRecord record,
    bool Function() current,
  ) async {
    await checks.metadata(expected.id, current);
    checks.require(current());
    final row = await _row(
      expected.id,
      current,
      sessionId: expected.sessionId,
      domain: expected.domain,
      targetId: expected.targetId,
    );
    checks.require(row == expected);
    final durable = await checks.readable(row!, current);
    checks.require(current() && durable == record);
    await _unchanged(parent, expected.id, expected, current);
    checks.require(current());
    return SupportMutationReservation._(durable, row, parent, db);
  }

  Future<SupportMutationReservation?> read(
    String id,
    String sessionId,
    String domain,
    String targetId,
    bool Function() current,
  ) => _transaction(current, () async {
    checks.require([id, sessionId, domain, targetId].every(checks.identifier));
    final parent = await checks.parent(sessionId, current);
    checks.require(current());
    await checks.metadata(id, current);
    checks.require(current());
    final row = await _row(
      id,
      current,
      sessionId: sessionId,
      domain: domain,
      targetId: targetId,
    );
    checks.require(row != null);
    final durable = await checks.readable(row!, current);
    checks.require(current());
    await _unchanged(parent, id, row, current);
    checks.require(current());
    return SupportMutationReservation._(durable, row, parent, db);
  });

  Future<SupportMutationReservation?> beginUndo(
    SupportMutationReservation expected,
    bool Function() current,
  ) => _transition(
    expected,
    SupportMutationStatus.applied,
    SupportMutationStatus.undoPending,
    current,
  );

  Future<SupportMutationReservation?> settle(
    SupportMutationReservation expected,
    SupportMutationFact fact,
    bool Function() custody,
  ) {
    final from = expected.status;
    final to = switch ((from, fact)) {
      (SupportMutationStatus.pending, SupportMutationFact.applied) =>
        SupportMutationStatus.applied,
      (SupportMutationStatus.pending, SupportMutationFact.failed) =>
        SupportMutationStatus.failed,
      (
        SupportMutationStatus.pending,
        SupportMutationFact.reconciliationRequired,
      ) =>
        SupportMutationStatus.reconciliationRequired,
      (SupportMutationStatus.undoPending, SupportMutationFact.undone) =>
        SupportMutationStatus.undone,
      (SupportMutationStatus.undoPending, SupportMutationFact.undoConflict) =>
        SupportMutationStatus.undoConflict,
      (
        SupportMutationStatus.undoPending,
        SupportMutationFact.reconciliationRequired,
      ) =>
        SupportMutationStatus.reconciliationRequired,
      _ => null,
    };
    if (to == null) return Future.value(null);
    return _transition(expected, from, to, custody);
  }

  Future<SupportMutationReservation?> _transition(
    SupportMutationReservation expected,
    SupportMutationStatus from,
    SupportMutationStatus to,
    bool Function() current,
  ) => _transaction(current, () async {
    final record = expected.record;
    checks.require(
      identical(expected._db, db) &&
          checks.record(record) &&
          record.status == from.value,
    );
    final parent = await checks.parent(record.sessionId, current);
    checks.require(
      current() && checks.originalParent(parent, expected._parent),
    );
    await _mapped(parent, expected._row, record, current);
    checks.require(current());
    // Exact encrypted bytes AND all immutable metadata are part of the SQL CAS.
    final count = await checks.checked(
      current,
      () =>
          (db.update(db.supportMutationJournal)..where(
                (t) =>
                    t.id.equals(record.id) &
                    t.sessionId.equals(record.sessionId) &
                    t.domain.equals(record.domain) &
                    t.targetId.equals(record.targetId) &
                    t.status.equals(from.value) &
                    t.createdAt.equals(record.createdAt) &
                    t.beforeCiphertext.equals(expected._row.beforeCiphertext) &
                    t.afterCiphertext.equals(expected._row.afterCiphertext),
              ))
              .write(SupportMutationJournalCompanion(status: Value(to.value))),
    );
    checks.require(current() && count == 1);
    // Read/map/compare inside this same transaction; never manufacture a DTO
    // from an optimistic copyWith if the provisional write or mapping changed.
    return _mapped(
      parent,
      expected._row.copyWith(status: to.value),
      record.copyWith(status: to.value),
      current,
    );
  });

  Future<bool> deleteSession(String id, bool Function() current) async {
    // Unreadable evidence is a known refusal only before the first write.
    // Never classify transaction/commit delivery failures through this helper.
    Future<T> preflight<T>(Future<T> Function() read) async {
      try {
        return await read();
      } on SupportCipherException {
        throw const _SupportMutationRefused();
      }
    }

    final result = await _transaction(current, () async {
      checks.require(checks.identifier(id));
      final parent = await preflight(() => checks.parent(id, current));
      checks.require(current());
      final ids = await checks.checked(
        current,
        () => db
            .customSelect(
              'SELECT id FROM support_mutation_journal WHERE session_id = ?',
              variables: [Variable<String>(id)],
              readsFrom: {db.supportMutationJournal},
            )
            .get(),
      );
      final rows = <SupportMutationJournalRow>[];
      for (final found in ids) {
        final journalId = found.data['id'];
        checks.require(journalId is String && checks.identifier(journalId));
        await checks.metadata(journalId as String, current);
        checks.require(current());
        final row = await _row(journalId, current, sessionId: id);
        checks.require(row != null);
        final originalRow = row!;
        final record = await preflight(
          () => checks.readable(originalRow, current),
        );
        checks.require(current());
        checks.require(!SupportMutationStatus.parse(record.status)!.unresolved);
        rows.add(originalRow);
      }
      for (final row in rows) {
        await _unchanged(parent, row.id, row, current);
        checks.require(current());
      }
      checks.require(
        await checks.checked(current, () => sessions.row(id)) == parent,
      );
      final latest = await checks.checked(
        current,
        () => db
            .customSelect(
              'SELECT id FROM support_mutation_journal WHERE session_id = ?',
              variables: [Variable<String>(id)],
              readsFrom: {db.supportMutationJournal},
            )
            .get(),
      );
      checks.require(
        latest.length == rows.length &&
            latest.every((r) => rows.any((row) => row.id == r.data['id'])),
      );
      await sessions.deleteRows(
        id,
        checkpoint: () => checks.require(current()),
      );
      checks.require(current());
      checks.require(
        await checks.checked(current, () => sessions.row(id)) == null,
      );
      final remaining = await checks.checked(
        current,
        () => db
            .customSelect(
              'SELECT 1 FROM support_mutation_journal WHERE session_id = ? LIMIT 1',
              variables: [Variable<String>(id)],
              readsFrom: {db.supportMutationJournal},
            )
            .get(),
      );
      checks.require(remaining.isEmpty);
      return true;
    });
    // A durable deletion remains true if admission retires after its commit.
    return result ?? false;
  }
}
