part of '../support_text_context_repo.dart';

/// Source-audited custody assertion, NOT runtime discovery of an arbitrary
/// executor. The native owner must enter from outside every Drift transaction,
/// retain one already-initialized, non-pooled/non-reconnecting connection from
/// preview to dispatch (all lazy-open/migration/preparation work is complete),
/// and exclude custom busy handlers and raw same-handle writers. Unknown owners
/// get no admission. PRAGMA busy_timeout alone cannot identify a custom handler.
enum SupportTextAdmissionContract { auditedRootSingleConnectionNoBusyHandler }

/// Trusted owning-repo reads only, on this attached DB's current transaction
/// zone. Must be bounded and call checkpoint after EVERY await, before further
/// SQL. No writes, parallel/escaping SQL, HTTP, UI or arbitrary future races.
typedef SupportTextAdmissionCheck =
    Future<bool> Function(void Function() checkpoint);

extension SupportTextContextAdmission on SupportTextContextRepo {
  /// Revoke synchronously on connection/owner replacement. Never rebase a
  /// retained preview onto a reopened handle, even if counters happen to match.
  void revokeAdmissionOwner() => _admissionOwnerRevoked = true;

  /// Fresh ROOT entry under the explicit audited constructor contract above.
  /// Stock Drift has no public top-level-zone test or cancellable dequeue.
  /// A revoked queued callback exits before PRAGMA/DELETE/source reads; cleanup
  /// still waits for the earlier Drift owner. This does not remove queue items.
  ///
  /// dispatch is a trusted T capsule's synchronous void method, never a Future.
  /// The capsule privately captures the response; HTTP is awaited only after
  /// this operation completes (including COMMIT/release). A post-dispatch error
  /// escapes so T can truthfully classify admitted-but-failed and cancel.
  Future<bool> admitDispatch({
    required List<SupportTextContextSnapshot> snapshots,
    required bool Function() isCurrent,
    required SupportTextAdmissionCheck checkReadOnly,
    required void Function() dispatch,
  }) async {
    final retained = List<SupportTextContextSnapshot>.unmodifiable(snapshots);
    bool current() {
      try {
        return !_admissionOwnerRevoked && isCurrent();
      } catch (_) {
        return false;
      }
    }

    void checkpoint() {
      if (!current()) _fail(SupportTextContextFailure.stale);
    }

    if (_admissionContract !=
            SupportTextAdmissionContract
                .auditedRootSingleConnectionNoBusyHandler ||
        !current() ||
        retained.length > SupportTextContextRepo.maxSelections ||
        retained.any(
          (s) =>
              s is! _OwnedTextSnapshot ||
              !identical(s._owner, this) ||
              s._revoked,
        )) {
      return false;
    }
    var dispatched = false;
    try {
      return await _db.transaction<bool>(() async {
        checkpoint(); // In particular, NO data access on canceled late entry.
        final timeout = await _db
            .customSelect('PRAGMA busy_timeout')
            .getSingle();
        checkpoint();
        if (timeout.data.length != 1 ||
            timeout.data.values.single is! int ||
            timeout.data.values.single != 0) {
          _fail(SupportTextContextFailure.unavailable);
        }
        // FIRST main-data-access statement. Constant false still obtains the
        // main writer, but increments no counter and fires no row trigger.
        await _db.customStatement(
          'DELETE FROM main."support_messages" WHERE 0',
        );
        checkpoint();
        final before = await _stamp();
        checkpoint();
        if (!await checkReadOnly(checkpoint)) return false;
        checkpoint();
        for (final snapshot in retained) {
          if (!await _revalidate(snapshot, checkpoint: checkpoint)) {
            return false;
          }
          checkpoint();
        }
        final after = await _stamp();
        checkpoint();
        if (before != after) {
          return false; // Also catches caller counted writes.
        }
        for (final snapshot in retained.cast<_OwnedTextSnapshot>()) {
          if (snapshot._revoked ||
              after != snapshot._stamp ||
              !_sameMessages(
                _sanitize(
                  snapshot._observation,
                  snapshot.sessionId,
                  snapshot.messageIds,
                ),
                snapshot.messages,
              )) {
            return snapshot._revoke();
          }
          _provenance(snapshot._observation);
        }
        checkpoint();
        dispatched = true;
        dispatch(); // No await from final checks through actual adapter fetch.
        return true; // bool, never the capsule's private response Future.
      });
    } catch (_) {
      if (dispatched) rethrow;
      return false;
    }
  }
}
