import 'dart:async';

import '../credentials/native_provider_credentials.dart';
import '../db/repositories/api_config_repo.dart';
import '../models/api_config.dart';

/// Constructor-owned bridge; neither repository nor tools can resolve a key.
/// Retains one original native lease through the repository's TRUE outer commit.
final class NativeProviderKeylessMutationBridge
    implements KeylessNativeMutationPort {
  NativeProviderKeylessMutationBridge({
    required this.mutations,
    required this.credentials,
    required this.readSavedConnection,
    required this.isRootCurrent,
  });

  final NativeConnectionMutationOwner mutations;
  final NativeProviderCredentialVault credentials;
  final Future<ApiConfig?> Function(String) readSavedConnection;
  final bool Function() isRootCurrent;
  NativeConnectionStamp? _cachedRevision;

  bool _current(bool Function() caller) {
    try {
      return isRootCurrent() && caller() && isRootCurrent();
    } catch (_) {
      return false;
    }
  }

  @override
  Object? revisionFor(String connectionId) {
    if (!_current(() => true) || !mutations.isStable) return null;
    final cached = _cachedRevision;
    if (cached != null && mutations.isCurrent(cached)) return cached;
    return _cachedRevision = mutations.observe();
  }

  @override
  Future<KeylessNativeMutationLease?> acquire({
    required String connectionId,
    required bool Function() isCurrent,
  }) async {
    final prior = revisionFor(connectionId);
    if (prior is! NativeConnectionStamp) return null;
    bool preflightCurrent() =>
        _current(isCurrent) && mutations.isCurrent(prior);
    try {
      if (!preflightCurrent()) return null;
      final presence = await credentials.inspectNativePresence(
        connectionId: connectionId,
        isCurrent: preflightCurrent,
      );
      if (!preflightCurrent()) return null;
      final saved = await readSavedConnection(connectionId);
      if (!preflightCurrent()) return null;
      var owned = false;
      final hasKey = presence == NativeProviderCredentialPresence.present;
      if (presence == NativeProviderCredentialPresence.present) {
        if (saved == null) return null;
        final state = await credentials.inspectNativeOwnership(
          saved: saved,
          isCurrent: preflightCurrent,
        );
        if (!preflightCurrent() ||
            state != NativeProviderCredentialState.ready) {
          return null;
        }
        owned = true;
      } else if (presence == NativeProviderCredentialPresence.prepared) {
        if (saved == null) {
          return null; // Orphan marker is NOT a retried create.
        }
      } else if (presence != NativeProviderCredentialPresence.absent) {
        return null; // Unknown/corrupt/disabled is never positive absence.
      }
      final admission = mutations.admit(
        expected: prior,
        // Original policy, NOT the prior epoch invalidated by our own fence.
        isOriginalOwner: () => _current(isCurrent),
      );
      if (admission == null) return null;
      final ready = Completer<_NativeKeylessLease?>();
      _NativeKeylessLease? held;
      final ownerDone = mutations.runOwned<void>(
        admission: admission,
        operation: (native) async {
          // Protected preparation is deliberately BEFORE DB create. Failure can
          // leave only a deny-only orphan marker, never a legacy-dispatchable row.
          if (saved == null) {
            final latest = await readSavedConnection(connectionId);
            if (!native.isCurrent || latest != null) {
              throw const KeylessApiConfigException();
            }
            await credentials.markPreparedForNativeCreate(
              lease: native,
              connectionId: connectionId,
            );
            if (!native.isCurrent) throw const KeylessApiConfigException();
            owned = true;
          } else if (presence == NativeProviderCredentialPresence.prepared) {
            final latest = await readSavedConnection(connectionId);
            if (!native.isCurrent || latest == null) {
              throw const KeylessApiConfigException();
            }
            owned = await credentials.isPreparedNativeOwned(
              lease: native,
              saved: latest,
            );
            if (!native.isCurrent || !owned) {
              throw const KeylessApiConfigException();
            }
          }
          final lease = _NativeKeylessLease(
            this,
            native,
            prior,
            owned,
            !hasKey,
          );
          held = lease;
          ready.complete(lease);
          await lease._releaseRequested.future;
        },
      );
      unawaited(
        ownerDone.then<void>(
          (_) {
            final lease = held;
            if (lease == null) {
              if (!ready.isCompleted) ready.complete(null);
              return;
            }
            final original = lease.native.settlementStamp;
            if (original != null &&
                mutations.isCurrent(original) &&
                _current(() => true)) {
              lease._originalSettlement = original;
              _cachedRevision = original;
            }
            lease._settled.complete();
          },
          onError: (Object _, StackTrace _) {
            if (!ready.isCompleted) ready.complete(null);
            final lease = held;
            if (lease != null) {
              lease._failed = true;
              lease._settled.complete();
            }
          },
        ),
      );
      return await ready.future;
    } catch (_) {
      return null; // No DB effect has been admitted; never forward secret causes.
    }
  }
}

