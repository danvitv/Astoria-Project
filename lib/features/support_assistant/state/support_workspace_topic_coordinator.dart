import 'dart:async';
import '../models/support_workspace_models.dart';
import '../services/support_workspace_send_service.dart';
import 'support_workspace_lifecycle.dart';

/// Immutable admission values, supplied by the reactive owner.
class SupportWorkspaceSendContext {
  const SupportWorkspaceSendContext(
    this.owner,
    this.selection,
    this.sessionId, {
    required this.ready,
  });
  final SupportWorkspaceLifecycle owner;
  final int selection;
  final String sessionId;
  final bool ready;
}

typedef SupportWorkspaceEnqueue =
    Future<bool> Function(
      SupportWorkspaceLifecycle owner,
      Future<void> Function() work, {
      bool Function()? ownsError,
    });

/// One notifier-lifetime coordinator owns topic normalization, supersession,
/// retry and send admission. It has no Riverpod or reactive-state dependency.
class SupportWorkspaceTopicCoordinator {
  SupportWorkspaceTopicCoordinator({
    required this.capture,
    required this.isCurrent,
    required this.enqueue,
    required this.reload,
    required this.inspectConnection,
    required this.invalidateNative,
    required this.selectCreatedSession,
    required this.publish,
    required this.publishHandledTopic,
  });
  final SupportWorkspaceSendContext Function() capture;
  final bool Function(SupportWorkspaceSendContext) isCurrent;
  final SupportWorkspaceEnqueue enqueue;
  final Future<void> Function(SupportWorkspaceLifecycle) reload;
  final Future<bool> Function(String, bool Function()) inspectConnection;
  final void Function() invalidateNative;
  final void Function(String) selectCreatedSession;
  final void Function(SupportWorkspaceLifecycle, SupportMessageItem) publish;
  final void Function(String?) publishHandledTopic;
  int _topicVersion = 0;
  String? _pendingTopic, _handledTopic;
  String? get handledTopic => _handledTopic;

  bool _ownsLifecycle(SupportWorkspaceLifecycle owner) {
    if (!owner.alive) return false;
    final live = capture();
    return identical(owner, live.owner) && isCurrent(live);
  }

  void applyInitialTopic(String? topic) {
    final normalized = switch (topic?.trim().toLowerCase()) {
      null || '' => null,
      'theme' => 'theme_setup',
      'provider' || 'api' => 'provider_setup',
      'memory' => 'memory_books_setup',
      'diagnostics' => 'connection_diagnostics',
      'report' => 'support_report',
      'theme_setup' ||
      'provider_setup' ||
      'memory_books_setup' ||
      'connection_diagnostics' ||
      'support_report' => topic!.trim().toLowerCase(),
      // Unknown route text is not stored in assistant state or session titles.
      _ => 'help',
    };
    if (normalized != _pendingTopic) {
      invalidateNative();
      _pendingTopic = normalized == _handledTopic ? null : normalized;
      _topicVersion++;
    }
    resume();
  }

  void resume() {
    final context = capture(), owner = context.owner;
    if (!isCurrent(context) ||
        _pendingTopic == null ||
        !context.ready ||
        owner.pending > 0 ||
        owner.sending) {
      return;
    }
    unawaited(send(topic: _pendingTopic, initialVersion: _topicVersion));
  }

  Future<bool> send({String? text, String? topic, int? initialVersion}) async {
    final context = capture(), owner = context.owner;
    var id = context.sessionId;
    final initial = initialVersion != null;
    if (!isCurrent(context) ||
        !context.ready ||
        owner.pending > 0 ||
        owner.sending ||
        (!initial && id.isEmpty) ||
        (text != null && text.trim().isEmpty)) {
      return false;
    }
    // Admission is synchronous; two callbacks in the same turn cannot both send.
    owner.sending = true;
    invalidateNative();
    var accepted = false;
    bool current() =>
        isCurrent(context) && (!initial || initialVersion == _topicVersion);
    try {
      await enqueue(owner, () async {
        if (id.isEmpty) {
          id = await owner.store.create('Сессия по теме');
          if (!_ownsLifecycle(owner)) return;
          if (!current()) {
            // Creation already committed. Reconcile it so the newer topic can
            // reuse the durable empty session rather than create another one.
            await reload(owner);
            return;
          }
          selectCreatedSession(id);
          await reload(owner);
          if (!current()) return;
        }
        await SupportWorkspaceSendService(
          store: owner.store,
          isCurrent: current,
          publish: (message) => publish(owner, message),
          acceptUser: () => accepted = true,
          acceptReply: () {
            accepted = true;
            if (initial && current()) {
              _handledTopic = topic;
              _pendingTopic = null;
              publishHandledTopic(topic);
            }
          },
          inspectConnection: inspectConnection,
        ).send(id, text: text, topic: topic);
        if (!_ownsLifecycle(owner)) return;
        await reload(owner);
      }, ownsError: current);
    } finally {
      owner.sending = false;
      if (_ownsLifecycle(owner)) {
        // Do not spin retrying a failed topic. Idle work or an explicit retry can
        // retry it; a newer route topic, however, must run after supersession.
        if (!initial || initialVersion != _topicVersion) {
          resume();
        }
      }
    }
    return accepted;
  }
}
