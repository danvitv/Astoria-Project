/// An admission event, not a durable change log. No message bodies are retained.
enum ChatSourceMutationPhase { began, settled }

/// Exact admission checkpoint captured before any synchronous observer can
/// start another mutation. Settlement never restores the checkpoint's currency.
final class ChatSourceMutationAdmission {
  ChatSourceMutationAdmission._(this.checkpoint, this.settle);
  final Object? checkpoint;
  final void Function() settle;
}

final class ChatSourceMutationChange {
  ChatSourceMutationChange({
    required this.sessionId,
    required Set<String>? messageIds,
    required this.phase,
  }) : messageIds = messageIds == null
           ? null
           : Set<String>.unmodifiable(messageIds);

  final String sessionId;

  /// Null means the entire session source; otherwise only these stable IDs.
  final Set<String>? messageIds;
  final ChatSourceMutationPhase phase;

  bool affects({
    required String sessionId,
    required Iterable<String> messageIds,
  }) =>
      this.sessionId == sessionId &&
      (this.messageIds == null || messageIds.any(this.messageIds!.contains));
}

/// Container-local, feature-free intent fences. Begin happens at acceptance,
/// before a queue, prerequisite await, or optimistic publication. A settlement
/// only closes pending work: it never restores authority retired by begin.
final class ChatSourceMutationRegistry {
  final _pending = <Object, ChatSourceMutationChange>{};
  final _listeners = <Object, void Function(ChatSourceMutationChange)>{};
  final _sessionEvents = <String, Object>{};
  final Object _initialSessionEvent = Object();
  bool _disposed = false;

  bool get isDisposed => _disposed;

  /// Original process-local admission checkpoint, including mutations that have
  /// already settled. It neither reads a source nor restores old authority.
  Object? sessionCheckpoint(String sessionId) =>
      _disposed ? null : _sessionEvents[sessionId] ?? _initialSessionEvent;

  bool isSessionPending(String sessionId) =>
      _disposed || _pending.values.any((c) => c.sessionId == sessionId);

  /// Fail closed for an expired lifetime, including retained old references.
  bool isPending({
    required String sessionId,
    required Iterable<String> messageIds,
  }) {
    if (_disposed) return true;
    final selectedIds = messageIds.toSet();
    return _pending.values.any(
      (change) => change.affects(sessionId: sessionId, messageIds: selectedIds),
    );
  }

  /// No initial callback, reads, or lazy feature construction. Throwing listeners
  /// cannot prevent other listeners or abort the accepted ordinary mutation.
  /// Unsubscribe is once-only and suppresses undispatched snapshot callbacks.
  void Function() subscribe(void Function(ChatSourceMutationChange) listener) {
    if (_disposed) return () {};
    final key = Object();
    _listeners[key] = listener;
    return () => _listeners.remove(key);
  }

  /// The returned settlement must be called in finally, around the ENTIRE
  /// accepted operation (including its queue wait and failure restoration).
  /// Nested leases are independent. Empty session/ID plans are silent. Pending
  /// work is tracked even without observers, allowing a later live subscriber
  /// to check admission without replaying events or loading source bodies.
  void Function() beginMutation({
    required String sessionId,
    Set<String>? messageIds,
  }) => beginObservedMutation(
    sessionId: sessionId,
    messageIds: messageIds,
  ).settle;

  ChatSourceMutationAdmission beginObservedMutation({
    required String sessionId,
    Set<String>? messageIds,
  }) {
    if (_disposed || sessionId.isEmpty)
      return ChatSourceMutationAdmission._(null, () {});
    final ids = messageIds?.where((id) => id.isNotEmpty).toSet();
    if (ids != null && ids.isEmpty)
      return ChatSourceMutationAdmission._(null, () {});
    final key = Object();
    final change = ChatSourceMutationChange(
      sessionId: sessionId,
      messageIds: ids,
      phase: ChatSourceMutationPhase.began,
    );
    _pending[key] = change;
    final checkpoint = Object();
    _sessionEvents[sessionId] = checkpoint;
    _notify(change);
    var settled = false;
    return ChatSourceMutationAdmission._(checkpoint, () {
      if (settled) return;
      settled = true;
      if (_disposed) return;
      _pending.remove(key);
      _notify(
        ChatSourceMutationChange(
          sessionId: change.sessionId,
          messageIds: change.messageIds,
          phase: ChatSourceMutationPhase.settled,
        ),
      );
    });
  }

  /// Permanently retires this lifetime. Old writes/settlements/subscriptions
  /// cannot revive it or notify a replacement registry. Does not cancel writes.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _listeners.clear();
    _pending.clear();
    _sessionEvents.clear();
  }

  void _notify(ChatSourceMutationChange change) {
    for (final entry in _listeners.entries.toList()) {
      if (_disposed || !_listeners.containsKey(entry.key)) continue;
      try {
        entry.value(change);
      } on Object {
        // Observation must not change ordinary write behavior or leak errors.
      }
    }
  }
}
