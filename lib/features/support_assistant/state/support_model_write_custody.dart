import '../services/support_model_service.dart';

/// Container-local native durable FIFO. Do NOT attach the workspace's broad
/// display/local-help operation tail: old display/crypto reads must not monopolize
/// original settlement. No preview, context reads, HTTP or SSE is enqueued here.
final class SupportModelDurableWrites implements SupportModelWriteScheduler {
  final _queue = SupportModelWriteQueue();
  final _services = <SupportModelService>{};
  Object _publicationStamp = Object();

  /// Display-read barrier only; not a SQL stamp, permission or dispatch authority.
  Object get publicationStamp => _publicationStamp;

  @override
  Future<T> enqueue<T>(Future<T> Function() write) => _queue.enqueue(() async {
    try {
      return await write();
    } finally {
      _publicationStamp = Object();
    }
  });

  void retain(SupportModelService service) => _services.add(service);
  void release(SupportModelService service) => _services.remove(service);

  /// Fence synchronously, before a queued deletion, including selected history.
  void invalidateMessage(String sessionId, String messageId) {
    for (final service in List.of(_services)) {
      service.invalidateMessage(sessionId, messageId);
    }
  }

  void invalidateSession(String sessionId) {
    for (final service in List.of(_services)) {
      service.invalidateSession(sessionId);
    }
  }

  /// Forward to ALL original retained services, including disposed issuers
  /// awaiting their original terminal DB write. Never use support deletion here.
  void invalidateGameSource({
    required String sessionId,
    Set<String>? messageIds,
  }) {
    final ids = messageIds == null
        ? null
        : Set<String>.unmodifiable(messageIds);
    for (final service in List.of(_services)) {
      service.invalidateGameSource(sessionId: sessionId, messageIds: ids);
    }
  }
}

/// Original DB lifetime, independent of reactive service/workspace replacement.
/// Retain disposed services until their original terminal write has unwound.
final class SupportModelDatabaseCustody implements SupportModelWriteScheduler {
  SupportModelDatabaseCustody(this.writes);
  final SupportModelDurableWrites writes;
  final _services = <SupportModelService>{};
  bool _alive = true;
  bool get alive => _alive;

  void retain(SupportModelService service) {
    _services.add(service);
    writes.retain(service);
    if (!_alive) service.revokeSettlementOwner();
  }

  void release(SupportModelService service) {
    _services.remove(service);
    writes.release(service);
  }

  @override
  Future<T> enqueue<T>(Future<T> Function() write) => writes.enqueue(() {
    if (!_alive) throw StateError('Original support data owner unavailable.');
    return write();
  });

  /// ONLY the provider owning the original appDb calls this on destruction.
  void revoke() {
    if (!_alive) return;
    _alive = false;
    for (final service in List.of(_services)) {
      service.revokeSettlementOwner();
    }
  }
}
