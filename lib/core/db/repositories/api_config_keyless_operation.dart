part of 'api_config_repo.dart';

extension _KeylessOwnedOperation on ApiConfigRepo {
  Future<T?> _runKeyless<T>(
    String id,
    bool Function() isCurrent,
    Future<T> Function(bool Function(), int, _KeylessOperation) work,
    void Function(T, Object?) publish,
  ) async {
    KeylessNativeMutationLease? held;
    _KeylessOperation? operation;

    Future<void> releaseNative() async {
      final release = held;
      held = null; // No second release/retry, including throw-after-settlement.
      if (release != null) await release.release();
    }

    void releaseProof() {
      final proof = operation?.proof;
      if (operation != null) operation.proof = null;
      proof?.release();
    }

    try {
      // Refuse caller-owned outer transactions: the fence must own true commit.
      // ignore: invalid_use_of_internal_member
      _requireKeyless(_db.resolvedEngine.executor is! TransactionExecutor);
      final beforeStamp = _keyless.stamp;
      var ownFenceStarted = false;
      bool admission() =>
          isCurrent() && _keyless.pending == 0 && _keyless.stamp == beforeStamp;
      // NativeOwner retains this guard for the whole lease. Its own repo fence
      // must not make that guard false; competing revisions still deny.
      bool originalOwner() {
        if (!isCurrent()) return false;
        if (!ownFenceStarted) {
          return _keyless.pending == 0 && _keyless.stamp == beforeStamp;
        }
        return (_keyless.pending == 1 && _keyless.stamp == beforeStamp + 1) ||
            (_keyless.pending == 0 && _keyless.stamp == beforeStamp + 2);
      }

      _requireKeyless(admission());
      final port = _keylessMutations;
      _requireKeyless(port != null);
      final lease = await port!.acquire(
        connectionId: id,
        isCurrent: originalOwner,
      );
      held = lease;
      _requireKeyless(admission() && lease != null && lease.isCurrent);
      final nativeLease = lease!;
      operation = _KeylessOperation(nativeLease);

      // Awaiting acquire does NOT propagate the owner's zone to this caller.
      // Both observer hooks and the true outer DB transaction belong inside it.
      final outcome = await nativeLease.runObservedMutation<_KeylessRunResult<T>>(
        () async {
          try {
            ownFenceStarted = true;
            final finish = _keyless.start(_mutationHook, native: true);
            try {
              final fenceStamp = beforeStamp + 1;
              bool current() =>
                  isCurrent() &&
                  _keyless.pending == 1 &&
                  _keyless.stamp == fenceStamp &&
                  nativeLease.isCurrent &&
                  operation!.proofCurrent;
              _requireKeyless(current());
              final result = await _db.transaction(() async {
                _requireKeyless(current());
                final result = await work(current, beforeStamp, operation!);
                _requireKeyless(current());
                return result;
              });
              return _KeylessRunResult<T>.success(result);
            } finally {
              finish(); // Even rollback/failure settlement stays in the owner zone.
            }
          } on _KeylessRefused {
            return _KeylessRunResult<T>.refused();
          } on _KeylessUndoConflict {
            return _KeylessRunResult<T>.refused();
          }
        },
      );

      // Already committed fact/custody survives retirement; no new admission at
      // result delivery. Await the original owner finally BEFORE receipt issuance.
      await releaseNative();
      releaseProof();
      if (!outcome.accepted) return null;
      final result = outcome.value as T;
      publish(result, nativeLease.settlementRevision);
      return result;
    } on _KeylessRefused {
      return null;
    } on _KeylessUndoConflict {
      return null;
    } catch (_) {
      throw const KeylessApiConfigException();
    } finally {
      try {
        await releaseNative();
      } catch (_) {
        throw const KeylessApiConfigException();
      } finally {
        try {
          releaseProof();
        } catch (_) {
          throw const KeylessApiConfigException();
        }
      }
    }
  }
}

/// Carry a known rolled-back refusal across the native owner's fixed-error
/// boundary without exporting private repository exceptions into that wrapper.
final class _KeylessRunResult<T> {
  const _KeylessRunResult.success(this.value) : accepted = true;
  const _KeylessRunResult.refused() : accepted = false, value = null;
  final bool accepted;
  final T? value;
}
