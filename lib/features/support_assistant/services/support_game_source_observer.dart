import '../../../core/application/chat_source_mutation_registry.dart';
import '../models/support_permission_scope.dart';
import 'support_native_runtime.dart';

/// Observes only an already-created native owner and primitive source metadata.
/// No Ref, source read, recipient refresh, durable queue or replacement lookup.
final class SupportGameSourceObserver {
  SupportGameSourceObserver({
    required this.registry,
    required this.runtime,
    required this.invalidateGameSource,
  }) {
    _unsubscribe = registry.subscribe(_changed);
    _unlisten = runtime.listen(reconcile);
    reconcile(); // No replay: sample primitive pending metadata only.
  }

  final ChatSourceMutationRegistry registry;
  final SupportNativeRuntime runtime;
  final void Function({required String sessionId, Set<String>? messageIds})
  invalidateGameSource;
  late final void Function() _unsubscribe, _unlisten;
  bool _active = true, _blocked = false, _reconciling = false, _again = false;
  bool _registryRetired = false;

  bool get isStable =>
      _active && runtime.alive && !registry.isDisposed && !_blocked;

  SupportPermissionScope? get _scope => runtime.snapshot.preferences?.scope;

  bool _affects(ChatSourceMutationChange change) {
    final scope = _scope;
    if (scope == null || scope.gameSessionId == null || !scope.hasGameHistory) {
      return false;
    }
    return scope.gameHistoryExtent == SupportHistoryExtent.wholeSession
        ? change.sessionId == scope.gameSessionId
        : change.affects(
            sessionId: scope.gameSessionId!,
            messageIds: scope.gameHistory!.messageIds,
          );
  }

  bool _sourcePending(SupportPermissionScope? scope) =>
      scope != null &&
      scope.gameSessionId != null &&
      scope.hasGameHistory &&
      (scope.gameHistoryExtent == SupportHistoryExtent.wholeSession
          ? registry.isSessionPending(scope.gameSessionId!)
          : registry.isPending(
              sessionId: scope.gameSessionId!,
              messageIds: scope.gameHistory!.messageIds,
            ));

  void _changed(ChatSourceMutationChange change) {
    if (!_active || !runtime.alive) return;
    if (change.phase == ChatSourceMutationPhase.began) {
      // Original retained services may describe a source no longer selected by
      // this runtime. Their own immutable game binding decides cancellation.
      final affects = _affects(change);
      if (affects) {
        _setBlocked(true);
        _retire();
      }
      if (!_active || !runtime.alive) return;
      invalidateGameSource(
        sessionId: change.sessionId,
        messageIds: change.messageIds,
      );
    }
    reconcile(); // Settlement balances pending, NEVER renews old authority.
  }

  void _setBlocked(bool value) {
    if (_blocked == value) return;
    _blocked = value;
    runtime.pending += value ? 1 : -1;
  }

  void _retire() {
    if (!_active || !runtime.alive) return;
    runtime.retireGameSourceIntents();
    if (!_active || !runtime.alive) return;
    runtime.invalidateLease(); // Data epoch only; keep recipient/write custody.
  }

  /// Also called before native admission and before runtime notifications. This
  /// closes selection-into-pending and silent registry-disposal gaps without DB
  /// loads. Reentry can change the selection/dispose this owner during notify.
  void reconcile() {
    if (!_active || !runtime.alive) return;
    if (_reconciling) {
      _again = true;
      return;
    }
    _reconciling = true;
    try {
      do {
        _again = false;
        final scope = _scope;
        final disposed = registry.isDisposed;
        final pending = disposed || _sourcePending(scope);
        final changed = pending != _blocked;
        final retire =
            (pending && !_blocked) || (disposed && !_registryRetired);
        _registryRetired = disposed;
        _setBlocked(pending);
        if (retire) {
          _retire();
        } else if (changed) {
          runtime.notify();
        }
      } while (_again && _active && runtime.alive);
    } finally {
      _reconciling = false;
    }
  }

  /// Must run BEFORE original runtime disposal. Remove only our contribution;
  /// other queued permission/settings contributions remain independently owned.
  void dispose() {
    if (!_active) return;
    _active = false;
    _unsubscribe();
    _unlisten();
    _setBlocked(false);
  }
}
