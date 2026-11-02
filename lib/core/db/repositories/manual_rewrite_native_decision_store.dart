part of 'manual_rewrite_job_repo.dart';

/// Exact reviewed job/operation provenance. No JSON/public reconstruction port.
final class ManualRewriteNativeObservation {
  ManualRewriteNativeObservation._(
    this._repo,
    this._job,
    this._op,
    this._ticket,
  );
  final ManualRewriteJobRepo _repo;
  final RewriteJobRow _job;
  final RewriteOperationRow _op;
  final ManualRewriteNativeTicket _ticket;
  bool _used = false;
  String get jobId => _job.id;
  String get operationId => _op.id;
  String get sessionId => _job.chatSessionId;
  int get jobVersion => _job.version;
  int get revision => _op.currentRevision;
  int get decisionRevision => _op.decisionRevision;
  bool get current => !_used && _ticket.current;
}

final class ManualRewriteNativeRejectReceipt {
  ManualRewriteNativeRejectReceipt._(
    this._before,
    this._job,
    this._op,
    this._journal,
  );
  final ManualRewriteNativeObservation _before;
  final RewriteJobRow _job;
  final RewriteOperationRow _op;
  final SupportMutationReservation _journal;
  ManualRewriteNativeTicket? _ticket;
  bool _used = false;
  String get jobId => _job.id;
  String get operationId => _op.id;
  String get sessionId => _job.chatSessionId;
  int get jobVersion => _job.version;
  int get revision => _op.currentRevision;
  int get priorDecisionRevision => _before.decisionRevision;

  /// Original native watcher comparison only; never tool/result metadata.
  RewriteJobRow get nativeJob => _job;
  RewriteOperationRow get nativeOperation => _op;
  bool get current => !_used && _ticket?.current == true;
}

final class ManualRewriteNativeUndoObservation {
  ManualRewriteNativeUndoObservation._(this._receipt, this._observed);
  final ManualRewriteNativeRejectReceipt _receipt;
  final ManualRewriteNativeObservation _observed;
  bool _used = false;
  bool get current => !_used && _receipt.current && _observed.current;
}

final class ManualRewriteNativeUndoCommit {
  ManualRewriteNativeUndoCommit._(this._job, this._op);
  final RewriteJobRow _job;
  final RewriteOperationRow _op;
  ManualRewriteNativeTicket? _ticket;
  int get jobVersion => _job.version;
  RewriteJobRow get nativeJob => _job;
  RewriteOperationRow get nativeOperation => _op;
  bool get current => _ticket?.current == true;
}

extension ManualRewriteNativeDecisionStore on ManualRewriteJobRepo {
  static const _maximum = 9007199254740991;
  bool _reviewId(String value) =>
      value.length <= 128 &&
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$').hasMatch(value);
  bool _pendingJob(RewriteJobRow job) {
    try {
      final request = jsonDecode(job.requestJson);
      return request is Map &&
          request['provenance'] != 'automatedEvolution' &&
          _reviewId(job.id) &&
          _reviewId(job.chatSessionId) &&
          job.status == 'pending' &&
          job.version >= 1 &&
          job.version <= _maximum &&
          job.appliedCharacterRevision == 0 &&
          job.appliedCharacterRevisionHash.isEmpty;
    } catch (_) {
      return false;
    }
  }

  bool _reviewable(RewriteOperationRow op, RewriteJobRow job) =>
      _reviewId(op.id) &&
      op.rewriteJobId == job.id &&
      op.chatSessionId == job.chatSessionId &&
      op.status == 'reviewable' &&
      op.currentRevision >= 1 &&
      op.currentRevision < _maximum &&
      op.decisionRevision >= 0 &&
      op.decisionRevision < _maximum &&
      op.appliedCharacterRevision == 0 &&
      op.appliedCharacterRevisionHash.isEmpty;

