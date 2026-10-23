part of 'support_theme_action_service.dart';

/// Provider-owned ORIGINAL data custody. Retain through UI/runtime/cipher-provider
/// retirement and share with replacement feature readers until drain completes.
/// Only actual original AppDatabase loss should retire its injected guard.
final class SupportThemeActionCustody {
  SupportThemeActionCustody({
    required this.repo,
    required this.hasOriginalDbCustody,
  });
  final SupportRepo repo;
  final bool Function() hasOriginalDbCustody;
  final _jobs = <String, _ThemeLiveJob>{};
  final _unresolved = <String, _ThemeUnresolved>{};
  int get activeJobs => _jobs.length;
  int get unresolvedCount => _unresolved.length;
  bool _current() {
    try {
      return hasOriginalDbCustody();
    } catch (_) {
      return false;
    }
  }

  Future<void> drain() async {
    while (_jobs.isNotEmpty) {
      await Future.wait(_jobs.values.map((job) => job.future).toList());
    }
  }
}

typedef _ThemeLiveJob = ({
  String sessionId,
  Future<SupportThemeActionResult> future,
});

final class _ThemeUnresolved {
  _ThemeUnresolved(this.record, this.reservation, this.domainResult);
  final SupportMutationRecord record;
  final SupportMutationReservation? reservation;
  final ThemeSelectionResult? domainResult;
}

/// Fixed safe classifications; this object is factual custody, not a current
/// display authorization. projectResult checks original live UI before paint.
final class SupportThemeActionResult {
  const SupportThemeActionResult._({
    required this.effect,
    required this.journal,
    this.effectStarted = false,
    this.domainCode,
    this.status,
    this.applied,
    this._binding,
    this._operationId,
  });
  final SupportThemeEffect effect;
  final SupportThemeJournalSave journal;
  final bool effectStarted;
  final ThemeSelectionCode? domainCode;

  /// Last accepted reservation/settlement status. On journal failure this is NOT
  /// proof of the row's current status; read-only recovery can observe that later.
  final SupportMutationStatus? status;
  final SupportThemeApplied? applied;
  final _ThemeBinding? _binding;
  final String? _operationId;

  /// A display/recovery identifier only, never executable native authority.
  String? get operationId {
    final b = _binding, id = _operationId;
    return b != null &&
            id != null &&
            b.service._displayCurrent(b) &&
            SupportThemeActionService._codec.identifier(
              id,
              b.service.redaction.redactor,
            )
        ? id
        : null;
  }
}

extension SupportThemeExecution on SupportThemeActionService {
  /// Consume synchronously before any await: same-turn duplicate/reentry denied.
  Future<SupportThemeActionResult> execute(SupportThemeApproval approval) {
    final review = approval._review, b = approval._review._binding;
    if (_consumed[approval] == true || !_current(b, changes: true)) {
      return Future.value(_refused);
    }
    _consumed[approval] = true;
    String id;
    try {
      id = review._applied?._reservation.record.id ?? _newOperationId();
      if (!SupportThemeActionService._codec.identifier(id, b.redactor) ||
          custody._jobs.containsKey(id) ||
          custody._unresolved.containsKey(id) ||
          !_current(b, changes: true)) {
        return Future.value(_refused);
      }
    } catch (_) {
      return Future.value(_refused);
    }
    // _run starts with an awaited policy read, so register before it resumes.
    final job = _run(id, review);
    custody._jobs[id] = (sessionId: b.sessionId, future: job);
    return job.whenComplete(() {
      custody._jobs.remove(id);
    });
  }

  SupportThemeActionResult? projectResult(
    SupportThemeIntent intent,
    SupportThemeActionResult result,
  ) {
    final original = result._binding, displayed = intent._binding;
    return original != null &&
            _current(original) &&
            _current(displayed) &&
            identical(original.controller, displayed.controller) &&
            identical(original.uiLifetime, displayed.uiLifetime)
        ? result
        : null;
  }

  static const _refused = SupportThemeActionResult._(
    effect: SupportThemeEffect.refused,
    journal: SupportThemeJournalSave.notReserved,
  );

