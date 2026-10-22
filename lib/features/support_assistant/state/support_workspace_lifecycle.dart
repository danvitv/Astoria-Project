import '../services/support_workspace_store.dart';

/// A build owns its store and serial write tail, never a replacement build's.
class SupportWorkspaceLifecycle {
  SupportWorkspaceLifecycle(this.epoch, this.store);
  final int epoch;
  final SupportWorkspaceStore store;
  Future<void> tail = Future.value();
  bool alive = true;
  bool sending = false;
  int pending = 0;
}
