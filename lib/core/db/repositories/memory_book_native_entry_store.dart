part of 'memory_book_repo.dart';

/// Native observations and receipts have no public or JSON constructor.
final class MemoryNativeEntryObservation {
  MemoryNativeEntryObservation._(
    this._repo,
    this.sessionId,
    this._index,
    this._raw,
    this.entry,
    this._ticket,
  );
  final MemoryBookRepo _repo;
  final String sessionId, _raw;
  final int _index;
  final MemoryEntry entry;
  final MemoryBookSetupTicket _ticket;
  bool _used = false;
  bool get current => !_used && _ticket.current;
}

final class MemoryNativeEntryReceipt {
  MemoryNativeEntryReceipt._(this._before, this.after, this._journal);
  final MemoryNativeEntryObservation _before;
  final MemoryEntry after;
  final SupportMutationReservation _journal;
  MemoryBookSetupTicket? _ticket;
  bool _used = false;
  String get sessionId => _before.sessionId;
  String get entryId => after.id;
  String get beforeContent => _before.entry.content;
  bool get current => !_used && _ticket?.current == true;
}

final class MemoryNativeEntryStorageException implements Exception {
  const MemoryNativeEntryStorageException();
}

extension MemoryNativeEntryStore on MemoryBookRepo {
  /// SQLite projects only one approved entry in an already finite book. Drafts,
  /// unrelated entries and settings payloads are never returned through this port.
  Future<MemoryNativeEntryObservation?> observeNativeEntry({
    required String sessionId,
    required String entryId,
    required bool Function() isCurrent,
  }) async {
    final ticket = captureSetupTicket();
    if (!ticket.current || !isCurrent()) return null;
    final result = await _readNativeEntry(
      sessionId,
      entryId,
      isCurrent,
      ticket,
    );
    return isCurrent() && ticket.current ? result : null;
  }

  Future<MemoryNativeEntryObservation?> _readNativeEntry(
    String sessionId,
    String entryId,
    bool Function() current,
    MemoryBookSetupTicket ticket,
  ) async {
    if (!current()) return null;
    try {
      final row = await customSelect(
        r'''
        SELECT e.key AS entry_index, e.value AS entry_json
        FROM memory_book_rows b, json_each(b.entries_json) e
        WHERE b.session_id = ? AND json_extract(e.value, '$.id') = ?
          AND EXISTS (SELECT 1 FROM chat_sessions s WHERE s.session_id = b.session_id)
          AND length(CAST(b.entries_json AS BLOB)) <= 524288
          AND length(CAST(e.value AS BLOB)) <= 131072
          AND json_array_length(b.entries_json) <= 128
          AND json_type(b.entries_json) = 'array'
          AND length(CAST(b.settings_json AS BLOB)) <= 65536
          AND json_type(b.settings_json) = 'object'
          AND (json_type(b.settings_json, '$.vectorSearchEnabled') IS NULL
            OR json_type(b.settings_json, '$.vectorSearchEnabled') = 'false')
          AND (SELECT count(*) FROM json_each(b.entries_json) x
            WHERE json_extract(x.value, '$.id') = ?) = 1
          AND (SELECT count(*) FROM json_each(b.settings_json)
            WHERE key = 'vectorSearchEnabled') <= 1''',
        variables: [
          Variable.withString(sessionId),
          Variable.withString(entryId),
          Variable.withString(entryId),
        ],
        readsFrom: {memoryBookRows},
      ).getSingleOrNull();
      if (!current() || row == null) return null;
      final raw = row.read<String>('entry_json');
      if (raw.length > 131072) return null;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      // Reject ambiguous duplicate object keys instead of normalizing authority.
      final duplicates = await customSelect(
        r'''
        SELECT count(*) AS n FROM
          (SELECT fullkey FROM json_tree(?) GROUP BY fullkey HAVING count(*) > 1)''',
        variables: [Variable.withString(raw)],
      ).getSingle();
      if (!current() || duplicates.read<int>('n') != 0) return null;
      if (map['content'] is! String || map['title'] is! String) return null;
      final entry = MemoryEntry.fromJson(map);
      if (entry.id != entryId ||
          entry.status != 'active' ||
          entry.locked ||
          const {'agentic', 'studio_ledger'}.contains(entry.source) ||
          entry.vectorSearch ||
          entry.content.length > 8192 ||
          entry.revisions.length > 32 ||
          !MemoryEntryRevisions.isUsable(entry))
        return null;
      return MemoryNativeEntryObservation._(
        this,
        sessionId,
        row.read<int>('entry_index'),
        raw,
        entry,
        ticket,
      );
    } catch (_) {
      return null;
    }
  }

