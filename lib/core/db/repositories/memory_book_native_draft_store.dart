part of 'memory_book_repo.dart';

/// Native only: neither an observation nor receipt has a public/JSON constructor.
final class MemoryNativeDraftObservation {
  MemoryNativeDraftObservation._(
    this._repo,
    this.sessionId,
    this._raw,
    this._index,
    this._span,
    this.draft,
    this._ticket,
  );
  final MemoryBookRepo _repo;
  final String sessionId, _raw;
  final int _index;
  final _NativeDraftTextSpan _span;
  final MemoryDraft draft;
  final MemoryBookSetupTicket _ticket;
  bool _used = false;
  bool get current => !_used && _ticket.current;
}

final class MemoryNativeDraftReceipt {
  MemoryNativeDraftReceipt._(this._before, this.after, this._journal);
  final MemoryNativeDraftObservation _before;
  final MemoryDraft after;
  final SupportMutationReservation _journal;
  MemoryBookSetupTicket? _ticket;
  bool _used = false;
  String get sessionId => _before.sessionId;
  String get draftId => after.id;
  String get beforeContent => _before.draft.content;
  bool get current => !_used && _ticket?.current == true;
}

/// A genuine delivered Undo fact, not a reconstructed draft or a fresh ticket.
/// Publication uses only the ticket finished by this operation's own admission.
final class MemoryNativeDraftUndoCommit {
  MemoryNativeDraftUndoCommit._(this.after);
  final MemoryDraft after;
  MemoryBookSetupTicket? _ticket;
  bool get current => _ticket?.current == true;
}

final class MemoryNativeDraftStorageException implements Exception {
  const MemoryNativeDraftStorageException();
}

extension MemoryNativeDraftStore on MemoryBookRepo {
  Future<MemoryNativeDraftObservation?> observeNativeDraft({
    required String sessionId,
    required String draftId,
    required bool Function() isCurrent,
  }) async {
    final ticket = captureSetupTicket();
    if (!ticket.current || !isCurrent()) return null;
    final result = await _readNativeDraft(
      sessionId,
      draftId,
      isCurrent,
      ticket,
    );
    return isCurrent() && ticket.current ? result : null;
  }

  Future<MemoryNativeDraftObservation?> _readNativeDraft(
    String session,
    String id,
    bool Function() current,
    MemoryBookSetupTicket ticket,
  ) async {
    if (!current()) return null;
    try {
      final row = await customSelect(
        r'''
        SELECT d.key AS draft_index, d.value AS draft_json,
          b.pending_drafts_json AS drafts_raw
        FROM memory_book_rows b, json_each(b.pending_drafts_json) d
        WHERE b.session_id = ? AND json_extract(d.value, '$.id') = ?
          AND EXISTS (SELECT 1 FROM chat_sessions s WHERE s.session_id = b.session_id)
          AND length(CAST(b.pending_drafts_json AS BLOB)) <= 524288
          AND length(CAST(d.value AS BLOB)) <= 131072
          AND json_type(b.pending_drafts_json) = 'array'
          AND json_array_length(b.pending_drafts_json) <= 128
          AND length(CAST(b.settings_json AS BLOB)) <= 65536
          AND json_type(b.settings_json) = 'object'
          AND (json_type(b.settings_json, '$.vectorSearchEnabled') IS NULL
            OR json_type(b.settings_json, '$.vectorSearchEnabled') = 'false')
          AND (SELECT count(*) FROM json_each(b.pending_drafts_json) x
            WHERE json_extract(x.value, '$.id') = ?) = 1
          AND (SELECT count(*) FROM json_each(b.settings_json)
            WHERE key = 'vectorSearchEnabled') <= 1''',
        variables: [
          Variable.withString(session),
          Variable.withString(id),
          Variable.withString(id),
        ],
        readsFrom: {memoryBookRows},
      ).getSingleOrNull();
      if (!current() || row == null) return null;
      final targetRaw = row.read<String>('draft_json');
      final duplicates = await customSelect(
        r'''SELECT count(*) AS n FROM
          (SELECT parent, key FROM json_tree(?) WHERE key IS NOT NULL
            GROUP BY parent, key HAVING count(*) > 1)''',
        variables: [Variable.withString(targetRaw)],
      ).getSingle();
      // Decoded sibling keys, not serialized path spelling: escaped aliases of
      // the same JSON key must be rejected as duplicates too.
      if (!current() || duplicates.read<int>('n') != 0) return null;
      final map = jsonDecode(targetRaw) as Map<String, dynamic>;
      if (map['content'] is! String ||
          map['status'] != 'pending_approval' ||
          (map['vectorSearch'] != null && map['vectorSearch'] != false))
        return null;
      final draft = MemoryDraft.fromJson(map);
      if (draft.id != id ||
          draft.vectorSearch ||
          draft.content.length > 8192 ||
          const {'agentic', 'studio_ledger'}.contains(draft.source))
        return null;
      final raw = row.read<String>('drafts_raw');
      // Validate before scanning; do not re-encode this array or its objects.
      if (jsonDecode(raw) is! List) return null;
      final index = row.read<int>('draft_index');
      final span = _NativeDraftTextSpan.locate(raw, index);
      if (span == null ||
          jsonDecode(raw.substring(span.start, span.end)) != draft.content ||
          utf8.encode(raw.substring(span.objectStart, span.objectEnd)).length >
              131072)
        return null;
      return MemoryNativeDraftObservation._(
        this,
        session,
        raw,
        index,
        span,
        draft,
        ticket,
      );
    } catch (_) {
      return null;
    }
  }

