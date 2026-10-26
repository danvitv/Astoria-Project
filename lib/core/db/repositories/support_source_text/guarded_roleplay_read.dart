part of '../support_text_context_repo.dart';

/// Reuses the existing strict active-variation reader with checkpoints INSIDE
/// its SQL awaits, not merely after an unguarded public loadRoleplay completes.
/// The guard is lifetime/currentness only: the caller holds exact native source
/// authority BEFORE entering this method. It is not a global body grant.
extension SupportNativeSourceRoleplayRead on SupportTextContextRepo {
  /// Narrow integration exception for the ONE counted provenance-column append
  /// performed by the exact pending-reply CAS. The caller must retain its actual
  /// durable reservation. Never reload/rebind foreign bodies: preserve each
  /// original opaque observation and require exactly +1 same-handle change, no
  /// other-connection version change, identical rows/membership/raw text/policy.
  /// This cannot repair a revoked snapshot or accept an intervening write/ABA.
  Future<List<SupportTextContextSnapshot>> refreshAfterOwnSourceExtension({
    required List<SupportTextContextSnapshot> snapshots,
    required void Function() checkpoint,
  }) async {
    checkpoint();
    if (_admissionOwnerRevoked ||
        _admissionContract !=
            SupportTextAdmissionContract
                .auditedRootSingleConnectionNoBusyHandler ||
        snapshots.isEmpty ||
        snapshots.length > SupportTextContextRepo.maxSelections ||
        snapshots.any(
          (s) =>
              s is! _OwnedTextSnapshot ||
              !identical(s._owner, this) ||
              s._revoked,
        )) {
      _fail(SupportTextContextFailure.stale);
    }
    final retained = List<_OwnedTextSnapshot>.unmodifiable(
      snapshots.cast<_OwnedTextSnapshot>(),
    );
    try {
      return await _db.transaction(() async {
        checkpoint();
        final stamp = await _stamp();
        checkpoint();
        for (final original in retained) {
          if (stamp.$1 != original._stamp.$1 + 1 ||
              stamp.$2 != original._stamp.$2) {
            _fail(SupportTextContextFailure.stale);
          }
          final whole = original._wholeSession;
          final (read, ids) = whole == null
              ? (
                  await _read(
                    original.source,
                    original.sessionId,
                    original.messageIds,
                    checkpoint: checkpoint,
                    boundedSuffix: original._boundedSuffix,
                  ),
                  original.messageIds,
                )
              : await _readSession(whole, checkpoint: checkpoint);
          checkpoint();
          if (!_sameIds(ids, original.messageIds) ||
              !read._same(original._observation) ||
              !_sameMessages(
                _sanitize(read, original.sessionId, ids),
                original.messages,
              )) {
            _fail(SupportTextContextFailure.stale);
          }
          _provenance(original._observation);
        }
        final after = await _stamp();
        checkpoint();
        if (after != stamp ||
            retained.any((s) => s._revoked) ||
            _admissionOwnerRevoked) {
          _fail(SupportTextContextFailure.stale);
        }
        return List<SupportTextContextSnapshot>.unmodifiable([
          for (final original in retained)
            _OwnedTextSnapshot(
              this,
              original.source,
              original.sessionId,
              original.messageIds,
              original.messages,
              original.provenance,
              original._observation,
              stamp,
              wholeSession: original._wholeSession,
              boundedSuffix: original._boundedSuffix,
            ),
        ]);
      });
    } catch (_) {
      for (final original in retained) {
        original._revoke();
      }
      _fail(SupportTextContextFailure.stale);
    }
  }

  Future<SupportTextContextSnapshot> loadRoleplayForNativeSource({
    required String sessionId,
    required List<String> messageIds,
    required void Function() checkpoint,
  }) async {
    checkpoint();
    if (_admissionOwnerRevoked) _fail(SupportTextContextFailure.unavailable);
    final ids = _selection(sessionId, messageIds);
    final before = await _stamp();
    checkpoint();
    final read = await _read(
      SupportTextContextSource.roleplay,
      sessionId,
      ids,
      checkpoint: checkpoint,
    );
    checkpoint();
    final after = await _stamp();
    checkpoint();
    if (before != after) _fail(SupportTextContextFailure.stale);
    return _OwnedTextSnapshot(
      this,
      SupportTextContextSource.roleplay,
      sessionId,
      ids,
      _sanitize(read, sessionId, ids),
      _provenance(read),
      read,
      after,
    );
  }
}
