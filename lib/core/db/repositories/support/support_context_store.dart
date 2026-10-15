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
        final summary = await cipher.encrypt(
          plaintext: block.summary,
          table: 'support_context_blocks',
          rowId: block.id,
          sessionId: block.sessionId,
          field: 'summary_ciphertext',
        );
        final facts = block.protectedFactsJson.isEmpty
            ? ''
            : await cipher.encrypt(
                plaintext: block.protectedFactsJson,
                table: 'support_context_blocks',
                rowId: block.id,
                sessionId: block.sessionId,
                field: 'protected_facts_ciphertext',
              );
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
        return mapper.context((await row(block.id))!);
      });
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
