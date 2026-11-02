part of 'memory_book_repo.dart';

/// Exact removal capsule. Raw unknown fields never leave this repository part.
final class MemoryNativeDraftRemovalObservation {
  MemoryNativeDraftRemovalObservation._(
    this._before,
    this._start,
    this._end,
    this._afterRaw,
    this._beforeEvidence,
    this._afterEvidence,
  );
  final MemoryNativeDraftObservation _before;
  final int _start, _end;
  final String _afterRaw, _beforeEvidence, _afterEvidence;
  bool _used = false;
  MemoryDraft get draft => _before.draft;
  String get sessionId => _before.sessionId;
  int get index => _before._index;
  bool get current => !_used && _before.current;
}

final class MemoryNativeDraftRemovalReceipt {
  MemoryNativeDraftRemovalReceipt._(this._before, this._journal);
  final MemoryNativeDraftRemovalObservation _before;
  final SupportMutationReservation _journal;
  MemoryBookSetupTicket? _ticket;
  bool _used = false;
  String get sessionId => _before.sessionId;
  MemoryDraft get draft => _before.draft;
  int get index => _before.index;
  bool get current => !_used && _ticket?.current == true;
}

/// A fresh private observation of ABSENCE, not a guessed deleted ID or DTO.
final class MemoryNativeDraftRemovalUndoObservation {
  MemoryNativeDraftRemovalUndoObservation._(
    this._repo,
    this._receipt,
    this._raw,
    this._ticket,
    this.drafts,
  );
  final MemoryBookRepo _repo;
  final MemoryNativeDraftRemovalReceipt _receipt;
  final String _raw;
  final MemoryBookSetupTicket _ticket;
  final List<MemoryDraft> drafts;
  bool _used = false;
  bool get current => !_used && _ticket.current && _receipt.current;
}

final class MemoryNativeDraftRemovalUndoCommit {
  MemoryNativeDraftRemovalUndoCommit._(this.draft, this.index);
  final MemoryDraft draft;
  final int index;
  MemoryBookSetupTicket? _ticket;
  bool get current => _ticket?.current == true;
}

extension MemoryNativeDraftRemovalStore on MemoryBookRepo {
  Future<MemoryNativeDraftRemovalObservation?> observeNativeDraftRemoval({
    required String sessionId,
    required String draftId,
    required bool Function() isCurrent,
  }) async {
    final before = await observeNativeDraft(
      sessionId: sessionId,
      draftId: draftId,
      isCurrent: isCurrent,
    );
    if (!isCurrent() || before == null || !before.current) return null;
    final raw = before._raw, object = before._span;
    var start = object.objectStart, end = object.objectEnd;
    // Remove exactly the object and ONE adjacent delimiter/whitespace span.
    // Sibling tokens, brackets and all other whitespace remain byte-identical.
    var next = end;
    while (next < raw.length && ' \r\n\t'.contains(raw[next])) {
      next++;
    }
    if (next < raw.length && raw[next] == ',') {
      end = next + 1;
    } else {
      var previous = start - 1;
      while (previous >= 0 && ' \r\n\t'.contains(raw[previous])) {
        previous--;
      }
      if (previous >= 0 && raw[previous] == ',') start = previous;
    }
    final after = raw.substring(0, start) + raw.substring(end);
    String hash(String value) => sha256.convert(utf8.encode(value)).toString();
    String? evidence(Map<String, Object?> value) {
      final native = jsonEncode(value);
      if (native.length > SupportMutationEvidence.maxNativeBytes ||
          utf8.encode(native).length > SupportMutationEvidence.maxNativeBytes) {
        return null;
      }
      return SupportMutationEvidence.encode(native);
    }

    // Full bounded original/after arrays stay in the genuine private capsule.
    // AEAD journal stores only the exact removed span plus whole-array hashes.
    // Oversized unknown raw evidence is a PRE-effect refusal, never truncation.
    final beforeEvidence = evidence({
      'v': 1,
      'session': sessionId,
      'draft': draftId,
      'index': before._index,
      'at': start,
      'arrayHash': hash(raw),
      'removedRaw': raw.substring(start, end),
    });
    final afterEvidence = evidence({
      'v': 1,
      'session': sessionId,
      'draft': draftId,
      'absent': true,
      'arrayHash': hash(after),
    });
    if (beforeEvidence == null ||
        afterEvidence == null ||
        utf8.encode(after).length > 524288 ||
        !before.current ||
        !isCurrent()) {
      return null;
    }
    return MemoryNativeDraftRemovalObservation._(
      before,
      start,
      end,
      after,
      beforeEvidence,
      afterEvidence,
    );
  }