  Future<SupportThemeActionResult> _run(
    String id,
    SupportThemeReview review,
  ) async {
    final b = review._binding, undo = review._applied;
    if (!await _fresh(b, changes: true) || !_current(b, changes: true)) {
      return _refused;
    }
    final preview = projectReview(review);
    if (preview == null) return _refused;
    SupportMutationRecord record;
    try {
      final before = SupportThemeActionService._codec.encode(
        sessionId: b.sessionId,
        value: preview.before,
        policy: b.redactor,
      );
      final after = SupportThemeActionService._codec.encode(
        sessionId: b.sessionId,
        value: preview.after,
        policy: b.redactor,
      );
      final time = _now();
      if (before == null ||
          after == null ||
          time < 0 ||
          time > maxSupportPermissionRevision ||
          !_current(b, changes: true)) {
        return _refused;
      }
      // Undo preserves the ORIGINAL immutable before/after evidence.
      record =
          undo?._reservation.record ??
          SupportMutationRecord(
            id: id,
            sessionId: b.sessionId,
            domain: SupportThemeEvidenceCodec.domain,
            targetId: SupportThemeEvidenceCodec.target,
            beforeJson: before,
            afterJson: after,
            status: 'pending',
            createdAt: time,
          );
    } catch (_) {
      return _refused;
    }
    SupportMutationReservation? reserved;
    try {
      reserved = undo == null
          ? await custody.repo.reserveMutation(
              record: record,
              isCurrent: () => _current(b, changes: true),
            )
          : await custody.repo.reserveMutationUndo(
              expected: undo._reservation,
              isCurrent: () => _current(b, changes: true),
            );
    } catch (_) {
      // A failed reservation NEVER invokes theme. Retain candidate separately
      // in case a commit was delivered through an exceptional outer boundary.
      custody._unresolved[id] = _ThemeUnresolved(record, null, null);
      return SupportThemeActionResult._(
        effect: SupportThemeEffect.refused,
        journal: SupportThemeJournalSave.unresolved,
        binding: b,
        operationId: id,
      );
    }
    if (reserved == null) return _refused;
    custody._unresolved[id] = _ThemeUnresolved(record, reserved, null);
    ThemeSelectionResult? domain;
    var invocation = false;
    if (await _fresh(b, changes: true) && _current(b, changes: true)) {
      try {
        invocation = true;
        domain = undo == null
            ? await theme.applyInstalledSelection(
                review._plan!,
                isCurrent: () => _current(b, changes: true),
              )
            : await theme.undoInstalledSelection(
                undo._receipt,
                isCurrent: () => _current(b, changes: true),
              );
      } catch (_) {
        // If the owning API unexpectedly throws, effectStarted is unavailable.
        // Invocation is conservatively uncertain, never invented no-effect.
      }
    }
    // No live admission check here: original outcome custody must join late work.
    custody._unresolved[id] = _ThemeUnresolved(record, reserved, domain);
    final verified =
        domain?.code == ThemeSelectionCode.applied &&
        domain?.effectStarted == true &&
        domain?.writeAccepted == true &&
        domain?.freshObserved == ThemeSelectionFreshObservation.after &&
        domain?.receipt != null;
    final started = domain?.effectStarted ?? invocation;
    final effect = verified
        ? (undo == null
              ? SupportThemeEffect.applied
              : SupportThemeEffect.undone)
        : started
        ? SupportThemeEffect.uncertain
        : SupportThemeEffect.noEffect;
    final fact = verified
        ? (undo == null
              ? SupportMutationFact.applied
              : SupportMutationFact.undone)
        : started
        ? SupportMutationFact.reconciliationRequired
        : undo == null
        ? SupportMutationFact.failed
        : SupportMutationFact.undoConflict;
    SupportMutationReservation? settled;
    try {
      settled = await custody.repo.settleMutation(
        expected: reserved,
        fact: fact,
        hasOriginalDbCustody: custody._current,
      );
    } catch (_) {
      /* Domain truth cannot be erased by journal-save failure. */
    }
    if (settled != null) custody._unresolved.remove(id);
    return SupportThemeActionResult._(
      effect: effect,
      effectStarted: started,
      domainCode: domain?.code,
      journal: settled == null
          ? SupportThemeJournalSave.unresolved
          : SupportThemeJournalSave.settled,
      status: settled?.status ?? reserved.status,
      binding: b,
      operationId: id,
      applied: verified && undo == null && settled != null
          ? SupportThemeApplied._(custody, theme, settled, domain!.receipt!)
          : null,
    );
  }
}
