part of 'support_native_active_selection_adapter.dart';

extension _SelectionExecution on SupportNativeActiveSelectionAdapter {
  Future<SupportAppActionOutcome> _execute(_SelectionPlan plan,
      SupportAppActionContext context, bool Function() admitted) async {
    final operation = plan.undo ? SupportAppDomainOperation.activeSelectionUndo :
        plan.port.kind == NativeActiveSelectionKind.persona
        ? SupportAppDomainOperation.activePersona : SupportAppDomainOperation.activePreset;
    bool nativeCurrent() => admitted() && _current && plan.port.current &&
        context.domainEffectForOperation(operation) &&
        context.domainEffectMatches(plan.target, plan);
    bool beforeCurrent() => nativeCurrent() && plan.observed.current &&
        plan.inventory.current && plan.targetsCurrent();
    if (!beforeCurrent()) return SupportAppActionOutcome(SupportAppActionCode.stale);
    final sourcesCurrent = _retainedSources(plan, context);
    if (sourcesCurrent == null) return SupportAppActionOutcome(SupportAppActionCode.stale);
    // Revalidation belongs to the retained original repositories. Never resolve
    // a replacement provider, normalize an ID or fall back to Studio storage.
    final latest = await _row(plan.port.kind, plan.next);
    if (!beforeCurrent() || latest != plan.desiredRow) {
      return SupportAppActionOutcome(SupportAppActionCode.conflict);
    }
    if (plan.observed.value == plan.next) {
      return SupportAppActionOutcome(SupportAppActionCode.noChange);
    }
    SupportMutationReservation? pending;
    var effect = SupportAppActionEffect.none;
    try {
      pending = plan.undo
          ? await support.reserveMutationUndo(expected: plan.journal!,
              isCurrent: beforeCurrent)
          : await support.reserveMutation(record: SupportMutationRecord(
              id: supportRepairOpaqueId('selection-op'), sessionId: context.sessionId,
              domain: 'activeSelection', targetId: plan.port.kind.key,
              beforeJson: SupportMutationEvidence.encode(jsonEncode({
                'v': 1, 'domain': plan.port.kind.name,
                'selection': SupportNativeActiveSelectionAdapter._selection(plan.observed.value)})),
              afterJson: SupportMutationEvidence.encode(jsonEncode({
                'v': 1, 'domain': plan.port.kind.name,
                'selection': SupportNativeActiveSelectionAdapter._selection(plan.next)})),
              status: SupportMutationStatus.pending.value,
              createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000),
              isCurrent: beforeCurrent);
      if (pending == null) return SupportAppActionOutcome(SupportAppActionCode.stale);
      if (!beforeCurrent()) {
        return await _settleSelection(pending, plan.undo, false,
            SupportAppActionEffect.none, null, nativeCurrent, plan, context, sourcesCurrent);
      }
      final inventoryCurrent = await chats.revalidateNativeSelectionInventory(
          plan.inventory, beforeCurrent);
      if (!inventoryCurrent || !beforeCurrent()) {
        return await _settleSelection(pending, plan.undo, false,
            SupportAppActionEffect.none, null, nativeCurrent, plan, context, sourcesCurrent);
      }
      final row = await _row(plan.port.kind, plan.next);
      if (!beforeCurrent() || row != plan.desiredRow) {
        return await _settleSelection(pending, plan.undo, false,
            SupportAppActionEffect.none, null, nativeCurrent, plan, context, sourcesCurrent);
      }
      final written = await plan.port.write(observed: plan.observed,
          value: plan.next,
          // The ORIGINAL target/inventory guards survive the final SELECT's
          // delivery and are checked again INSIDE actual plugin CAS admission.
          isCurrent: () => nativeCurrent() && plan.inventory.current &&
              plan.targetsCurrent() && sourcesCurrent());
      effect = !written.started ? SupportAppActionEffect.none :
          written.saved ? SupportAppActionEffect.persisted : SupportAppActionEffect.uncertain;
      return await _settleSelection(pending, plan.undo, written.started, effect,
          written.receipt, nativeCurrent, plan, context, sourcesCurrent);
    } catch (_) {
      // A journal failure cannot erase a completed or ambiguous plugin effect.
      // Nor can a matching cache manufacture saved evidence or reusable Undo.
      return SupportAppActionOutcome(SupportAppActionCode.storageUncertain,
        effect: effect, data: const {'reconciliationRequired': true,
          'receiptRetained': false, 'refreshPending': true});
    }
  }

  Future<SupportAppActionOutcome> _settleSelection(
      SupportMutationReservation pending, bool undo, bool started,
      SupportAppActionEffect effect, NativeActiveSelectionReceipt? receipt,
      bool Function() nativeCurrent, _SelectionPlan plan,
      SupportAppActionContext context, bool Function() sourcesCurrent) async {
    final fact = effect == SupportAppActionEffect.persisted
        ? undo ? SupportMutationFact.undone : SupportMutationFact.applied
        : started ? SupportMutationFact.reconciliationRequired
        : undo ? SupportMutationFact.undoConflict : SupportMutationFact.failed;
    final settled = await support.settleMutation(expected: pending, fact: fact,
        hasOriginalDbCustody: nativeCurrent);
    if (settled == null) {
      return SupportAppActionOutcome(SupportAppActionCode.storageUncertain,
        effect: effect, data: const {'reconciliationRequired': true,
          'receiptRetained': false, 'refreshPending': true});
    }
    if (effect == SupportAppActionEffect.none) {
      return SupportAppActionOutcome(SupportAppActionCode.conflict);
    }
    if (effect == SupportAppActionEffect.uncertain) {
      return SupportAppActionOutcome(SupportAppActionCode.storageUncertain,
        effect: effect, data: const {'reconciliationRequired': true,
          'receiptRetained': false, 'refreshPending': true});
    }
    if (undo) {
      _receipts.remove(plan.target);
      return SupportAppActionOutcome(SupportAppActionCode.completed, effect: effect,
        data: {'outcome': 'undone', 'selectionDomain': plan.port.kind.name,
          'affectedPreferenceKeys': 1, 'refreshPending': receipt == null});
    }
    String? handle;
    if (!_disposed && receipt != null && receipt.current && sourcesCurrent()) {
      while (_receipts.length >= 64) { _receipts.remove(_receipts.keys.first); }
      handle = supportRepairOpaqueId('repair');
      _receipts[handle] = _RetainedSelection(context.sessionId,
          receipt, settled, sourcesCurrent, plan.inventory, plan.targetsCurrent);
    }
    return SupportAppActionOutcome(SupportAppActionCode.completed, effect: effect,
      data: {'outcome': 'applied', 'selectionDomain': plan.port.kind.name,
        'affectedPreferenceKeys': 1, 'receiptRetained': handle != null,
        if (handle != null) 'receipt': handle, 'refreshPending': receipt == null});
  }
}
