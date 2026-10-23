import '../models/support_workspace_models.dart';

/// Captured native display owner. Not an authorized model-context reader.
final class SupportModelWorkspaceCapture {
  const SupportModelWorkspaceCapture({
    required this.sessionId,
    required this.ready,
    required this.isCurrent,
    required this.publish,
  });
  final String sessionId;
  final bool ready;
  final bool Function() isCurrent;
  final void Function(SupportMessageItem) publish;
  bool get current {
    try {
      return isCurrent();
    } catch (_) {
      return false;
    }
  }
}

/// Downward event port avoids workspace/model-provider import cycles. No DB,
/// credential or context read. The workspace supplies only safe presentation.
final class SupportModelWorkspaceBinding {
  SupportModelWorkspaceCapture Function()? _capture;
  void Function()? _resumeLocal;
  Object? _workspace, _claim;
  bool _alive = true;
  final _listeners = <void Function()>{};
  bool get busy => _claim != null;

  Object attach({
    required SupportModelWorkspaceCapture Function() capture,
    required void Function() resumeLocal,
  }) {
    final token = Object();
    _workspace = token;
    _capture = capture;
    _resumeLocal = resumeLocal;
    _notify();
    return token;
  }

  void detach(Object token) {
    if (!identical(_workspace, token)) return;
    _workspace = null;
    _capture = null;
    _resumeLocal = null;
    _notify();
  }

  SupportModelWorkspaceCapture? capture() {
    if (!_alive) return null;
    final token = _workspace, captured = _capture?.call();
    if (captured == null || token == null) return null;
    return SupportModelWorkspaceCapture(
      sessionId: captured.sessionId,
      ready: captured.ready && !busy,
      isCurrent: () =>
          _alive && identical(token, _workspace) && captured.current,
      publish: captured.publish,
    );
  }

  bool claim(Object token) {
    if (!_alive || busy) return false;
    _claim = token;
    _notify();
    return true;
  }

  void release(Object token) {
    if (!identical(token, _claim)) return;
    _claim = null;
    _notify();
    try {
      _resumeLocal?.call();
    } catch (_) {
      /* Local observer cannot own terminal custody. */
    }
  }

  void Function() listen(void Function() listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void _notify() {
    for (final listener in List.of(_listeners)) {
      if (!_listeners.contains(listener)) continue;
      try {
        listener();
      } catch (_) {
        /* Observation cannot own admission. */
      }
    }
  }

  void dispose() {
    _alive = false;
    _workspace = null;
    _capture = null;
    _resumeLocal = null;
    _notify();
    _listeners.clear();
  }
}