  bool _sameNativeEntry(
    MemoryNativeEntryObservation a,
    MemoryNativeEntryObservation? b,
  ) =>
      b != null &&
      identical(a._repo, this) &&
      identical(b._repo, this) &&
      a.sessionId == b.sessionId &&
      a._index == b._index &&
      a._raw == b._raw;

  String _nativeEntryTarget(MemoryNativeEntryObservation observed) {
    // A canonical pair avoids delimiter ambiguity without truncating either ID.
    // The exact IDs remain in private observation/receipt and encrypted evidence.
    final pair = jsonEncode([observed.sessionId, observed.entry.id]);
    return 'memory-entry-${sha256.convert(utf8.encode(pair))}';
  }

  String? _nativeEntryEvidence(
    MemoryNativeEntryObservation before,
    MemoryEntry after,
  ) {
    final native = jsonEncode({
      'v': 1,
      'session': before.sessionId,
      'entry': after.id,
      'revision': after.activeRevisionId,
      'content': after.content,
    });
    // The content's UTF-16 limit does not bound UTF-8 JSON, its escaping or
    // identifiers. Oversized originals/proposals are a refusal, not uncertain IO.
    if (native.length > SupportMutationEvidence.maxNativeBytes ||
        utf8.encode(native).length > SupportMutationEvidence.maxNativeBytes) {
      return null;
    }
    return SupportMutationEvidence.encode(native);
  }

  String _nativeRevisionRaw(String beforeRaw, MemoryEntry next) {
    final raw = Map<String, dynamic>.from(jsonDecode(beforeRaw) as Map);
    // Preserve unknown fields and historical revision objects, including source
    // manifests. Only content, active pointer and newly appended history change.
    final history = raw['revisions'] == null
        ? <dynamic>[]
        : List<dynamic>.from(raw['revisions'] as List);
    for (final revision in next.revisions.skip(history.length)) {
      history.add(revision.toJson());
    }
    raw['content'] = next.content;
    raw['activeRevisionId'] = next.activeRevisionId;
    raw['revisions'] = history;
    return jsonEncode(raw);
  }

  /// Reserve both serialized states without returning any unrelated book text.
  /// The prospective Undo's timestamps reserve the full signed safe integer width;
  /// the real Undo still appends its own fresh timestamp and never edits history.
  Future<bool> _nativeEntryRoom(
    MemoryNativeEntryObservation before,
    String proposedRaw,
    String undoRaw,
    bool Function() current,
  ) async {
    if (!current()) return false;
    final row = await customSelect(
      '''
      SELECT 1 AS room FROM memory_book_rows
      WHERE session_id = ?
        AND json_extract(entries_json, '\$[${before._index}]') = ?
        AND length(CAST(? AS BLOB)) <= 131072
        AND length(CAST(? AS BLOB)) <= 131072
        AND length(CAST(json_set(entries_json, '\$[${before._index}]',
          json(?)) AS BLOB)) <= 524288
        AND length(CAST(json_set(entries_json, '\$[${before._index}]',
          json(?)) AS BLOB)) <= 524288''',
      variables: [
        Variable.withString(before.sessionId),
        Variable.withString(before._raw),
        Variable.withString(proposedRaw),
        Variable.withString(undoRaw),
        Variable.withString(proposedRaw),
        Variable.withString(undoRaw),
      ],
      readsFrom: {memoryBookRows},
    ).getSingleOrNull();
    return current() && row != null;
  }

