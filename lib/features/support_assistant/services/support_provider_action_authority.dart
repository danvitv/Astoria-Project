part of 'support_provider_action_service.dart';

extension _ProviderAuthority on SupportProviderActionService {
  SupportPermissionPreferences? _localPolicy(
    SupportPermissionSnapshot snapshot,
    SupportNativePermissionContext context,
  ) {
    final p = snapshot.preferences;
    if (!snapshot.isAvailable ||
        p == null ||
        context.recipient != null ||
        p.supportSessionId != context.supportSessionId ||
        p.scope?.sameAs(context.scope) != true) {
      return null;
    }
    return SupportPermissionPreferences(
      supportSessionId: p.supportSessionId,
      policyIdentity: p.policyIdentity,
      revision: context.epoch,
      scope: p.scope,
      grants: p.grants.where(
        (r) =>
            r == SupportPermission.readSafeSettings ||
            r == SupportPermission.confirmedSettingsChanges,
      ),
    );
  }

  bool _samePolicy(
    SupportPermissionPreferences a,
    SupportPermissionPreferences? b,
  ) =>
      b != null &&
      a.supportSessionId == b.supportSessionId &&
      a.policyIdentity == b.policyIdentity &&
      a.revision == b.revision &&
      a.scope?.sameAs(b.scope) == true &&
      a.grants.length == b.grants.length &&
      a.grants.every(b.grants.contains);

  bool _current(_ProviderBinding b, {bool changes = false, Object? job}) {
    bool exact() {
      final c = currentLocalContext();
      final p = _localPolicy(currentPermissions(), c);
      return identical(b.service, this) &&
          _alive &&
          identical(b.issuer, _issuer) &&
          (_pending == null || (job != null && identical(job, _pending))) &&
          b.context.sameAs(c) &&
          _samePolicy(b.policy, p) &&
          b.policy.allows(SupportPermission.readSafeSettings) &&
          b.policy.scope!.safeCategories.contains(
            SupportSafeCategory.connections,
          ) &&
          (!changes ||
              b.policy.allows(SupportPermission.confirmedSettingsChanges));
    }

    try {
      if (!exact() || !isOriginalScopeCurrent() || !b.externalCurrent()) {
        return false;
      }
      // Do not bind a replacement issuer/context after a callback changes them.
      return exact() && isOriginalScopeCurrent() && exact();
    } catch (_) {
      return false;
    }
  }

  Future<SupportPermissionSnapshot> _readLocalPolicy(String id) async {
    try {
      final c = currentLocalContext();
      final p = _localPolicy(currentPermissions(), c);
      if (!_alive || c.supportSessionId != id || p == null) return _unavailable;
      final snapshot = await readPermissions(id);
      final next = currentLocalContext();
      final loaded = _localPolicy(snapshot, c);
      final current = _localPolicy(currentPermissions(), next);
      if (!_alive ||
          !c.sameAs(next) ||
          !_samePolicy(p, loaded) ||
          !_samePolicy(p, current)) {
        return _unavailable;
      }
      return SupportPermissionSnapshot(
        SupportPermissionAvailability.available,
        loaded,
      );
    } catch (_) {
      return _unavailable;
    }
  }

  Future<bool> _fresh(_ProviderBinding b, {bool changes = false}) async {
    if (!_current(b, changes: changes)) return false;
    final snapshot = await _readLocalPolicy(b.sessionId);
    return _current(b, changes: changes) &&
        snapshot.isAvailable &&
        _samePolicy(b.policy, snapshot.preferences);
  }

  Future<T?> _readLocal<T>(
    _ProviderBinding b,
    Future<T> Function() loader,
  ) async {
    if (!_current(b)) return null;
    try {
      final lease = await _authorization.prepare(
        supportSessionId: b.sessionId,
        use: SupportPermissionUse.localRead,
        sources: [
          SupportPermissionSource.safeProjection(
            b.sessionId,
            SupportSafeCategory.connections,
          ),
        ],
      );
      if (!_current(b) || lease == null) return null;
      final data = await _authorization.loadLocal(lease, loader);
      if (!_current(b)) return null;
      T? result;
      await _authorization.consume(lease, data, (value) {
        if (_current(b)) result = value;
      });
      return _current(b) ? result : null;
    } catch (_) {
      return null;
    }
  }

  bool _admission(SupportProviderReview review, {Object? job}) {
    final b = review._binding;
    bool exact() =>
        !review._cancelled &&
        _current(b, changes: true, job: job) &&
        (review.destinationKind == SupportProviderDestinationKind.standard ||
            identical(_custom[review]?._review, review));
    if (!exact()) return false;
    // Reproject BOTH whole immutable states from the ORIGINAL review. A first
    // native record read may register a secret while acquire awaits. This guard
    // is called again by the repository before evidence reservation/effect.
    final preview = _projectExact(review);
    return preview != null &&
        exact() &&
        _projectExact(review) != null &&
        exact();
  }

  static const _unavailable = SupportPermissionSnapshot(
    SupportPermissionAvailability.unavailable,
  );
}
