part of '../support_text_context_repo.dart';

final class _OwnedSessionHistoryBoundary
    implements SupportSessionHistoryBoundary {
  _OwnedSessionHistoryBoundary(this._owner, QueryRow row)
    : _metadata = Map.unmodifiable(row.data);
  final SupportTextContextRepo _owner;
  final Map<String, Object?> _metadata;
  String get _sessionId => _metadata['session_id']! as String;
  String get _messageId => _metadata['id']! as String;
  String get _runId => _metadata['run_id']! as String;
  int get _createdAt => _metadata['created_at']! as int;
  @override
  String toString() => 'SupportSessionHistoryBoundary';
}

extension SupportSessionBoundaryCapture on SupportTextContextRepo {
  /// Metadata ONLY. Called after the exact current user is durable and before
  /// history preview. No caller-constructed tuple or restored boundary accepted.
  /// Parent must separately fence the current native run/session at each await.
  Future<SupportSessionHistoryBoundary> captureSupportSessionBoundary({
    required String sessionId,
    required String userMessageId,
    required String runId,
  }) async {
    try {
      final redactor = _currentRedactor();
      if (_admissionOwnerRevoked ||
          !_identity(sessionId, redactor) ||
          !_identity(userMessageId, redactor) ||
          !_identity(runId, redactor)) {
        _fail(SupportTextContextFailure.invalidSelection);
      }
      final before = await _stamp();
      final row = await _db.transaction(
        () => _sessionBoundaryRow(_db, sessionId, userMessageId, runId),
      );
      final after = await _stamp();
      if (_admissionOwnerRevoked || before != after) {
        _fail(SupportTextContextFailure.stale);
      }
      if (!_identity(sessionId, _currentRedactor()) ||
          !_identity(userMessageId, _currentRedactor()) ||
          !_identity(runId, _currentRedactor())) {
        _fail(SupportTextContextFailure.unavailable);
      }
      return _OwnedSessionHistoryBoundary(this, row);
    } on SupportTextContextException {
      rethrow;
    } catch (_) {
      _fail(SupportTextContextFailure.unavailable);
    }
  }

  _OwnedSessionHistoryBoundary _requireBoundary(
    String sessionId,
    SupportSessionHistoryBoundary boundary,
  ) {
    if (_admissionOwnerRevoked ||
        boundary is! _OwnedSessionHistoryBoundary ||
        !identical(boundary._owner, this) ||
        boundary._sessionId != sessionId ||
        !_identity(sessionId, _currentRedactor()) ||
        !_identity(boundary._messageId, _currentRedactor()) ||
        !_identity(boundary._runId, _currentRedactor())) {
      _fail(SupportTextContextFailure.invalidSelection);
    }
    return boundary;
  }
}

Future<QueryRow> _sessionBoundaryRow(
  AppDatabase db,
  String sessionId,
  String userMessageId,
  String runId, {
  void Function()? checkpoint,
}) async {
  checkpoint?.call();
  final row = await db
      .customSelect(
        '''
    SELECT s.rowid AS parent_identity, s.created_at AS parent_created_at,
      m.rowid AS native_identity, m.id, m.session_id, m.run_id, m.created_at,
      m.role, m.status
    FROM support_messages m JOIN support_sessions s ON s.id = m.session_id
    WHERE s.id = ? AND m.session_id = ? AND m.id = ? AND m.run_id = ?
      AND typeof(s.created_at) = 'integer' AND s.created_at BETWEEN 0 AND 8640000000000
      AND typeof(m.id) = 'text' AND length(m.id) BETWEEN 1 AND 256
      AND typeof(m.session_id) = 'text' AND length(m.session_id) BETWEEN 1 AND 256
      AND typeof(m.run_id) = 'text' AND length(m.run_id) BETWEEN 1 AND 256
      AND typeof(m.created_at) = 'integer' AND m.created_at BETWEEN 0 AND 8640000000000
      AND m.role = 'user' AND m.status = 'complete'
  ''',
        variables: [
          Variable.withString(sessionId),
          Variable.withString(sessionId),
          Variable.withString(userMessageId),
          Variable.withString(runId),
        ],
      )
      .getSingleOrNull();
  checkpoint?.call();
  if (row == null) _fail(SupportTextContextFailure.unavailable);
  return row;
}
