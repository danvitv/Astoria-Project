import '../models/support_workspace_models.dart';
import '../services/support_native_runtime.dart';
import 'support_model_workspace_binding.dart';
import 'support_workspace_state.dart';

/// Safe display attachment/projection only. Never reads history for the model.
/// All reactive values are constructor-injected by the workspace owner.
final class SupportModelWorkspaceAttachment {
  const SupportModelWorkspaceAttachment({
    required this.native,
    required this.readState,
    required this.readSelection,
    required this.isOwnerCurrent,
    required this.isWritePending,
    required this.publish,
  });
  final SupportNativeRuntime native;
  final SupportWorkspaceState Function() readState;
  final int Function() readSelection;
  final bool Function() isOwnerCurrent, isWritePending;
  final void Function(SupportMessageItem) publish;

  SupportModelWorkspaceCapture capture() {
    final state = readState(), selection = readSelection();
    final id = state.activeSessionId, lifetime = native.lifetime;
    return SupportModelWorkspaceCapture(
      sessionId: id,
      ready:
          !state.isLoading &&
          !state.isBusy &&
          !isWritePending() &&
          id.isNotEmpty &&
          state.settingsAvailable &&
          state.activeSession?.isLocked != true,
      isCurrent: () =>
          isOwnerCurrent() &&
          selection == readSelection() &&
          readState().activeSessionId == id &&
          native.alive &&
          native.sessionId == id &&
          native.lifetime == lifetime,
      publish: publish,
    );
  }

  /// An update replaces in-place. A newly committed row uses native time/ID
  /// ordering, including the monotonic user/reply timestamps allocated by S.
  static Map<String, List<SupportMessageItem>> mergeDurable(
    Map<String, List<SupportMessageItem>> bySession,
    SupportMessageItem message,
  ) {
    final updated = List<SupportMessageItem>.of(
      bySession[message.sessionId] ?? const [],
    );
    final index = updated.indexWhere((m) => m.id == message.id);
    if (index >= 0) {
      updated[index] = message;
    } else {
      updated.add(message);
      updated.sort((a, b) {
        final time = a.createdAt.compareTo(b.createdAt);
        return time != 0 ? time : a.id.compareTo(b.id);
      });
    }
    return Map.unmodifiable({
      ...bySession,
      message.sessionId: List<SupportMessageItem>.unmodifiable(updated),
    });
  }
}
