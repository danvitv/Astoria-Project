import 'dart:async';

import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';

/// Explicit fixture-only native ownership and verified key absence. This is NOT
/// evidence for real vault custody; real ApiConfigRepo CAS/persistence executes.
final class AppControlMemoryMutationPort implements KeylessNativeMutationPort {
  Object _revision = Object();
  final Object _zone = Object();
  _AppControlMemoryLease? _active;
  bool admit = true;
  Future<void> Function()? beforeAcquire;
  int releases = 0;

  @override
  Object? revisionFor(String connectionId) =>
      _active == null ? _revision : null;

  @override
  Future<KeylessNativeMutationLease?> acquire({
    required String connectionId,
    required bool Function() isCurrent,
  }) async {
    final before = _revision;
    await beforeAcquire?.call();
    if (!admit || _active != null || before != _revision || !isCurrent()) {
      return null;
    }
    return _active = _AppControlMemoryLease(this, before, isCurrent);
  }

  void Function() onMutationStarted() {
    final owned = Zone.current[_zone];
    void fence() {
      _revision = Object();
      if (!identical(owned, _active)) _active?.invalidated = true;
    }

    fence();
    return fence;
  }
}

final class _AppControlMemoryLease implements KeylessNativeMutationLease {
  _AppControlMemoryLease(this.port, this.priorRevision, this.original);
  final AppControlMemoryMutationPort port;
  @override
  final Object priorRevision;
  final bool Function() original;
  bool invalidated = false, released = false;
  Object? _settlement;
  @override
  bool get isCurrent =>
      !released && !invalidated && identical(port._active, this) && original();
  @override
  bool get nativeOwned => true;
  @override
  bool get allowsModelChange => true; // Explicit synthetic verified absence.
  @override
  Future<T> runObservedMutation<T>(Future<T> Function() operation) async {
    if (!isCurrent) throw const KeylessApiConfigException();
    return runZoned(operation, zoneValues: {port._zone: this});
  }

  @override
  Future<void> release() async {
    if (released) throw const KeylessApiConfigException();
    released = true;
    port.releases++;
    if (identical(port._active, this)) {
      port._active = null;
      port._revision = Object();
      if (!invalidated) _settlement = port._revision;
    }
  }

  @override
  Object? get settlementRevision =>
      released && _settlement == port._revision ? _settlement : null;
}
