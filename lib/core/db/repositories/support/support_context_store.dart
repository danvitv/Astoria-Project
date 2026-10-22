part of '../support_repo.dart';

final class _SupportContextStore {
  _SupportContextStore(this.db, this.cipher, this.mapper, this.sessions);
  final AppDatabase db;
  final SupportPayloadCipher cipher;
  final _SupportRowMapper mapper;
  final _SupportSessionStore sessions;
  Future<SupportContextBlockRow?> row(String id) => (db.select(
    db.supportContextBlocks,
  )..where((t) => t.id.equals(id))).getSingleOrNull();
  Future<SupportContextBlock> put(SupportContextBlock block) =>
      db.transaction(() async {
        _requireUnlocked(block.isLocked);
        await sessions.requireParent(block.sessionId);
        final existing = await row(block.id);
        if (existing != null) {
          _requireSameSession(existing.sessionId, block.sessionId);
          _requireUnlocked((await mapper.context(existing)).isLocked);
        }
        return write(block);
      });

  Future<SupportContextBlock?> mutate(
    String id,
    String sessionId,
    SupportContextBlock? Function(SupportContextBlock? latest) mutate,
    bool Function()? isCurrent,
  ) => db.transaction(() async {
    if (isCurrent?.call() == false) return null;
    await sessions.requireParent(sessionId);
    if (isCurrent?.call() == false) return null;
    final existing = await row(id);
    SupportContextBlock? latest;
    if (existing != null) {
      _requireSameSession(existing.sessionId, sessionId);
      latest = await mapper.context(existing);
      _requireUnlocked(latest.isLocked);
    }
    if (isCurrent?.call() == false) return null;
    final next = mutate(latest);
    if (next == null || isCurrent?.call() == false) return null;
    if (next.id != id) throw StateError('Support context identity changed.');
    _requireSameSession(next.sessionId, sessionId);
    _requireUnlocked(next.isLocked);
    return write(next, isCurrent: isCurrent, requireReadableResult: true);
  });

  /// Caller owns the transaction. Recheck ownership after encryption and after
  /// result mapping; throwing rolls back any provisional write, never history.
  Future<SupportContextBlock> write(
    SupportContextBlock block, {
    bool Function()? isCurrent,
    bool requireReadableResult = false,
  }) async {
    void requireCurrent() {
      if (isCurrent?.call() == false) {
        throw StateError('Support context operation is no longer current.');
      }
    }

    final summary = await cipher.encrypt(
      plaintext: block.summary,
      table: 'support_context_blocks',
      rowId: block.id,
      sessionId: block.sessionId,
      field: 'summary_ciphertext',
    );
    requireCurrent();
    final facts = block.protectedFactsJson.isEmpty
        ? ''
        : await cipher.encrypt(
            plaintext: block.protectedFactsJson,
            table: 'support_context_blocks',
            rowId: block.id,
            sessionId: block.sessionId,
            field: 'protected_facts_ciphertext',
          );
    requireCurrent();
    await db
        .into(db.supportContextBlocks)
        .insertOnConflictUpdate(
          SupportContextBlocksCompanion(
            id: Value(block.id),
            sessionId: Value(block.sessionId),
            startMessageId: Value(block.startMessageId),
            endMessageId: Value(block.endMessageId),
            summaryCiphertext: Value(summary),
            protectedFactsCiphertext: Value(facts),
            isActive: Value(block.isActive),
            createdAt: Value(block.createdAt),
          ),
        );
    requireCurrent();
    final durable = await mapper.context((await row(block.id))!);
    if (requireReadableResult) _requireUnlocked(durable.isLocked);
    requireCurrent();
    return durable;
  }

  Future<SupportContextBlock?> get(String id) async {
    final found = await row(id);
    return found == null ? null : mapper.context(found);
  }

  Future<List<SupportContextBlock>> all(
    String sessionId, {
    bool activeOnly = false,
  }) async {
    final rows =
        await (db.select(db.supportContextBlocks)
              ..where(
                (t) => activeOnly
                    ? t.sessionId.equals(sessionId) & t.isActive.equals(true)
                    : t.sessionId.equals(sessionId),
              )
              ..orderBy([
                (t) => OrderingTerm.asc(t.createdAt),
                (t) => OrderingTerm.asc(t.id),
              ]))
            .get();
    final result = <SupportContextBlock>[];
    for (final row in rows) {
      result.add(await mapper.context(row));
    }
    return result;
  }

  Future<void> deactivate(String id) => db.transaction(() async {
    final existing = await row(id);
    if (existing == null) return;
    await sessions.requireParent(existing.sessionId, unlocked: false);
    await (db.update(db.supportContextBlocks)..where((t) => t.id.equals(id)))
        .write(const SupportContextBlocksCompanion(isActive: Value(false)));
  });
}
