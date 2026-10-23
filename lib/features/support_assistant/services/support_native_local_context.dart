part of 'support_native_runtime.dart';

/// Local settings custody excludes the selected LLM recipient/configuration
/// epoch. Its own key registration must retire N1, not its native save gesture.
extension SupportNativeLocalContext on SupportNativeRuntime {
  SupportNativePermissionContext get localContext =>
      SupportNativePermissionContext(
        supportSessionId: sessionId,
        epoch: _localEpoch,
        scope: snapshot.preferences?.scope,
      );

  bool get localActionsAvailable =>
      alive &&
      !_localExhausted &&
      _localPending == 0 &&
      sessionId.isNotEmpty &&
      snapshot.isAvailable;

  SupportPermissionSnapshot get localPermissionSnapshot => localActionsAvailable
      ? snapshot
      : const SupportPermissionSnapshot(
          SupportPermissionAvailability.unavailable,
        );

  /// Start BEFORE admission/notify/any await for local consent/scope writes.
  /// Independent native toggles can still merge under their original controller.
  void Function() beginLocalPermissionChange() {
    final owner = _localOwner;
    _localPending++;
    _advanceLocalEpoch();
    _notifyLocalFence();
    var settled = false;
    return () {
      if (settled) return;
      settled = true;
      if (!identical(owner, _localOwner)) return;
      _localPending--;
      _advanceLocalEpoch();
      _notifyLocalFence();
    };
  }

  void _advanceLocalEpoch() {
    if (_localEpoch >= maxSupportPermissionRevision) {
      _localExhausted = true;
    } else {
      _localEpoch++;
    }
  }

  void _retireLocalOwner() {
    _localOwner = Object();
    _localPending = 0;
    _advanceLocalEpoch();
  }

  void _reconcileLocalSnapshot(SupportPermissionSnapshot next) {
    final a = snapshot.preferences, b = next.preferences;
    if (snapshot.availability != next.availability ||
        a?.supportSessionId != b?.supportSessionId ||
        a?.policyIdentity != b?.policyIdentity ||
        !(a?.scope == null ? b?.scope == null : a!.scope!.sameAs(b?.scope)) ||
        a?.allows(SupportPermission.readSafeSettings) !=
            b?.allows(SupportPermission.readSafeSettings) ||
        a?.allows(SupportPermission.confirmedSettingsChanges) !=
            b?.allows(SupportPermission.confirmedSettingsChanges)) {
      _advanceLocalEpoch();
    }
  }

  void _notifyLocalFence() {
    try {
      notify();
    } catch (_) {
      // An observer cannot strand the local pending token or prevent retirement.
    }
  }
}
