part of 'manual_rewrite_job_repo.dart';

final _nativeReviewDatabases = Expando<_NativeReviewDatabase>();

final class _NativeReviewDatabase {
  final jobs = <String, _NativeReviewJobEpoch>{};
  final operations = <String, String>{};
}

final class _NativeReviewJobEpoch {
  int revision = 0, pending = 0;
  bool exhausted = false;
  void advance() {
    if (revision >= 9007199254740991) {
      exhausted = true;
    } else {
      revision++;
    }
  }

  _NativeReviewAdmission begin() {
    advance();
    pending++;
    return _NativeReviewAdmission(this, revision);
  }
}

/// A native job ticket is process-local provenance, not its durable CAS version.
/// Same-value ordinary writes retire it at acceptance, before their queue/SQL.
final class ManualRewriteNativeTicket {
  ManualRewriteNativeTicket._(this._owner, this._revision);
  final _NativeReviewJobEpoch _owner;
  final int _revision;
  bool _retired = false;
  bool get current {
    if (_owner.exhausted || _owner.pending != 0 || _owner.revision != _revision)
      _retired = true;
    return !_retired;
  }
}

final class _NativeReviewAdmission {
  _NativeReviewAdmission(this.owner, this.revision);
  final _NativeReviewJobEpoch owner;
  final int revision;
  bool _closed = false;
  bool get current =>
      !_closed &&
      !owner.exhausted &&
      owner.pending == 1 &&
      owner.revision == revision;
  ManualRewriteNativeTicket? finish({bool retainSuccessor = true}) {
    if (_closed) return null;
    final retained = retainSuccessor && current;
    _closed = true;
    owner.pending--;
    owner.advance();
    // Never capture a latest ticket after await: this admission issues ONLY its
    // own original successor. A late ordinary writer cannot be adopted.
    return retained &&
            !owner.exhausted &&
            owner.pending == 0 &&
            owner.revision == revision + 1
        ? ManualRewriteNativeTicket._(owner, revision + 1)
        : null;
  }
}

extension _NativeReviewFences on ManualRewriteJobRepo {
  _NativeReviewDatabase get _nativeReview =>
      _nativeReviewDatabases[_db] ??= _NativeReviewDatabase();
  _NativeReviewJobEpoch _nativeJob(String id) =>
      _nativeReview.jobs.putIfAbsent(id, _NativeReviewJobEpoch.new);
  Future<T> _trackNativeReviewJobWrite<T>(
    String id,
    Future<T> Function() effect,
  ) {
    final admission = _nativeJob(id).begin();
    return Future.sync(effect).whenComplete(() {
      admission.finish();
    });
  }

  Future<T> _trackNativeReviewOperationWrite<T>(
    String id,
    Future<T> Function() effect,
  ) {
    final job = _nativeReview.operations[id];
    return job == null
        ? Future.sync(effect)
        : _trackNativeReviewJobWrite(job, effect);
  }
}

extension ManualRewriteNativeAdmission on ManualRewriteJobRepo {
  /// Called only by the mounted original review owner for its already-loaded
  /// aggregate. Lookup itself never loads a job, starts generation or applies.
  ManualRewriteNativeTicket bindNativeLoadedReview(
    ManualRewriteJobSnapshot snap,
  ) {
    for (final view in snap.operations) {
      if (view.operation.rewriteJobId == snap.job.id) {
        _nativeReview.operations[view.operation.id] = snap.job.id;
      }
    }
    final owner = _nativeJob(snap.job.id);
    return ManualRewriteNativeTicket._(owner, owner.revision);
  }

  /// Ordinary route actions (including guarded apply, whose repo is separate)
  /// retire native tickets synchronously; no durable contract is changed.
  void retireNativeReview(String jobId) => _nativeJob(jobId).advance();
}

final class ManualRewriteNativeStorageException implements Exception {
  const ManualRewriteNativeStorageException();
}

final class _NativeReviewRefused implements Exception {
  const _NativeReviewRefused();
}

final class _NativeReviewCommitGuard extends QueryInterceptor {
  _NativeReviewCommitGuard(this.current);
  final bool Function() current;
  void check() {
    if (!current()) throw const _NativeReviewRefused();
  }

  @override
  Future<bool> ensureOpen(
    QueryExecutor executor,
    QueryExecutorUser user,
  ) async {
    check();
    final result = await super.ensureOpen(executor, user);
    check();
    return result;
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    check();
    final result = await super.runSelect(executor, statement, args);
    check();
    return result;
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    check();
    final result = await super.runInsert(executor, statement, args);
    check();
    return result;
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    check();
    final result = await super.runUpdate(executor, statement, args);
    check();
    return result;
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) async {
    check();
    // This OUTER check is only an early refusal. AppDatabase's original fence
    // repeats it beneath every awaited observer at the actual commit send.
    await super.commitTransaction(inner);
    // Delivered physical COMMIT remains a fact even if its ticket retired.
  }
}
