part of 'support_native_global_regex_adapter.dart';

extension _GlobalRegexExecution on SupportNativeGlobalRegexAdapter {
  Future<SupportAppActionOutcome> _execute(
    _GlobalRegexPlan plan,
    SupportAppActionContext context,
    bool Function() admitted,
  ) async {
    final operation = plan.undo
        ? SupportAppDomainOperation.globalRegexUndo
        : SupportAppDomainOperation.globalRegexDisable;
    bool nativeCurrent() =>
        admitted() &&
        _current &&
        plan.port.current &&
        context.domainEffectForOperation(operation) &&
        context.domainEffectMatches(plan.target, plan);
    bool beforeCurrent() =>
        nativeCurrent() && plan.observed.current && plan.inventory.current;
    if (!beforeCurrent())
      return SupportAppActionOutcome(SupportAppActionCode.stale);
    final sourcesCurrent = _retainedSources(plan, context);
    if (sourcesCurrent == null)
      return SupportAppActionOutcome(SupportAppActionCode.stale);
    if (!plan.undo && plan.observed.disabled)
      return SupportAppActionOutcome(SupportAppActionCode.noChange);
    SupportMutationReservation? pending;
    var effect = SupportAppActionEffect.none;
    try {
      pending = plan.undo
          ? await support.reserveMutationUndo(
              expected: plan.journal!,
              isCurrent: beforeCurrent,
            )
          : await support.reserveMutation(
              record: SupportMutationRecord(
                id: supportRepairOpaqueId('regex-op'),
                sessionId: context.sessionId,
                domain: 'globalRegex',
                targetId: plan.observed.id,
                beforeJson: plan.beforeEvidence,
                afterJson: plan.afterEvidence,
                status: SupportMutationStatus.pending.value,
                createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
              ),
              isCurrent: beforeCurrent,
            );
      if (pending == null)
        return SupportAppActionOutcome(SupportAppActionCode.stale);
      if (!beforeCurrent())
        return await _settleRegex(
          pending,
          false,
          effect,
          null,
          nativeCurrent,
          plan,
          context,
          sourcesCurrent,
        );
      final valid = await chats.revalidateNativeSelectionInventory(
        plan.inventory,
        beforeCurrent,
      );
      if (!valid || !beforeCurrent() || !sourcesCurrent()) {
        return await _settleRegex(
          pending,
          false,
          effect,
          null,
          nativeCurrent,
          plan,
          context,
          sourcesCurrent,
        );
      }
      // Original target (whole document/controller revision), inventory and source
      // guards are checked AGAIN inside actual original plugin CAS admission.
      bool writeCurrent() =>
          nativeCurrent() && plan.inventory.current && sourcesCurrent();
      final written = plan.undo
          ? await plan.port.undo(
              plan.observed,
              plan.retained!.receipt,
              writeCurrent,
            )
          : await plan.port.disable(plan.observed, writeCurrent);
      effect = !written.started
          ? SupportAppActionEffect.none
          : written.saved
          ? SupportAppActionEffect.persisted
          : SupportAppActionEffect.uncertain;
      return await _settleRegex(
        pending,
        written.started,
        effect,
        written.receipt,
        nativeCurrent,
        plan,
        context,
        sourcesCurrent,
      );
    } catch (_) {
      // Journal or delivery failure does not erase an acknowledged plugin fact.
      return SupportAppActionOutcome(
        SupportAppActionCode.storageUncertain,
        effect: effect,
        data: const {
          'reconciliationRequired': true,
          'receiptRetained': false,
          'refreshPending': true,
        },
      );
    }
  }

  Future<SupportAppActionOutcome> _settleRegex(
    SupportMutationReservation pending,
    bool started,
    SupportAppActionEffect effect,
    NativeGlobalRegexReceipt? receipt,
    bool Function() nativeCurrent,
    _GlobalRegexPlan plan,
    SupportAppActionContext context,
    bool Function() sourcesCurrent,
  ) async {
    final fact = effect == SupportAppActionEffect.persisted
        ? plan.undo
              ? SupportMutationFact.undone
              : SupportMutationFact.applied
        : started
        ? SupportMutationFact.reconciliationRequired
        : plan.undo
        ? SupportMutationFact.undoConflict
        : SupportMutationFact.failed;
    final settled = await support.settleMutation(
      expected: pending,
      fact: fact,
      hasOriginalDbCustody: nativeCurrent,
    );
    if (settled == null)
      return SupportAppActionOutcome(
        SupportAppActionCode.storageUncertain,
        effect: effect,
        data: const {
          'reconciliationRequired': true,
          'receiptRetained': false,
          'refreshPending': true,
        },
      );
    if (effect == SupportAppActionEffect.none)
      return SupportAppActionOutcome(SupportAppActionCode.conflict);
    if (effect == SupportAppActionEffect.uncertain) {
      return SupportAppActionOutcome(
        SupportAppActionCode.storageUncertain,
        effect: effect,
        data: const {
          'reconciliationRequired': true,
          'receiptRetained': false,
          'refreshPending': true,
        },
      );
    }
    if (plan.undo) {
      _receipts.remove(plan.target);
      return SupportAppActionOutcome(
        SupportAppActionCode.completed,
        effect: effect,
        data: {
          'outcome': 'undone',
          'regexDomain': 'global',
          'affectedScripts': 1,
          'affectedPreferenceKeys': 1,
          'refreshPending': receipt == null,
        },
      );
    }
    String? handle;
    if (!_disposed && receipt != null && receipt.current && sourcesCurrent()) {
      while (_receipts.length >= 64) {
        _receipts.remove(_receipts.keys.first);
      }
      handle = supportRepairOpaqueId('repair');
      _receipts[handle] = _RetainedGlobalRegex(
        context.sessionId,
        receipt,
        settled,
        sourcesCurrent,
        plan.inventory,
      );
    }
    return SupportAppActionOutcome(
      SupportAppActionCode.completed,
      effect: effect,
      data: {
        'outcome': 'applied',
        'regexDomain': 'global',
        'affectedScripts': 1,
        'affectedPreferenceKeys': 1,
        'receiptRetained': handle != null,
        if (handle != null) 'receipt': handle,
        'refreshPending': receipt == null,
      },
    );
  }
}
