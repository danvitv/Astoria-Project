import '../../../core/utils/id_generator.dart';
import '../models/support_workspace_models.dart';
import 'support_local_reply_service.dart';
import 'support_workspace_store.dart';

class SupportReplyUnavailable extends StateError {
  SupportReplyUnavailable() : super('Reply unavailable');
}

/// Publish each durable append independently, including a user-only success.
class SupportWorkspaceSendService {
  const SupportWorkspaceSendService({
    required this.store,
    required this.isCurrent,
    required this.publish,
    required this.acceptUser,
    required this.acceptReply,
    required this.inspectConnection,
  });
  final SupportWorkspaceStore store;
  final bool Function() isCurrent;
  final void Function(SupportMessageItem) publish;
  final void Function() acceptUser, acceptReply;
  final Future<bool> Function(String, bool Function()) inspectConnection;
  static const _replies = SupportLocalReplyService();

  Future<void> send(String id, {String? text, String? topic}) async {
    final runId =
        generateId(); // Original native send, never renewed after await.
    SupportMessageItem? originatingUser;
    await store.settingsFor(
      id,
    ); // Own local preferences readiness, not API metadata.
    if (!isCurrent()) return;
    if (text != null) {
      final user = await store.appendNativeLocalUser(
        id,
        text,
        runId: runId,
        isCurrent: isCurrent,
      );
      originatingUser = user;
      acceptUser(); // Durable acceptance survives switch, rebuild or disposal.
      if (!isCurrent()) return;
      publish(user);
    }
    final selectedTopic = topic ?? _replies.topicForText(text!);
    // Proposing setup never inspects a connection. Only this explicit native
    // diagnostic topic retains its separately authorized metadata reader.
    if (selectedTopic == 'connection_diagnostics') {
      await inspectConnection(id, isCurrent);
      if (!isCurrent()) return;
    }
    final SupportMessageItem reply;
    try {
      final fixed = _replies.reply(id, selectedTopic, text: text);
      reply = originatingUser == null
          // A topic-only click has no durable USER. Do not invent/backfill an
          // origin or misclassify it as a provenance-backed composer response.
          ? await store.append(fixed)
          : await store.appendNativeLocalReply(
              fixed,
              originatingUser: originatingUser,
              isCurrent: isCurrent,
            );
    } catch (_) {
      if (text != null) throw SupportReplyUnavailable();
      rethrow;
    }
    // Only a current topic can be consumed, even if an older append committed.
    if (!isCurrent()) return;
    publish(reply);
    acceptReply();
  }
}