  Future<String?> _readNativeRemovedDraft(
    String session,
    String id,
    bool Function() current,
  ) async {
    if (!current()) return null;
    try {
      final row = await customSelect(
        r'''SELECT b.pending_drafts_json AS drafts_raw FROM memory_book_rows b
        WHERE b.session_id = ?
          AND EXISTS (SELECT 1 FROM chat_sessions s WHERE s.session_id = b.session_id)
          AND typeof(b.pending_drafts_json) = 'text'
          AND length(CAST(b.pending_drafts_json AS BLOB)) <= 524288
          AND json_type(b.pending_drafts_json) = 'array'
          AND json_array_length(b.pending_drafts_json) <= 128
          AND length(CAST(b.settings_json AS BLOB)) <= 65536
          AND json_type(b.settings_json) = 'object'
          AND (json_type(b.settings_json, '$.vectorSearchEnabled') IS NULL
            OR json_type(b.settings_json, '$.vectorSearchEnabled') = 'false')
          AND (SELECT count(*) FROM json_each(b.settings_json)
            WHERE key = 'vectorSearchEnabled') <= 1
          AND NOT EXISTS (SELECT 1 FROM json_each(b.pending_drafts_json) d
            WHERE json_extract(d.value, '$.id') = ?)''',
        variables: [Variable.withString(session), Variable.withString(id)],
        readsFrom: {memoryBookRows},
      ).getSingleOrNull();
      return current() && row != null ? row.read<String>('drafts_raw') : null;
    } catch (_) {
      return null;
    }
  }

