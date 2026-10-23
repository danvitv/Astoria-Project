part of 'support_provider_action_service.dart';

extension SupportProviderActionExecution on SupportProviderActionService {
  Future<SupportProviderActionResult> execute(
    SupportProviderApproval approval,
  ) {
    final review = approval._review;
    SupportProviderActionResult refused() => SupportProviderActionResult._(
      SupportProviderActionCode.refused,
      review,
      null,
    );
    // Claim ONCE and exclude competing jobs BEFORE all external predicates.
    // No replacement lookup, notification or await before synchronous start.
    if (approval._used || !identical(review._binding.service, this)) {
      return Future.value(refused());
    }
    approval._used = true;
    if (_pending != null) return Future.value(refused());
    final job = Object();
    _pending = job;
    return _executeOriginal(review, job);
  }

  Future<SupportProviderActionResult> _executeOriginal(
    SupportProviderReview review,
    Object job,
  ) async {
    SupportProviderActionResult fact(
      SupportProviderActionCode code, [
      SupportProviderApplied? applied,
    ]) => SupportProviderActionResult._(code, review, applied);
    try {
      String? journalId;
      bool admission() {
        try {
          return _admission(review, job: job) &&
              (journalId == null ||
                  currentRedactor().redactText(journalId) == journalId) &&
              _admission(review, job: job);
        } catch (_) {
          return false;
        }
      }

      if (!admission()) return fact(SupportProviderActionCode.refused);
      final undo = review._undo;
      Future<SupportProviderSetupReceipt?> operation;
      if (undo != null) {
        if (undo._undoUsed) return fact(SupportProviderActionCode.refused);
        undo._undoUsed = true;
        operation = setupRepo.undo(
          original: undo._receipt,
          isCurrent: admission,
        );
      } else {
        // Evidence stays exact, private and canonical. No caller body/JSON/tool
        // parser, speculative pending row or service-owned DB transaction.
        final action = review.kind == SupportProviderActionKind.create
            ? SupportProviderSetupAction.create
            : SupportProviderSetupAction.update;
        final id = _newOperationId();
        journalId = id;
        final createdAt = _now();
        final p = currentRedactor();
        if (p.redactText(id) != id || !admission()) {
          return fact(SupportProviderActionCode.refused);
        }
        final target = review._after!.connectionId;
        final evidence = SupportMutationRecord(
          id: id,
          sessionId: review._binding.sessionId,
          domain: SupportProviderSetupRepo.domain,
          targetId: target,
          status: 'pending',
          createdAt: createdAt,
          beforeJson: SupportProviderSetupEvidence.encode(
            action: action,
            sessionId: review._binding.sessionId,
            connectionId: target,
            state: review._before,
          ),
          afterJson: SupportProviderSetupEvidence.encode(
            action: action,
            sessionId: review._binding.sessionId,
            connectionId: target,
            state: review._after,
          ),
        );
        if (!admission()) return fact(SupportProviderActionCode.refused);
        operation = action == SupportProviderSetupAction.create
            ? setupRepo.create(
                draft: review._draft!,
                pendingEvidence: evidence,
                isCurrent: admission,
              )
            : setupRepo.update(
                expected: review._choice!._observation,
                patch: review._patch!,
                pendingEvidence: evidence,
                isCurrent: admission,
              );
      }
      final receipt = await operation;
      // TRUE outer commit may already have completed. Do not turn its ORIGINAL
      // factual return into a refusal just because admission/UI is now retired.
      if (receipt == null) return fact(SupportProviderActionCode.refused);
      if (receipt.status == SupportMutationStatus.undoConflict) {
        return fact(SupportProviderActionCode.undoConflict);
      }
      if (receipt.status == SupportMutationStatus.undone) {
        return fact(SupportProviderActionCode.undone);
      }
      final applied = SupportProviderApplied._(review, receipt);
      // Optional current observation gives ONLY conditional eligibility; the
      // ORIGINAL repository receipt remains mandatory authority at final Undo.
      // Readback failure never discards the factual original commit or retries.
      try {
        if (review.kind == SupportProviderActionKind.update && admission()) {
          final observed = await apiRepo.inspectKeyless(receipt.connectionId);
          if (admission() &&
              observed != null &&
              observed.nativeOwned &&
              observed.view == receipt.after &&
              apiRepo.sameKeylessObservation(observed, observed) &&
              admission()) {
            applied._undoObservation = observed;
          }
        }
      } catch (_) {
        /* Original fact retained; Undo stays unavailable. */
      }
      return fact(SupportProviderActionCode.applied, applied);
    } catch (_) {
      // Fixed safe uncertainty, NEVER arbitrary native exception text. No retry,
      // fresh ID guess, row-equality inference or historical receipt recovery.
      return fact(SupportProviderActionCode.storageUncertain);
    } finally {
      if (identical(_pending, job)) _pending = null;
    }
  }
}