final class _NativeKeylessLease implements KeylessNativeMutationLease {
  _NativeKeylessLease(
    this.bridge,
    this.native,
    this.priorRevision,
    this.nativeOwned,
    this.allowsModelChange,
  );
  final NativeProviderKeylessMutationBridge bridge;
  final NativeConnectionOperationLease native;
  @override
  final NativeConnectionStamp priorRevision;
  @override
  final bool nativeOwned;
  @override
  final bool allowsModelChange; // Original verified private-key absence only.
  final _releaseRequested = Completer<void>();
  final _settled = Completer<void>();
  NativeConnectionStamp? _originalSettlement;
  bool _failed = false;

  @override
  bool get isCurrent =>
      native.isCurrent && bridge._current(() => true) && native.isCurrent;

  @override
  Future<T> runObservedMutation<T>(Future<T> Function() operation) =>
      native.runObservedMutation(operation);

  @override
  Future<void> release() async {
    if (!_releaseRequested.isCompleted) _releaseRequested.complete();
    await _settled.future; // Includes the native owner's original finally.
    if (_failed) throw const KeylessApiConfigException();
  }

  @override
  Object? get settlementRevision {
    final original = _originalSettlement;
    return _settled.isCompleted &&
            !_failed &&
            original != null &&
            bridge._current(() => true) &&
            bridge.mutations.isCurrent(original)
        ? original
        : null; // NEVER observe/mint a replacement stamp here.
  }
}

/// Actual decoded row/normalized proposal checks happen inside the held zone.
/// A label never proves absence or selects a credential. An already observed
/// ordinary-only fact must still match the actual decoded mutation target.
final class NativeProviderOrdinaryMutationGuard
    implements ApiConfigOrdinaryMutationGuard {
  NativeProviderOrdinaryMutationGuard({
    required this.mutations,
    required this.credentials,
    required this.isRootCurrent,
  });
  final NativeConnectionMutationOwner mutations;
  final NativeProviderCredentialVault credentials;
  final bool Function() isRootCurrent;
  final Object _zoneKey = Object();

  bool _rootCurrent() {
    try {
      return isRootCurrent();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<T> run<T>({
    required String connectionId,
    required Future<T> Function() operation,
  }) async {
    if (!_rootCurrent()) throw const KeylessApiConfigException();
    final absence = credentials.observedOrdinaryAbsence(connectionId);
    if (absence != null) {
      // Only an already observed exact-slot absence admits original ordinary DB
      // custody. No native lease/entry/dispatch authority survives retirement.
      try {
        return await runZoned(operation, zoneValues: {_zoneKey: absence});
      } catch (_) {
        throw const KeylessApiConfigException();
      }
    }
    final stamp = mutations.observe();
    if (stamp == null || !_rootCurrent()) {
      throw const KeylessApiConfigException();
    }
    final admission = mutations.admit(
      expected: stamp,
      isOriginalOwner: _rootCurrent,
    );
    if (admission == null) throw const KeylessApiConfigException();
    try {
      return await mutations.runOwned<T>(
        admission: admission,
        operation: (lease) => lease.runObservedMutation(
          () => runZoned(operation, zoneValues: {_zoneKey: lease}),
        ),
      );
    } catch (_) {
      throw const KeylessApiConfigException();
    }
  }

  NativeConnectionOperationLease _held() {
    final lease = Zone.current[_zoneKey];
    if (lease is! NativeConnectionOperationLease ||
        !_rootCurrent() ||
        !lease.isCurrent) {
      throw const KeylessApiConfigException();
    }
    return lease;
  }

  @override
  Future<void> beforePut({
    required ApiConfig? existing,
    required ApiConfig proposed,
  }) {
    final held = Zone.current[_zoneKey];
    if (credentials.isObservedOrdinaryAbsence(held, proposed.id)) {
      return Future<void>.value();
    }
    return credentials.guardOrdinaryPut(
      lease: _held(),
      existing: existing,
      proposed: proposed,
    );
  }

  @override
  Future<void> beforeDelete(String id) {
    if (credentials.isObservedOrdinaryAbsence(Zone.current[_zoneKey], id)) {
      return Future<void>.value();
    }
    return credentials.guardOrdinaryDelete(lease: _held(), connectionId: id);
  }
}