  Future<MemoryEntry?> _writeNativeEntry(
    MemoryNativeEntryObservation before,
    MemoryEntry next,
    String nextRaw,
    bool Function() current,
  ) async {
    void check(bool value) {
      if (!value || !current()) throw const _MemoryBookControlRetired();
    }

    check(
      next.content.length <= 8192 &&
          next.content != before.entry.content &&
          next.revisions.length <= 32,
    );
    check(await _nativeEntryRoom(before, nextRaw, nextRaw, current));
    final count = await customUpdate(
      '''
      UPDATE memory_book_rows SET
        entries_json = json_set(entries_json, '\$[${before._index}]', json(?)),
        updated_at = ?
      WHERE session_id = ?
        AND json_extract(entries_json, '\$[${before._index}]') = ?''',
      variables: [
        Variable.withString(nextRaw),
        Variable.withInt(currentTimestampSeconds()),
        Variable.withString(before.sessionId),
        Variable.withString(before._raw),
      ],
      updates: {memoryBookRows},
    );
    check(count == 1);
    final verified = await _readNativeEntry(
      before.sessionId,
      before.entry.id,
      current,
      before._ticket,
    );
    check(verified != null && verified.entry == next);
    return next;
  }

  Future<MemoryNativeEntryReceipt?> reviseNativeEntry({
    required MemoryNativeEntryObservation observed,
    required String content,
    required SupportRepo support,
    required String parentSession,
    required String operationId,
    required bool Function() isCurrent,
  }) async {
    if (!identical(observed._repo, this) ||
        !observed.current ||
        !support.usesDatabase(attachedDatabase) ||
        !isCurrent())
      return null;
    final admission = _beginSetupBookWrite(observed._ticket);
    if (admission == null) return null;
    observed._used = true;
    bool current() => isCurrent() && admission.current;
    MemoryNativeEntryReceipt? committed;
    try {
      committed = await outsideDatabaseTransaction(
        attachedDatabase,
        () => transaction(() async {
          void check(bool value) {
            if (!value || !current()) throw const _MemoryBookControlRetired();
          }

          check(
            content.length <= 8192 &&
                content != observed.entry.content &&
                observed.entry.revisions.length < 31,
          );
          final latest = await _readNativeEntry(
            observed.sessionId,
            observed.entry.id,
            current,
            observed._ticket,
          );
          check(_sameNativeEntry(observed, latest));
          final next = MemoryEntryRevisions.prepare(
            observed.entry.copyWith(content: content),
            observed.entry,
            author: 'user',
            reviewer: 'user',
            reason: 'assistant_text_edit',
          );
          // Preflight BOTH exact evidence states before any journal reservation
          // or entry write. Null follows the existing defined no-effect refusal.
          final beforeEvidence = _nativeEntryEvidence(observed, observed.entry);
          final afterEvidence = _nativeEntryEvidence(observed, next);
          check(beforeEvidence != null && afterEvidence != null);
          final nextRaw = _nativeRevisionRaw(observed._raw, next);
          final predictedUndo = MemoryEntryRevisions.prepare(
            next.copyWith(content: observed.entry.content),
            next,
            author: 'user',
            reviewer: 'user',
            reason: 'assistant_text_undo',
          );
          final undoMap =
              jsonDecode(_nativeRevisionRaw(nextRaw, predictedUndo))
                  as Map<String, dynamic>;
          final undoRevision = (undoMap['revisions'] as List).last as Map;
          undoRevision['createdAt'] = -9007199254740991;
          undoRevision['reviewedAt'] = -9007199254740991;
          check(
            next.revisions.length < 32 && predictedUndo.revisions.length <= 32,
          );
          check(
            await _nativeEntryRoom(
              observed,
              nextRaw,
              jsonEncode(undoMap),
              current,
            ),
          );
          final pending = await support.reserveMutation(
            record: SupportMutationRecord(
              id: operationId,
              sessionId: parentSession,
              domain: 'memory.entry.text',
              targetId: _nativeEntryTarget(observed),
              beforeJson: beforeEvidence!,
              afterJson: afterEvidence!,
              status: 'pending',
              createdAt: currentTimestampSeconds(),
            ),
            isCurrent: current,
          );
          check(pending != null);
          final revised = await _writeNativeEntry(
            observed,
            next,
            nextRaw,
            current,
          );
          check(revised != null);
          final settled = await support.settleMutation(
            expected: pending!,
            fact: SupportMutationFact.applied,
            hasOriginalDbCustody: current,
          );
          check(settled != null);
          final durable = await _readNativeEntry(
            observed.sessionId,
            observed.entry.id,
            current,
            observed._ticket,
          );
          check(durable != null && durable.entry == revised);
          return MemoryNativeEntryReceipt._(observed, revised!, settled!);
        }),
        onRejected: () => const _MemoryBookControlRetired(),
      );
      return committed;
    } on _MemoryBookControlRetired {
      return null;
    } catch (_) {
      throw const MemoryNativeEntryStorageException();
    } finally {
      final ticket = admission.finish();
      committed?._ticket = ticket;
    }
  }

