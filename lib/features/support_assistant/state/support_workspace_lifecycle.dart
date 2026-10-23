import '../services/support_workspace_store.dart';

/// A build owns its LOCAL operation tail, never a replacement build's. Native
/// model durable writes have separate original-DB custody; no preview/HTTP here.
class SupportWorkspaceLifecycle {
  SupportWorkspaceLifecycle(this.epoch, this.store);
  final int epoch;
  final SupportWorkspaceStore store;
  Future<void> tail = Future.value();
  bool alive = true;
  bool sending = false;
  int pending = 0;
}