  Future<ManualRewriteNativeObservation?> _readNativeReview(
    RewriteJobRow expectedJob,
    RewriteOperationRow expectedOp,
    ManualRewriteNativeTicket ticket,
    bool Function() current,
  ) async {
    if (!current()) return null;
    // Validate SQLite dynamic types before generated Drift integer mapping.
    // Raw bodies are neither projected nor decoded by this fixed metadata query.
    final valid = await _db
        .customSelect(
          '''
      SELECT 1 FROM rewrite_jobs j JOIN rewrite_operations o ON o.rewrite_job_id = j.id
      WHERE j.id = ? AND o.id = ? AND j.status = 'pending' AND o.status = 'reviewable'
        AND typeof(j.version) = 'integer' AND j.version >= 1 AND j.version <= $_maximum
        AND typeof(o.current_revision) = 'integer' AND o.current_revision >= 1
        AND o.current_revision < $_maximum AND typeof(o.decision_revision) = 'integer'
        AND o.decision_revision >= 0 AND o.decision_revision < $_maximum
        AND typeof(j.applied_character_revision) = 'integer' AND j.applied_character_revision = 0
        AND typeof(o.applied_character_revision) = 'integer' AND o.applied_character_revision = 0
        AND typeof(j.created_at) = 'integer' AND typeof(j.updated_at) = 'integer'
        AND typeof(o.created_at) = 'integer' AND typeof(o.updated_at) = 'integer'
        AND j.created_at >= 0 AND j.created_at <= $_maximum AND j.updated_at >= 0 AND j.updated_at <= $_maximum
        AND o.created_at >= 0 AND o.created_at <= $_maximum AND o.updated_at >= 0 AND o.updated_at <= $_maximum
        AND NOT EXISTS (SELECT 1 FROM card_evolution_proposal_runs p WHERE p.rewrite_job_id = j.id)
      ''',
          variables: [
            Variable.withString(expectedJob.id),
            Variable.withString(expectedOp.id),
          ],
          readsFrom: {
            _db.rewriteJobs,
            _db.rewriteOperations,
            _db.cardEvolutionProposalRuns,
          },
        )
        .get();
    if (!current() || valid.length != 1) return null;
    final job = await (_db.select(
      _db.rewriteJobs,
    )..where((t) => t.id.equals(expectedJob.id))).getSingleOrNull();
    if (!current() || job != expectedJob || job == null || !_pendingJob(job))
      return null;
    final op = await (_db.select(
      _db.rewriteOperations,
    )..where((t) => t.id.equals(expectedOp.id))).getSingleOrNull();
    if (!current() || op != expectedOp || op == null || !_reviewable(op, job))
      return null;
    return ManualRewriteNativeObservation._(this, job, op, ticket);
  }

  Future<ManualRewriteNativeObservation?> observeNativeReject({
    required ManualRewriteJobSnapshot loaded,
    required ManualRewriteOperationView selected,
    required ManualRewriteNativeTicket ticket,
    required bool Function() isCurrent,
  }) async {
    if (!identical(ticket._owner, _nativeJob(loaded.job.id)) ||
        !ticket.current ||
        !isCurrent() ||
        loaded.job.version > _maximum - 2 ||
        selected.operation.decision != 'pending' ||
        !loaded.operations.any((view) => identical(view, selected)))
      return null;
    bool current() => isCurrent() && ticket.current;
    try {
      return await _db.transaction(
        () =>
            _readNativeReview(loaded.job, selected.operation, ticket, current),
      );
    } catch (_) {
      return null;
    }
  }

  Future<ManualRewriteNativeUndoObservation?> observeNativeRejectUndo({
    required ManualRewriteNativeRejectReceipt receipt,
    required ManualRewriteJobSnapshot loaded,
    required ManualRewriteOperationView selected,
    required bool Function() isCurrent,
  }) async {
    if (!identical(receipt._before._repo, this) ||
        !receipt.current ||
        !isCurrent() ||
        receipt.jobVersion >= _maximum ||
        loaded.job != receipt._job ||
        selected.operation != receipt._op ||
        !loaded.operations.any((view) => identical(view, selected)))
      return null;
    bool current() => isCurrent() && receipt.current;
    try {
      final observed = await _db.transaction(
        () => _readNativeReview(
          receipt._job,
          receipt._op,
          receipt._ticket!,
          current,
        ),
      );
      return current() && observed != null
          ? ManualRewriteNativeUndoObservation._(receipt, observed)
          : null;
    } catch (_) {
      return null;
    }
  }

