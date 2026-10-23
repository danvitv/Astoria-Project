part of 'support_workspace_provider.dart';

/// An original native display, not a session ID or restorable write capability.
final class SupportWorkspaceSettingsIntent {
  SupportWorkspaceSettingsIntent._(this._notifier, this._current);
  final SupportWorkspaceNotifier _notifier;
  final bool Function() _current;

  bool get isCurrent {
    try {
      return _current();
    } catch (_) {
      return false;
    }
  }

  @override
  String toString() => 'SupportWorkspaceSettingsIntent';
}