  Future<MemoryEntry?> undoNativeEntry({
    required MemoryNativeEntryReceipt receipt,
    required MemoryNativeEntryObservation observed,
    required SupportRepo support,
    required String parentSession,
    required bool Function() isCurrent,
  }) async {
    if (!identical(receipt._before._repo, this) ||
        !identical(observed._repo, this) ||
        !receipt.current ||
        !observed.current ||
        observed.entry != receipt.after ||
        observed.sessionId != receipt.sessionId ||
        receipt._journal.record.sessionId != parentSession ||
        !support.usesDatabase(attachedDatabase) ||
        !isCurrent())
      return null;
    final admission = _beginSetupBookWrite(receipt._ticket!);
    if (admission == null) return null;
    receipt._used = true;
    observed._used = true;
    bool current() => isCurrent() && admission.current;
    try {
      return await outsideDatabaseTransaction(
        attachedDatabase,
        () => transaction(() async {
          void check(bool value) {
            if (!value || !current()) throw const _MemoryBookControlRetired();
          }

          final latest = await _readNativeEntry(
            observed.sessionId,
            observed.entry.id,
            current,
            observed._ticket,
          );
          check(_sameNativeEntry(observed, latest));
          final next = MemoryEntryRevisions.prepare(
            observed.entry.copyWith(content: receipt.beforeContent),
            observed.entry,
            author: 'user',
            reviewer: 'user',
            reason: 'assistant_text_undo',
          );
          final nextRaw = _nativeRevisionRaw(observed._raw, next);
          final reserved = await support.reserveMutationUndo(
            expected: receipt._journal,
            isCurrent: current,
          );
          check(reserved != null);
          final restored = await _writeNativeEntry(
            observed,
            next,
            nextRaw,
            current,
          );
          check(restored != null);
          final settled = await support.settleMutation(
            expected: reserved!,
            fact: SupportMutationFact.undone,
            hasOriginalDbCustody: current,
          );
          check(settled != null);
          final durable = await _readNativeEntry(
            observed.sessionId,
            observed.entry.id,
            current,
            observed._ticket,
          );
          check(durable != null && durable.entry == restored);
          return restored;
        }),
        onRejected: () => const _MemoryBookControlRetired(),
      );
    } on _MemoryBookControlRetired {
      return null;
    } catch (_) {
      throw const MemoryNativeEntryStorageException();
    } finally {
      admission.finish();
    }
  }
}
