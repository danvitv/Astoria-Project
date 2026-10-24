part of 'native_provider_mutation_bridge.dart';

extension _NativeKeylessTerminalAcquisition
    on NativeProviderKeylessMutationBridge {
  Future<KeylessNativeMutationLease?> _terminalAcquire({
    required KeylessApiConfigTerminalPlan plan,
    required KeylessTerminalEffectPermit permit,
  }) {
    final custody = _NativeKeylessTerminalCustody(this, plan, permit);
    return _acquire(
      connectionId: plan.connectionId,
      isCurrent: () => custody.isCurrent,
      terminal: custody,
    );
  }
}

final class _NativeKeylessTerminalCustody
    implements NativeKeylessTerminalEffectPort, KeylessTerminalNativeCustody {
  _NativeKeylessTerminalCustody(this._bridge, this._plan, this._permit);
  final NativeProviderKeylessMutationBridge _bridge;
  final KeylessApiConfigTerminalPlan _plan;
  final KeylessTerminalEffectPermit _permit;
  bool _consumed = false;
  bool get hasAdmittedEffect => _consumed;
  @override
  bool get isCurrent => _bridge._current(() => _permit.current);
  @override
  bool get isRootCurrent {
    try {
      return _bridge.isRootCurrent();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> admitAtMutationStart() => _permit.admitAtMutationStart();
  @override
  bool consume() {
    if (_consumed || !isCurrent) return false;
    if (!_permit.consume(plan: _plan, custody: this)) return false;
    _consumed = true;
    return true;
  }
}
