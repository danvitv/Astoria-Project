part of 'memory_native_entry_owner.dart';

/// Draft text shares the original tab owner, queue and lifetime. No new owner,
/// provider startup, generation, approval, compatibility put or indexing path.
extension MemoryNativeDraftOwner on MemoryNativeEntryOwner {
  MemoryDraft? cachedDraft(String id) {
    if (!current) return null;
    final book = readBook();
    if (book == null ||
        book.sessionId != sessionId ||
        book.pendingDrafts.length > 128 ||
        book.settings.vectorSearchEnabled)
      return null;
    final matches = book.pendingDrafts.where((d) => d.id == id).toList();
    if (matches.length != 1 ||
        matches.single.status != 'pending_approval' ||
        matches.single.vectorSearch)
      return null;
    return matches.single;
  }

  Future<MemoryNativeDraftObservation?> observeDraft(
    String id,
    bool Function() sourceCurrent,
  ) async {
    final draft = cachedDraft(id), revision = queue.revision;
    bool current() =>
        this.current &&
        sourceCurrent() &&
        queue.idle &&
        queue.revision == revision &&
        identical(cachedDraft(id), draft);
    if (draft == null || !current()) return null;
    final observation = await repo.observeNativeDraft(
      sessionId: sessionId,
      draftId: id,
      isCurrent: current,
    );
    return current() && observation?.draft == draft ? observation : null;
  }

  Future<MemoryNativeDraftReceipt?> reviseDraftText({
    required MemoryNativeDraftObservation observed,
    required int queueRevision,
    required String content,
    required SupportRepo support,
    required String parentSession,
    required String operationId,
    required bool Function() sourceCurrent,
  }) => queue.runNative<MemoryNativeDraftReceipt>(queueRevision, (
    queueCurrent,
  ) async {
    final cachedBefore = cachedDraft(observed.draft.id);
    bool current() =>
        this.current &&
        sourceCurrent() &&
        queueCurrent() &&
        cachedBefore == observed.draft &&
        identical(cachedDraft(observed.draft.id), cachedBefore);
    if (!current()) return null;
    final receipt = await repo.reviseNativeDraft(
      observed: observed,
      content: content,
      support: support,
      parentSession: parentSession,
      operationId: operationId,
      isCurrent: current,
    );
    if (receipt != null && current() && receipt.current) {
      publishDraft(receipt.after);
    }
    return receipt;
  });

  Future<MemoryNativeDraftUndoCommit?> undoDraftText({
    required MemoryNativeDraftReceipt receipt,
    required MemoryNativeDraftObservation observed,
    required int queueRevision,
    required SupportRepo support,
    required String parentSession,
    required bool Function() sourceCurrent,
  }) => queue.runNative<MemoryNativeDraftUndoCommit>(queueRevision, (
    queueCurrent,
  ) async {
    final cachedBefore = cachedDraft(observed.draft.id);
    bool current() =>
        this.current &&
        sourceCurrent() &&
        queueCurrent() &&
        cachedBefore == observed.draft &&
        identical(cachedDraft(observed.draft.id), cachedBefore);
    if (!current()) return null;
    final restored = await repo.undoNativeDraft(
      receipt: receipt,
      observed: observed,
      support: support,
      parentSession: parentSession,
      isCurrent: current,
    );
    if (restored != null && current() && restored.current) {
      publishDraft(restored.after);
    }
    return restored;
  });
}
