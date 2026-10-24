import 'package:glaze_flutter/core/application/chat_source_mutation_registry.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_app_action.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/content/support_content_mutation.dart';

/// No default acceptance callback: a test must supply an original native gesture
/// for one exact call/arguments/context, just as the production sheet must.
final class ContentNativeGesture
    implements SupportAppConfirmationPort, SupportContentMutationPort {
  ContentNativeGesture(this.registry);
  final ChatSourceMutationRegistry registry;
  String? _action;
  Map<String, Object?>? _arguments;
  SupportAppActionContext? _context;
  SupportAppConfirmationLease? accepted;
  SupportAppConfirmationRequest? request;
  bool uiCurrent = true;
  int begins = 0, settlements = 0;
  Future<void> Function(SupportAppConfirmationRequest)? beforeGesture;
  void Function()? afterBegin;

  void gesture({
    required String action,
    required Map<String, Object?> arguments,
    required SupportAppActionContext original,
  }) {
    _action = action;
    _arguments = Map.unmodifiable(arguments);
    _context = original;
  }

  @override
  Future<SupportAppConfirmationLease?> confirm(
    SupportAppConfirmationRequest original,
  ) async {
    request = original;
    await beforeGesture?.call(original);
    final expected = _arguments;
    final matches =
        original.action == _action &&
        identical(original.context, _context) &&
        expected != null &&
        expected.length == original.arguments.length &&
        expected.entries.every((e) => original.arguments[e.key] == e.value);
    _action = null;
    _arguments = null;
    _context = null;
    if (!matches || !uiCurrent || !original.current) return null;
    return accepted = SupportAppConfirmationLease(
      request: original,
      isOriginalUiCurrent: () => uiCurrent,
    );
  }

  @override
  SupportContentMutationLease? begin({
    required SupportContentDomain domain,
    required String target,
    required Object observation,
    required SupportAppActionContext context,
  }) {
    final lease = accepted;
    if (lease == null ||
        !lease.current ||
        !identical(lease.request.context, context) ||
        !identical(lease.request.observation, observation) ||
        lease.request.target != '${domain.name}:$target' ||
        registry.isDisposed)
      return null;
    // Synthetic native source target from THIS test gesture, never a tool arg
    // or fabricated sourceAccess grant. This exercises the real primitive fence.
    const sourceId = 'synthetic-native-content-source';
    final settle = registry.beginMutation(sessionId: sourceId);
    begins++;
    final checkpoint = registry.sessionCheckpoint(sourceId);
    afterBegin?.call();
    return _ContentFence(lease, registry, checkpoint, () {
      settle();
      settlements++;
    });
  }
}

final class _ContentFence implements SupportContentMutationLease {
  _ContentFence(this.gesture, this.registry, this.checkpoint, this.finish);
  final SupportAppConfirmationLease gesture;
  final ChatSourceMutationRegistry registry;
  final Object? checkpoint;
  final void Function() finish;
  bool settled = false;
  @override
  bool get isCurrent =>
      !settled &&
      gesture.current &&
      !registry.isDisposed &&
      identical(
        checkpoint,
        registry.sessionCheckpoint('synthetic-native-content-source'),
      );
  @override
  void settle() {
    if (settled) return;
    settled = true;
    finish();
  }
}