  Future<MemoryNativeDraftRemovalUndoObservation?>
  observeNativeDraftRemovalUndo({
    required MemoryNativeDraftRemovalReceipt receipt,
    required bool Function() isCurrent,
  }) async {
    if (!identical(receipt._before._before._repo, this) ||
        !receipt.current ||
        !isCurrent())
      return null;
    final ticket = captureSetupTicket();
    bool current() => isCurrent() && receipt.current && ticket.current;
    if (!current()) return null;
    final raw = await _readNativeRemovedDraft(
      receipt.sessionId,
      receipt.draft.id,
      current,
    );
    if (!current() || raw != receipt._before._afterRaw) return null;
    try {
      final drafts = (jsonDecode(raw!) as List)
          .map((d) => MemoryDraft.fromJson(Map<String, dynamic>.from(d as Map)))
          .toList(growable: false);
      return current()
          ? MemoryNativeDraftRemovalUndoObservation._(
              this,
              receipt,
              raw,
              ticket,
              List.unmodifiable(drafts),
            )
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeNativeDraftArray(
    String session,
    String before,
    String after,
    bool Function() current,
  ) async {
    if (!current()) throw const _MemoryBookControlRetired();
    final count = await customUpdate(
      '''UPDATE memory_book_rows SET pending_drafts_json = ?
      WHERE session_id = ? AND pending_drafts_json = ?''',
      variables: [
        Variable.withString(after),
        Variable.withString(session),
        Variable.withString(before),
      ],
      updates: {memoryBookRows},
    );
    if (!current() || count != 1) throw const _MemoryBookControlRetired();
  }

  Future<MemoryNativeDraftRemovalReceipt?> removeNativeDraft({
    required MemoryNativeDraftRemovalObservation observed,
    required SupportRepo support,
    required String parentSession,
    required String operationId,
    required bool Function() isCurrent,
  }) async {
    final before = observed._before;
    if (!identical(before._repo, this) ||
        !observed.current ||
        !support.usesDatabase(attachedDatabase) ||
        !isCurrent())
      return null;
    final admission = _beginSetupBookWrite(before._ticket);
    if (admission == null) return null;
    observed._used = true;
    before._used = true;
    bool current() => isCurrent() && admission.current;
    MemoryNativeDraftRemovalReceipt? committed;
    try {
      committed = await outsideDatabaseTransaction(
        attachedDatabase,
        () => attachedDatabase.runWithInterceptor(
          () => attachedDatabase.transaction(() async {
            void check(bool value) {
              if (!value || !current()) throw const _MemoryBookControlRetired();
            }

            final latest = await _readNativeDraft(
              before.sessionId,
              before.draft.id,
              current,
              before._ticket,
            );
            check(_sameNativeDraft(before, latest));
            check(
              observed._afterRaw ==
                  before._raw.substring(0, observed._start) +
                      before._raw.substring(observed._end),
            );
            final reserved = await support.reserveMutation(
              record: SupportMutationRecord(
                id: operationId,
                sessionId: parentSession,
                domain: 'memory.draft.delete',
                targetId: _nativeDraftTarget(before),
                beforeJson: observed._beforeEvidence,
                afterJson: observed._afterEvidence,
                status: 'pending',
                createdAt: currentTimestampSeconds(),
              ),
              isCurrent: current,
            );
            check(reserved != null);
            await _writeNativeDraftArray(
              before.sessionId,
              before._raw,
              observed._afterRaw,
              current,
            );
            check(true);
            final absent = await _readNativeRemovedDraft(
              before.sessionId,
              before.draft.id,
              current,
            );
            check(absent == observed._afterRaw);
            final settled = await support.settleMutation(
              expected: reserved!,
              fact: SupportMutationFact.applied,
              hasOriginalDbCustody: current,
            );
            check(settled != null);
            final durable = await _readNativeRemovedDraft(
              before.sessionId,
              before.draft.id,
              current,
            );
            check(durable == observed._afterRaw);
            return MemoryNativeDraftRemovalReceipt._(observed, settled!);
          }),
          interceptor: _NativeDraftCommitGuard(current),
        ),
        onRejected: () => const _MemoryBookControlRetired(),
      );
      return committed; // Delivered COMMIT remains a fact after retirement.
    } on _MemoryBookControlRetired {
      return null;
    } catch (_) {
      throw const MemoryNativeDraftStorageException();
    } finally {
      final ticket = admission.finish();
      committed?._ticket = ticket;
    }
  }

  Future<MemoryNativeDraftRemovalUndoCommit?> undoNativeDraftRemoval({
    required MemoryNativeDraftRemovalReceipt receipt,
    required MemoryNativeDraftRemovalUndoObservation observed,
    required SupportRepo support,
    required String parentSession,
    required bool Function() isCurrent,
  }) async {
    if (!identical(receipt._before._before._repo, this) ||
        !identical(observed._repo, this) ||
        !identical(observed._receipt, receipt) ||
        !receipt.current ||
        !observed.current ||
        receipt._journal.record.sessionId != parentSession ||
        !support.usesDatabase(attachedDatabase) ||
        !isCurrent())
      return null;
    final admission = _beginSetupBookWrite(receipt._ticket!);
    if (admission == null) return null;
    receipt._used = true;
    observed._used = true;
    bool current() => isCurrent() && admission.current;
    MemoryNativeDraftRemovalUndoCommit? committed;
    try {
      committed = await outsideDatabaseTransaction(
        attachedDatabase,
        () => attachedDatabase.runWithInterceptor(
          () => attachedDatabase.transaction(() async {
            void check(bool value) {
              if (!value || !current()) throw const _MemoryBookControlRetired();
            }

            final before = receipt._before._before;
            final latest = await _readNativeRemovedDraft(
              receipt.sessionId,
              receipt.draft.id,
              current,
            );
            check(
              latest == observed._raw && latest == receipt._before._afterRaw,
            );
            final reserved = await support.reserveMutationUndo(
              expected: receipt._journal,
              isCurrent: current,
            );
            check(reserved != null);
            // Restore the EXACT retained original array, never journal JSON,
            // fromJson/toJson reconstruction, reinsert-at-end or latest ticket.
            await _writeNativeDraftArray(
              receipt.sessionId,
              observed._raw,
              before._raw,
              current,
            );
            check(true);
            final restored = await _readNativeDraft(
              receipt.sessionId,
              receipt.draft.id,
              current,
              observed._ticket,
            );
            check(
              _sameNativeDraft(before, restored) &&
                  restored!.draft == receipt.draft,
            );
            final settled = await support.settleMutation(
              expected: reserved!,
              fact: SupportMutationFact.undone,
              hasOriginalDbCustody: current,
            );
            check(settled != null);
            final durable = await _readNativeDraft(
              receipt.sessionId,
              receipt.draft.id,
              current,
              observed._ticket,
            );
            check(
              _sameNativeDraft(before, durable) &&
                  durable!.draft == receipt.draft,
            );
            return MemoryNativeDraftRemovalUndoCommit._(
              receipt.draft,
              receipt.index,
            );
          }),
          interceptor: _NativeDraftCommitGuard(current),
        ),
        onRejected: () => const _MemoryBookControlRetired(),
      );
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
