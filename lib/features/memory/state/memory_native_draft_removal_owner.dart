part of 'memory_native_entry_owner.dart';

/// Removal/absence publication belongs to the ORIGINAL mounted controller.
extension MemoryNativeDraftRemovalOwner on MemoryNativeEntryOwner {
  bool _sameDraftList(List<MemoryDraft> a, List<MemoryDraft> b) =>
      a.length == b.length &&
      List.generate(a.length, (i) => a[i] == b[i]).every((same) => same);

  Future<MemoryNativeDraftRemovalObservation?> observeDraftRemoval(
    String id,
    bool Function() sourceCurrent,
  ) async {
    final draft = cachedDraft(id), revision = queue.revision;
    bool current() =>
        this.current &&
        sourceCurrent() &&
        publishDraftList != null &&
        queue.idle &&
        queue.revision == revision &&
        identical(cachedDraft(id), draft);
    if (draft == null || !current()) return null;
    final observed = await repo.observeNativeDraftRemoval(
      sessionId: sessionId,
      draftId: id,
      isCurrent: current,
    );
    return current() && observed?.draft == draft ? observed : null;
  }

  Future<MemoryNativeDraftRemovalUndoObservation?> observeDraftRemovalUndo(
    MemoryNativeDraftRemovalReceipt receipt,
    bool Function() sourceCurrent,
  ) async {
    final book = readBook(), revision = queue.revision;
    bool current() =>
        this.current &&
        sourceCurrent() &&
        publishDraftList != null &&
        queue.idle &&
        queue.revision == revision &&
        identical(readBook(), book) &&
        book != null &&
        book.sessionId == sessionId &&
        !book.settings.vectorSearchEnabled &&
        book.pendingDrafts.length <= 128 &&
        !book.pendingDrafts.any((d) => d.id == receipt.draft.id);
    if (!current() || receipt.sessionId != sessionId) return null;
    final observed = await repo.observeNativeDraftRemovalUndo(
      receipt: receipt,
      isCurrent: current,
    );
    return current() &&
            observed != null &&
            _sameDraftList(book!.pendingDrafts, observed.drafts)
        ? observed
        : null;
  }

  Future<MemoryNativeDraftRemovalReceipt?> removeDraft({
    required MemoryNativeDraftRemovalObservation observed,
    required int queueRevision,
    required SupportRepo support,
    required String parentSession,
    required String operationId,
    required bool Function() sourceCurrent,
  }) => queue.runNative<MemoryNativeDraftRemovalReceipt>(queueRevision, (
    queueCurrent,
  ) async {
    final book = readBook(), draft = cachedDraft(observed.draft.id);
    bool current() =>
        this.current &&
        sourceCurrent() &&
        queueCurrent() &&
        publishDraftList != null &&
        identical(readBook(), book) &&
        draft == observed.draft &&
        identical(cachedDraft(observed.draft.id), draft) &&
        book != null &&
        observed.index < book.pendingDrafts.length &&
        book.pendingDrafts[observed.index] == draft;
    if (!current()) return null;
    final receipt = await repo.removeNativeDraft(
      observed: observed,
      support: support,
      parentSession: parentSession,
      operationId: operationId,
      isCurrent: current,
    );
    if (receipt != null && current() && receipt.current) {
      publishDraftList!([...book!.pendingDrafts]..removeAt(observed.index));
    }
    return receipt;
  });

  Future<MemoryNativeDraftRemovalUndoCommit?> undoDraftRemoval({
    required MemoryNativeDraftRemovalReceipt receipt,
    required MemoryNativeDraftRemovalUndoObservation observed,
    required int queueRevision,
    required SupportRepo support,
    required String parentSession,
    required bool Function() sourceCurrent,
  }) => queue.runNative<MemoryNativeDraftRemovalUndoCommit>(queueRevision, (
    queueCurrent,
  ) async {
    final book = readBook();
    bool current() =>
        this.current &&
        sourceCurrent() &&
        queueCurrent() &&
        publishDraftList != null &&
        identical(readBook(), book) &&
        book != null &&
        book.sessionId == sessionId &&
        !book.settings.vectorSearchEnabled &&
        !book.pendingDrafts.any((d) => d.id == receipt.draft.id) &&
        _sameDraftList(book.pendingDrafts, observed.drafts) &&
        receipt.index >= 0 &&
        receipt.index <= book.pendingDrafts.length;
    if (!current()) return null;
    final restored = await repo.undoNativeDraftRemoval(
      receipt: receipt,
      observed: observed,
      support: support,
      parentSession: parentSession,
      isCurrent: current,
    );
    if (restored != null && current() && restored.current) {
      publishDraftList!(
        [...book!.pendingDrafts]..insert(restored.index, restored.draft),
      );
    }
    return restored;
  });
}
