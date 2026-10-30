part of 'api_config_repo.dart';

/// Constructor-injected native confirmation/ROOT port, never a tool argument.
/// A returned bool is not authority: only the identical opaque dispatch can
/// admit one exact plan. No credentials, network handles or replacement source.
abstract interface class KeylessTerminalEffectAdmissionPort {
  bool isCurrent(KeylessApiConfigTerminalPlan plan);
  Future<void> admit(KeylessTerminalEffectDispatch dispatch);
}

abstract interface class KeylessNativeTerminalMutationPort {
  Future<KeylessNativeMutationLease?> acquireTerminal({
    required KeylessApiConfigTerminalPlan plan,
    required KeylessTerminalEffectPermit permit,
  });
}

/// Implemented only by the native keyless bridge; keeps the original native
/// ROOT lifetime, NOT requesting UI/network authority, after effect admission.
abstract interface class KeylessTerminalNativeCustody {
  bool get isRootCurrent;
}

final class KeylessApiConfigTerminalPlan {
  KeylessApiConfigTerminalPlan._(
    this._owner,
    this._draft,
    this._expected,
    this._patch,
    this.after,
  );
  final KeylessApiConfigTerminalEffectOwner _owner;
  final KeylessApiConfigDraft? _draft;
  final KeylessApiConfigObservation? _expected;
  final KeylessApiConfigPatch? _patch;
  final KeylessApiConfigView after;
  KeylessApiConfigView? get before => _expected?.view;
  String get connectionId => after.connectionId;
  bool _used = false;
  @override
  String toString() => 'KeylessApiConfigTerminalPlan';
}

final class KeylessTerminalEffectDispatch {
  KeylessTerminalEffectDispatch._(this._permit);
  final KeylessTerminalEffectPermit _permit;
  KeylessApiConfigTerminalPlan get plan => _permit._plan;
  bool get isCurrent => !_permit._dispatched && _permit.current;
  void dispatch() {
    if (!isCurrent) throw const KeylessApiConfigException();
    _permit._dispatched = true;
  }

  @override
  String toString() => 'KeylessTerminalEffectDispatch';
}

/// Private construction, exact owner/plan, once dispatch AND once native consume.
/// This cannot authorize a POST, another plan, a replay or an Undo.
final class KeylessTerminalEffectPermit {
  KeylessTerminalEffectPermit._(this._plan);
  final KeylessApiConfigTerminalPlan _plan;
  KeylessTerminalNativeCustody? _custody;
  bool _dispatched = false,
      _consumed = false,
      _closed = false,
      _checking = false;
  bool get current {
    if (_checking) _closed = true;
    if (_closed) return false;
    _checking = true;
    try {
      final accepted = _consumed
          ? _custody!.isRootCurrent
          : _plan._owner._admission.isCurrent(_plan);
      if (!accepted) _closed = true;
      return !_closed;
    } catch (_) {
      _closed = true;
      return false;
    } finally {
      _checking = false;
    }
  }

  Future<void> admitAtMutationStart() async {
    if (_dispatched || _consumed || !current) {
      throw const KeylessApiConfigException();
    }
    await _plan._owner._admission.admit(KeylessTerminalEffectDispatch._(this));
    if (!_dispatched || !current) throw const KeylessApiConfigException();
  }

  bool consume({
    required KeylessApiConfigTerminalPlan plan,
    required KeylessTerminalNativeCustody custody,
  }) {
    if (!identical(plan, _plan) ||
        !_dispatched ||
        _consumed ||
        !current ||
        !custody.isRootCurrent ||
        !current) {
      return false;
    }
    _consumed = true;
    _custody = custody;
    return current;
  }

  @override
  String toString() => 'KeylessTerminalEffectPermit';
}

/// Narrow per-native-context owner. Production composes exactly the native
/// connection confirmation port; executable callbacks cannot come from JSON.
final class KeylessApiConfigTerminalEffectOwner {
  KeylessApiConfigTerminalEffectOwner({
    required this._repo,
    required this._admission,
  });
  final ApiConfigRepo _repo;
  final KeylessTerminalEffectAdmissionPort _admission;

  KeylessApiConfigTerminalPlan create(KeylessApiConfigDraft draft) =>
      KeylessApiConfigTerminalPlan._(this, draft, null, null, draft.view);
  KeylessApiConfigTerminalPlan update(
    KeylessApiConfigObservation expected,
    KeylessApiConfigPatch patch,
  ) => KeylessApiConfigTerminalPlan._(
    this,
    null,
    expected,
    patch,
    patch.applyTo(expected.view),
  );

  Future<KeylessApiConfigReceipt?> execute(KeylessApiConfigTerminalPlan plan) {
    if (!identical(plan._owner, this) || plan._used) return Future.value(null);
    plan._used =
        true; // Before any injected port; failed attempts never replay.
    final permit = KeylessTerminalEffectPermit._(plan);
    return _repo._runKeyless<KeylessApiConfigReceipt>(
      plan.connectionId,
      () => _admission.isCurrent(plan),
      (current, stamp, operation) => plan._draft != null
          ? _repo._createKeyless(plan._draft, current, stamp)
          : _repo._updateKeyless(
              plan._expected!,
              plan._patch!,
              current,
              stamp,
              operation.native,
            ),
      (receipt, revision) => _repo._publishKeyless(receipt, revision),
      terminalPlan: plan,
      terminalPermit: permit,
    );
  }
}