  String? _reviewEvidence(RewriteJobRow job, RewriteOperationRow op) {
    final native = jsonEncode({
      'v': 1,
      'job': job.id,
      'operation': op.id,
      'jobVersion': job.version,
      'jobStatus': job.status,
      'revision': op.currentRevision,
      'decision': op.decision,
      'decisionRevision': op.decisionRevision,
      'operationStatus': op.status,
      'applied': 0,
    });
    return utf8.encode(native).length <= SupportMutationEvidence.maxNativeBytes
        ? SupportMutationEvidence.encode(native)
        : null;
  }

  Future<(RewriteJobRow, RewriteOperationRow)> _writeNativeReviewDecision(
    ManualRewriteNativeObservation before,
    String decision,
    int decisionRevision,
    bool Function() current,
  ) async {
    void check(bool accepted) {
      if (!accepted || !current()) throw const _NativeReviewRefused();
    }

    check(true);
    // Confirmed aggregate version, not CURRENT/latest job version as authority.
    final jobs =
        await (_db.update(_db.rewriteJobs)..where(
              (t) =>
                  t.id.equals(before.jobId) &
                  t.version.equals(before.jobVersion) &
                  t.status.equals('pending') &
                  t.appliedCharacterRevision.equals(0) &
                  t.appliedCharacterRevisionHash.equals(''),
            ))
            .write(
              RewriteJobsCompanion(
                version: Value(before.jobVersion + 1),
                updatedAt: Value(currentTimestampSeconds()),
              ),
            );
    check(jobs == 1);
    final ops =
        await (_db.update(_db.rewriteOperations)..where(
              (t) =>
                  t.id.equals(before.operationId) &
                  t.rewriteJobId.equals(before.jobId) &
                  t.chatSessionId.equals(before.sessionId) &
                  t.status.equals('reviewable') &
                  t.currentRevision.equals(before.revision) &
                  t.decision.equals(before._op.decision) &
                  t.decisionRevision.equals(before.decisionRevision) &
                  t.appliedCharacterRevision.equals(0) &
                  t.appliedCharacterRevisionHash.equals(''),
            ))
            .write(
              RewriteOperationsCompanion(
                decision: Value(decision),
                decisionRevision: Value(decisionRevision),
                updatedAt: Value(currentTimestampSeconds()),
              ),
            );
    check(ops == 1);
    final job = await (_db.select(
      _db.rewriteJobs,
    )..where((t) => t.id.equals(before.jobId))).getSingle();
    check(
      job ==
          before._job.copyWith(
            version: before.jobVersion + 1,
            updatedAt: job.updatedAt,
          ),
    );
    final op = await (_db.select(
      _db.rewriteOperations,
    )..where((t) => t.id.equals(before.operationId))).getSingle();
    check(
      op ==
          before._op.copyWith(
            decision: decision,
            decisionRevision: decisionRevision,
            updatedAt: op.updatedAt,
          ),
    );
    return (job, op);
  }

