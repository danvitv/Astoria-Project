import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'chat_session_write_queue.dart';
import 'chat_native_session_title_port.dart';

/// Separate native maintenance custody, never a loaded ChatNotifier. Its
/// barrier belongs to the actual admitted queued effect, not a persisted lease.
abstract interface class ChatNativeMaintenanceBarrier {
  Future<void>? beforeLiveOwner();
}

/// Original loaded controllers register here. Looking up a target never builds
/// a chat, loads preferences, repairs a row or manufactures an offline queue.
final class ChatNativeOwner {
  ChatNativeOwner({
    required this.characterId,
    required this.sessionId,
    required this.isIdle,
    required this.queue,
    required this.refresh,
    this.titles,
  });
  final String characterId;
  final String? Function() sessionId;
  final bool Function() isIdle;
  final ChatSessionWriteQueue queue;

  /// The admitted source guard must be checked after reads and before cache or
  /// state publication; queue publication alone cannot detect history renames.
  final Future<bool> Function(
    String sessionId,
    int publication,
    bool Function() sourceCurrent,
  )
  refresh;
  final ChatNativeSessionTitlePort? titles;
}

final class ChatNativeOwnerRegistry {
  final _owners = <Object, ChatNativeOwner>{};
  final _maintenance = <ChatNativeMaintenanceBarrier>{};
  final _registrationBarriers = <ChatNativeOwner, List<Future<void>>>{};
  bool _disposed = false;
  int _revision = 0;
  bool get isCurrent => !_disposed;
  int get revision => _revision;
  void Function() register(ChatNativeOwner owner) {
    if (_disposed) return () {};
    final barriers =
        fenceMaintenance(); // Synchronous BEFORE first build await.
    final key = Object();
    _owners[key] = owner;
    _registrationBarriers[owner] = barriers;
    _revision++;
    return () {
      _registrationBarriers.remove(owner);
      if (_owners.remove(key) != null) _revision++;
    };
  }

  void Function() registerMaintenance(ChatNativeMaintenanceBarrier owner) {
    if (_disposed) return () {};
    _maintenance.add(owner);
    return () => _maintenance.remove(owner);
  }

  List<Future<void>> fenceMaintenance() => [
    for (final owner in _maintenance.toList())
      if (owner.beforeLiveOwner() case final Future<void> barrier) barrier,
  ];
  Future<void>? awaitRegistration(ChatNativeOwner owner) {
    final pending =
        _registrationBarriers.remove(owner) ?? const <Future<void>>[];
    return pending.isEmpty
        ? null
        : Future.wait<void>(pending).then<void>((_) {});
  }

  Future<void>? beforeSessionSelection() {
    // Native intent, before the first switch/branch await. A warm owner going
    // A -> B -> A must not renew a previously painted source/Undo observation.
    _revision++;
    final pending = fenceMaintenance();
    return pending.isEmpty
        ? null
        : Future.wait<void>(pending).then<void>((_) {});
  }

  List<ChatNativeOwner> get loaded =>
      _disposed ? const [] : List.unmodifiable(_owners.values);
  ChatNativeOwner? existing(String session) {
    final matches = loaded.where((o) => o.sessionId() == session).toList();
    return matches.length == 1 && matches.single.isIdle()
        ? matches.single
        : null;
  }

  bool retains(ChatNativeOwner owner, String session) =>
      !_disposed &&
      _owners.values.any((o) => identical(o, owner)) &&
      owner.sessionId() == session &&
      owner.isIdle();
  void dispose() {
    _disposed = true;
    _revision++;
    for (final owner in _maintenance.toList()) {
      owner.beforeLiveOwner();
    }
    _owners.clear();
    _registrationBarriers.clear();
    _maintenance.clear();
  }
}

final chatNativeOwnerRegistryProvider = Provider<ChatNativeOwnerRegistry>((
  ref,
) {
  final owner = ChatNativeOwnerRegistry();
  ref.onDispose(owner.dispose);
  return owner;
});