  bool _sameNativeDraft(
    MemoryNativeDraftObservation a,
    MemoryNativeDraftObservation? b,
  ) =>
      b != null &&
      identical(a._repo, this) &&
      identical(b._repo, this) &&
      a.sessionId == b.sessionId &&
      a._index == b._index &&
      a._raw == b._raw;

  String _nativeDraftTarget(MemoryNativeDraftObservation before) =>
      'memory-draft-${sha256.convert(utf8.encode(jsonEncode([before.sessionId, before.draft.id])))}';

  String? _nativeDraftEvidence(
    MemoryNativeDraftObservation before,
    String content,
  ) {
    final native = jsonEncode({
      'v': 1,
      'session': before.sessionId,
      'draft': before.draft.id,
      'content': content,
    });
    if (native.length > SupportMutationEvidence.maxNativeBytes ||
        utf8.encode(native).length > SupportMutationEvidence.maxNativeBytes)
      return null;
    return SupportMutationEvidence.encode(native);
  }

  bool _nativeDraftRoom(MemoryNativeDraftObservation before, String content) {
    final raw = before._span.replace(before._raw, content);
    // Both actual Apply and prospective Undo states must fit before reserving IO.
    if (utf8.encode(raw).length > 524288) return false;
    final target =
        before._raw.substring(before._span.objectStart, before._span.start) +
        jsonEncode(content) +
        before._raw.substring(before._span.end, before._span.objectEnd);
    return utf8.encode(target).length <= 131072;
  }

  Future<MemoryDraft> _writeNativeDraft(
    MemoryNativeDraftObservation before,
    String content,
    bool Function() current,
  ) async {
    void check(bool value) {
      if (!value || !current()) throw const _MemoryBookControlRetired();
    }

    check(
      content.length <= 8192 &&
          content != before.draft.content &&
          _nativeDraftRoom(before, content),
    );
    final raw = before._span.replace(before._raw, content);
    final count = await customUpdate(
      '''UPDATE memory_book_rows SET pending_drafts_json = ?
      WHERE session_id = ? AND pending_drafts_json = ?''',
      variables: [
        Variable.withString(raw),
        Variable.withString(before.sessionId),
        Variable.withString(before._raw),
      ],
      updates: {memoryBookRows},
    );
    check(count == 1);
    final verified = await _readNativeDraft(
      before.sessionId,
      before.draft.id,
      current,
      before._ticket,
    );
    final next = before.draft.copyWith(content: content);
    check(verified != null && verified._raw == raw && verified.draft == next);
    return next;
  }