  Future<ManualRewriteNativeRejectReceipt?> rejectNativeReview({
    required ManualRewriteNativeObservation observed,
    required SupportRepo support,
    required String parentSession,
    required String journalId,
    required bool Function() isCurrent,
  }) async {
    if (!identical(observed._repo, this) ||
        !isCurrent() ||
        !support.usesDatabase(_db) ||
        observed._op.decision != 'pending' ||
        !observed.current)
      return null;
    final beforeEvidence = _reviewEvidence(observed._job, observed._op);
    final afterEvidence = _reviewEvidence(
      observed._job.copyWith(version: observed.jobVersion + 1),
      observed._op.copyWith(
        decision: 'rejected',
        decisionRevision: observed.revision,
      ),
    );
    if (beforeEvidence == null || afterEvidence == null) return null;
    if (!isCurrent() || !observed.current) return null;
    final admission = observed._ticket._owner.begin();
    observed._used = true;
    bool current() => isCurrent() && admission.current;
    ManualRewriteNativeRejectReceipt? committed;
    try {
      committed = await outsideDatabaseTransaction(
        _db,
        () => _db.runWithInterceptor(
          () => _db.nativeReviewTransaction(
            () async {
              void check(bool value) {
                if (!value || !current()) throw const _NativeReviewRefused();
              }

              check(
                await _readNativeReview(
                      observed._job,
                      observed._op,
                      observed._ticket,
                      current,
                    ) !=
                    null,
              );
              final reserved = await support.reserveMutation(
                record: SupportMutationRecord(
                  id: journalId,
                  sessionId: parentSession,
                  domain: 'rewrite.reject',
                  targetId: observed.operationId,
                  beforeJson: beforeEvidence,
                  afterJson: afterEvidence,
                  status: 'pending',
                  createdAt: currentTimestampSeconds(),
                ),
                isCurrent: current,
              );
              check(reserved != null);
              final rows = await _writeNativeReviewDecision(
                observed,
                'rejected',
                observed.revision,
                current,
              );
              check(true);
              final settled = await support.settleMutation(
                expected: reserved!,
                fact: SupportMutationFact.applied,
                hasOriginalDbCustody: current,
              );
              check(settled != null);
              check(
                await _readNativeReview(
                      rows.$1,
                      rows.$2,
                      observed._ticket,
                      current,
                    ) !=
                    null,
              );
              return ManualRewriteNativeRejectReceipt._(
                observed,
                rows.$1,
                rows.$2,
                settled!,
              );
            },
            isCurrent: current,
            onRefused: () => const _NativeReviewRefused(),
          ),
          interceptor: _NativeReviewCommitGuard(current),
        ),
        onRejected: () => const _NativeReviewRefused(),
      );
      return committed;
    } on _NativeReviewRefused {
      return null;
    } catch (_) {
      throw const ManualRewriteNativeStorageException();
    } finally {
      // A delivered COMMIT remains a fact. Its successor is issued only while
      // the ORIGINAL captured authority still owns completion, not just its epoch.
      final ticket = admission.finish(retainSuccessor: isCurrent());
      committed?._ticket = ticket;
    }
  }

  Future<ManualRewriteNativeUndoCommit?> undoNativeReject({
    required ManualRewriteNativeRejectReceipt receipt,
    required ManualRewriteNativeUndoObservation observed,
    required SupportRepo support,
    required String parentSession,
    required bool Function() isCurrent,
  }) async {
    if (!identical(receipt._before._repo, this) ||
        !identical(observed._receipt, receipt) ||
        !isCurrent() ||
        receipt._journal.record.sessionId != parentSession ||
        !support.usesDatabase(_db) ||
        !receipt.current ||
        !observed.current)
      return null;
    final admission = receipt._ticket!._owner.begin();
    receipt._used = true;
    observed._used = true;
    bool current() => isCurrent() && admission.current;
    ManualRewriteNativeUndoCommit? committed;
    try {
      committed = await outsideDatabaseTransaction(
        _db,
        () => _db.runWithInterceptor(
          () => _db.nativeReviewTransaction(
            () async {
              void check(bool value) {
                if (!value || !current()) throw const _NativeReviewRefused();
              }

              final before = observed._observed;
              check(
                await _readNativeReview(
                      receipt._job,
                      receipt._op,
                      receipt._ticket!,
                      current,
                    ) !=
                    null,
              );
              final reserved = await support.reserveMutationUndo(
                expected: receipt._journal,
                isCurrent: current,
              );
              check(reserved != null);
              // Restore only the genuine prior pending decision and its original
              // decisionRevision. Never edit/revalidate, reset a revision or approve.
              final rows = await _writeNativeReviewDecision(
                before,
                receipt._before._op.decision,
                receipt.priorDecisionRevision,
                current,
              );
              check(true);
              final settled = await support.settleMutation(
                expected: reserved!,
                fact: SupportMutationFact.undone,
                hasOriginalDbCustody: current,
              );
              check(settled != null);
              check(
                await _readNativeReview(
                      rows.$1,
                      rows.$2,
                      receipt._ticket!,
                      current,
                    ) !=
                    null,
              );
              return ManualRewriteNativeUndoCommit._(rows.$1, rows.$2);
            },
            isCurrent: current,
            onRefused: () => const _NativeReviewRefused(),
          ),
          interceptor: _NativeReviewCommitGuard(current),
        ),
        onRejected: () => const _NativeReviewRefused(),
      );
      return committed;
    } on _NativeReviewRefused {
      return null;
    } catch (_) {
      throw const ManualRewriteNativeStorageException();
    } finally {
      final ticket = admission.finish(retainSuccessor: isCurrent());
      committed?._ticket = ticket;
    }
  }
}
