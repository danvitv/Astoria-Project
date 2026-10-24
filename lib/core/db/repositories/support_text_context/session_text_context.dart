part of '../support_text_context_repo.dart';

/// Not a materialized selection: admission reruns this original whole-source
/// request, including source identity and the exact current-input boundary.
final class _WholeSessionSpec {
  const _WholeSessionSpec(
    this._source,
    this._sessionId,
    this._boundary, {
    this._sourceIdentity,
    this._directConversation = false,
  });
  final SupportTextContextSource _source;
  final String _sessionId;
  final _OwnedSessionHistoryBoundary? _boundary;
  final Map<String, Object?>? _sourceIdentity;
  final bool _directConversation;

  static Map<String, Object?> _identityOf(_TextRead read) => Map.unmodifiable({
    for (final key in const [
      'native_identity',
      'created_at',
      'character_id',
      'character_native_identity',
      'variant_group_id',
      'variant_order',
      'session_index',
    ])
      if (read._header.containsKey(key)) key: read._header[key],
  });

  _WholeSessionSpec _captureIdentity(_TextRead read) => _WholeSessionSpec(
    _source,
    _sessionId,
    _boundary,
    sourceIdentity: _identityOf(read),
    directConversation: _directConversation,
  );
}

extension SupportSessionTextContext on SupportTextContextRepo {
  /// Direct native Send's own visible USER/assistant conversation only. This
  /// distinct recipe never discovers another session or exports policy/tool
  /// rows. The caller owns exact Send authority, not a persisted history grant.
  Future<SupportTextContextSnapshot> loadCurrentConversation({
    required String sessionId,
    required SupportSessionHistoryBoundary currentInput,
  }) => _loadSession(
    _WholeSessionSpec(
      SupportTextContextSource.support,
      sessionId,
      _requireBoundary(sessionId, currentInput),
      directConversation: true,
    ),
  );

  /// Fresh bounded complete visible history of exactly this native session.
  /// Session consent and exact prompt approval remain the caller's obligations.
  Future<SupportTextContextSnapshot> loadRoleplaySessionHistory({
    required String sessionId,
  }) => _loadSession(
    _WholeSessionSpec(SupportTextContextSource.roleplay, sessionId, null),
  );

  /// Own history strictly before the original durable user tuple. Neither the
  /// current user nor its reserved reply is loaded, even once as history.
  Future<SupportTextContextSnapshot> loadSupportSessionHistory({
    required String sessionId,
    required SupportSessionHistoryBoundary currentInput,
  }) async {
    try {
      final boundary = _requireBoundary(sessionId, currentInput);
      return await _loadSession(
        _WholeSessionSpec(
          SupportTextContextSource.support,
          sessionId,
          boundary,
        ),
      );
    } on SupportTextContextException {
      rethrow;
    } catch (_) {
      _fail(SupportTextContextFailure.unavailable);
    }
  }

  Future<SupportTextContextSnapshot> _loadSession(
    _WholeSessionSpec spec,
  ) async {
    try {
      if (_admissionOwnerRevoked ||
          !_identity(spec._sessionId, _currentRedactor())) {
        _fail(SupportTextContextFailure.invalidSelection);
      }
      final before = await _stamp();
      final (read, ids) = await _readSession(spec);
      final after = await _stamp();
      if (_admissionOwnerRevoked || before != after) {
        _fail(SupportTextContextFailure.stale);
      }
      final messages = _sanitize(read, spec._sessionId, ids);
      final provenance = _provenance(read);
      return _OwnedTextSnapshot(
        this,
        spec._source,
        spec._sessionId,
        ids,
        messages,
        provenance,
        read,
        after,
        wholeSession: spec._captureIdentity(read),
      );
    } on SupportTextContextException {
      rethrow;
    } catch (_) {
      _fail(SupportTextContextFailure.unavailable);
    }
  }

  Future<(_TextRead, List<String>)> _readSession(
    _WholeSessionSpec spec, {
    void Function()? checkpoint,
  }) async {
    // Discovery, budgets, parent readability, strict body and dedicated origin
    // reads all belong to this repository's same transaction. No page cache.
    final result = await _db.transaction(
      () => spec._source == SupportTextContextSource.roleplay
          ? _RoleplaySessionTextReader(
              _roleplay,
            ).read(spec._sessionId, _currentRedactor, checkpoint: checkpoint)
          : _SupportSessionTextReader(_support).read(
              _requireBoundary(spec._sessionId, spec._boundary!),
              _currentRedactor,
              directConversation: spec._directConversation,
              checkpoint: checkpoint,
            ),
    );
    checkpoint?.call();
    final originalIdentity = spec._sourceIdentity;
    if (originalIdentity != null &&
        !_sameValues(
          originalIdentity,
          _WholeSessionSpec._identityOf(result.$1),
        )) {
      _fail(SupportTextContextFailure.stale);
    }
    if (_nativeProvenanceValidator != null) {
      _nativeProvenanceSessions[result.$1] = spec._sessionId;
    }
    return result;
  }
}