  Future<MemoryNativeDraftReceipt?> reviseNativeDraft({
    required MemoryNativeDraftObservation observed,
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
    MemoryNativeDraftReceipt? committed;
    try {
      committed = await outsideDatabaseTransaction(
        attachedDatabase,
        () => attachedDatabase.runWithInterceptor(
          () => attachedDatabase.transaction(() async {
            void check(bool value) {
              if (!value || !current()) throw const _MemoryBookControlRetired();
            }

            check(content.length <= 8192 && content != observed.draft.content);
            final latest = await _readNativeDraft(
              observed.sessionId,
              observed.draft.id,
              current,
              observed._ticket,
            );
            check(_sameNativeDraft(observed, latest));
            final before = _nativeDraftEvidence(
              observed,
              observed.draft.content,
            );
            final after = _nativeDraftEvidence(observed, content);
            check(
              before != null &&
                  after != null &&
                  _nativeDraftRoom(observed, content) &&
                  _nativeDraftRoom(observed, observed.draft.content),
            );
            final reserved = await support.reserveMutation(
              record: SupportMutationRecord(
                id: operationId,
                sessionId: parentSession,
                domain: 'memory.draft.text',
                targetId: _nativeDraftTarget(observed),
                beforeJson: before!,
                afterJson: after!,
                status: 'pending',
                createdAt: currentTimestampSeconds(),
              ),
              isCurrent: current,
            );
            check(reserved != null);
            final next = await _writeNativeDraft(observed, content, current);
            check(true);
            final settled = await support.settleMutation(
              expected: reserved!,
              fact: SupportMutationFact.applied,
              hasOriginalDbCustody: current,
            );
            check(settled != null);
            final durable = await _readNativeDraft(
              observed.sessionId,
              observed.draft.id,
              current,
              observed._ticket,
            );
            check(
              durable != null &&
                  durable.draft == next &&
                  durable._raw ==
                      observed._span.replace(observed._raw, content),
            );
            return MemoryNativeDraftReceipt._(observed, next, settled!);
          }),
          interceptor: _NativeDraftCommitGuard(current),
        ),
        onRejected: () => const _MemoryBookControlRetired(),
      );
      // A delivered commit is a durable fact, even if publication has retired.
      return committed;
    } on _MemoryBookControlRetired {
      return null;
    } catch (_) {
      throw const MemoryNativeDraftStorageException();
    } finally {
      final ticket = admission.finish();
      committed?._ticket = ticket;
    }
  }

  Future<MemoryNativeDraftUndoCommit?> undoNativeDraft({
    required MemoryNativeDraftReceipt receipt,
    required MemoryNativeDraftObservation observed,
    required SupportRepo support,
    required String parentSession,
    required bool Function() isCurrent,
  }) async {
    if (!identical(receipt._before._repo, this) ||
        !identical(observed._repo, this) ||
        !receipt.current ||
        !observed.current ||
        observed.draft != receipt.after ||
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
    MemoryNativeDraftUndoCommit? committed;
    try {
      committed = await outsideDatabaseTransaction(
        attachedDatabase,
        () => attachedDatabase.runWithInterceptor(
          () => attachedDatabase.transaction(() async {
            void check(bool value) {
              if (!value || !current()) throw const _MemoryBookControlRetired();
            }

            final latest = await _readNativeDraft(
              observed.sessionId,
              observed.draft.id,
              current,
              observed._ticket,
            );
            check(_sameNativeDraft(observed, latest));
            check(
              _nativeDraftRoom(observed, receipt.beforeContent) &&
                  _nativeDraftEvidence(observed, receipt.beforeContent) != null,
            );
            final reserved = await support.reserveMutationUndo(
              expected: receipt._journal,
              isCurrent: current,
            );
            check(reserved != null);
            final next = await _writeNativeDraft(
              observed,
              receipt.beforeContent,
              current,
            );
            check(true);
            final settled = await support.settleMutation(
              expected: reserved!,
              fact: SupportMutationFact.undone,
              hasOriginalDbCustody: current,
            );
            check(settled != null);
            final durable = await _readNativeDraft(
              observed.sessionId,
              observed.draft.id,
              current,
              observed._ticket,
            );
            check(
              durable != null &&
                  durable.draft == next &&
                  durable._raw ==
                      observed._span.replace(
                        observed._raw,
                        receipt.beforeContent,
                      ),
            );
            return MemoryNativeDraftUndoCommit._(next);
          }),
          interceptor: _NativeDraftCommitGuard(current),
        ),
        onRejected: () => const _MemoryBookControlRetired(),
      );
      // Preserve a delivered fact even when a later ordinary writer retired us.
      return committed;
    } on _MemoryBookControlRetired {
      return null;
    } catch (_) {
      throw const MemoryNativeDraftStorageException();
    } finally {
      final ticket = admission.finish();
      committed?._ticket = ticket;
    }
  }
}

/// Original guard includes current metadata policy, not just a redactor snapshot.
/// Check immediately around SQL and immediately before the real COMMIT send.
final class _NativeDraftCommitGuard extends QueryInterceptor {
  _NativeDraftCommitGuard(this.current);
  final bool Function() current;
  void check() {
    if (!current()) throw const _MemoryBookControlRetired();
  }

  @override
  Future<bool> ensureOpen(
    QueryExecutor executor,
    QueryExecutorUser user,
  ) async {
    check();
    final opened = await super.ensureOpen(executor, user);
    check();
    return opened;
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    check();
    final rows = await super.runSelect(executor, statement, args);
    check();
    return rows;
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    check();
    final count = await super.runInsert(executor, statement, args);
    check();
    return count;
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    check();
    final count = await super.runUpdate(executor, statement, args);
    check();
    return count;
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) async {
    check();
    await super.commitTransaction(inner);
    // Never turn an actually delivered commit into a fictitious rolled-back fact.
  }
}
