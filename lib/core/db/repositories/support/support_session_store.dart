part of '../support_repo.dart';

final class _SupportSessionStore {
  _SupportSessionStore(this.db, this.cipher, this.mapper);
  final AppDatabase db;
  final SupportPayloadCipher cipher;
  final _SupportRowMapper mapper;
  Future<SupportSessionRow?> row(String id) => (db.select(
    db.supportSessions,
  )..where((t) => t.id.equals(id))).getSingleOrNull();

  /// Call only inside the transaction that performs the child write.
  Future<SupportSessionRow> requireParent(
    String id, {
    bool unlocked = true,
  }) async {
    final parent = await row(id);
    if (parent == null) throw StateError('Support session is missing.');
    if (unlocked) _requireUnlocked((await mapper.session(parent)).isLocked);
    return parent;
  }

  Future<SupportSession> put(
    SupportSession session, {
    bool createOnly = false,
  }) => db.transaction(() async {
    _requireUnlocked(session.isLocked);
    final existing = await row(session.id);
    if (existing != null) {
      if (createOnly) throw StateError('Support session already exists.');
      _requireUnlocked((await mapper.session(existing)).isLocked);
    }
    final title = await cipher.encrypt(
      plaintext: session.title,
      table: 'support_sessions',
      rowId: session.id,
      sessionId: session.id,
      field: 'title_ciphertext',
    );
    await db
        .into(db.supportSessions)
        .insertOnConflictUpdate(
          SupportSessionsCompanion(
            id: Value(session.id),
            titleCiphertext: Value(title),
            createdAt: Value(session.createdAt),
            updatedAt: Value(session.updatedAt),
            pinned: Value(session.pinned),
            mode: Value(session.mode),
            activeApiConfigId: Value(session.activeApiConfigId),
            activeModelId: Value(session.activeModelId),
          ),
        );
    return mapper.session((await row(session.id))!);
  });
  Future<SupportSession?> get(String id) async {
    final found = await row(id);
    return found == null ? null : mapper.session(found);
  }

  SimpleSelectStatement<$SupportSessionsTable, SupportSessionRow> _query() =>
      db.select(db.supportSessions)..orderBy([
        (t) => OrderingTerm.desc(t.pinned),
        (t) => OrderingTerm.desc(t.updatedAt),
        (t) => OrderingTerm.desc(t.createdAt),
        (t) => OrderingTerm.asc(t.id),
      ]);
  Future<List<SupportSession>> _map(List<SupportSessionRow> rows) async {
    final result = <SupportSession>[];
    for (final row in rows) {
      result.add(await mapper.session(row));
    }
    return result;
  }

  Future<List<SupportSession>> all() async => _map(await _query().get());
  Stream<List<SupportSession>> watch() => _query().watch().asyncMap(_map);
  Future<SupportSession?> rename(String id, String title, int? updatedAt) =>
      db.transaction(() async {
        final existing = await row(id);
        if (existing == null) return null;
        _requireUnlocked((await mapper.session(existing)).isLocked);
        final encrypted = await cipher.encrypt(
          plaintext: title,
          table: 'support_sessions',
          rowId: id,
          sessionId: id,
          field: 'title_ciphertext',
        );
        await (db.update(
          db.supportSessions,
        )..where((t) => t.id.equals(id))).write(
          SupportSessionsCompanion(
            titleCiphertext: Value(encrypted),
            updatedAt: Value(updatedAt ?? existing.updatedAt),
          ),
        );
        return mapper.session((await row(id))!);
      });
  Future<SupportSession?> updateMetadata({
    required String sessionId,
    bool? pinned,
    String? mode,
    String? activeApiConfigId,
    bool clearActiveApiConfigId = false,
    String? activeModelId,
    bool clearActiveModelId = false,
    int? updatedAt,
  }) => db.transaction(() async {
    if (await row(sessionId) == null) return null;
    // Metadata remains editable on locked sessions; never replace ciphertext.
    await (db.update(
      db.supportSessions,
    )..where((t) => t.id.equals(sessionId))).write(
      SupportSessionsCompanion(
        pinned: pinned != null ? Value(pinned) : const Value.absent(),
        mode: mode != null ? Value(mode) : const Value.absent(),
        activeApiConfigId: clearActiveApiConfigId
            ? const Value(null)
            : activeApiConfigId != null
            ? Value(activeApiConfigId)
            : const Value.absent(),
        activeModelId: clearActiveModelId
            ? const Value(null)
            : activeModelId != null
            ? Value(activeModelId)
            : const Value.absent(),
        updatedAt: updatedAt != null ? Value(updatedAt) : const Value.absent(),
      ),
    );
    return mapper.session((await row(sessionId))!);
  });
  Future<void> delete(String id) => db.transaction(() => deleteRows(id));

  /// DB-only existing cascade; guarded deletion calls this in its OWN transaction.
  Future<void> deleteRows(String id, {void Function()? checkpoint}) async {
    checkpoint?.call();
    await (db.delete(
      db.supportMessages,
    )..where((t) => t.sessionId.equals(id))).go();
    checkpoint?.call();
    await (db.delete(
      db.supportContextBlocks,
    )..where((t) => t.sessionId.equals(id))).go();
    checkpoint?.call();
    await (db.delete(
      db.supportMutationJournal,
    )..where((t) => t.sessionId.equals(id))).go();
    checkpoint?.call();
    await (db.delete(
      db.supportReports,
    )..where((t) => t.sessionId.equals(id))).go();
    checkpoint?.call();
    await (db.delete(db.supportSessions)..where((t) => t.id.equals(id))).go();
    checkpoint?.call();
  }
}

void _requireUnlocked(bool locked) {
  if (locked) {
    throw const SupportCipherException(
      SupportCipherFailure.authenticationFailed,
    );
  }
}

void _requireSameSession(String existing, String requested) {
  if (existing != requested) {
    throw StateError('Support row belongs to another session.');
  }
}
