part of 'support_native_active_selection_adapter.dart';

final class _SelectionPlan {
  const _SelectionPlan(this.port, this.observed, this.next, this.desiredRow,
      this.inventory, this.collateral, this.targetsCurrent,
      this.target, this.retained, this.journal);
  final NativeActiveSelectionPort port;
  final NativeActiveSelectionObservation observed;
  final String? next;
  final Object? desiredRow;
  final ChatNativeSelectionInventory inventory;
  final SupportNativeDomainObservation collateral;
  final bool Function() targetsCurrent;
  final String target;
  final _RetainedSelection? retained;
  final SupportMutationReservation? journal;
  bool get undo => retained != null;
}

final class _RetainedSelection {
  _RetainedSelection(this.parent, this.receipt, this.journal,
      this.sourceCurrent, this.inventory, this.targetsCurrent);
  final String parent;
  final NativeActiveSelectionReceipt receipt;
  final SupportMutationReservation journal;
  final bool Function() sourceCurrent;
  final ChatNativeSelectionInventory inventory;
  final bool Function() targetsCurrent;
  bool _retired = false;
  bool get current {
    if (_retired) return false;
    if (!receipt.current || !sourceCurrent() || !inventory.current ||
        !targetsCurrent()) _retired = true;
    return !_retired;
  }
}

extension _SelectionRetention on SupportNativeActiveSelectionAdapter {
  /// Capture only this already-admitted all-session fence's own events and
  /// publications. Never adopt a later observer or reconstruct a disposed scope.
  bool Function()? _retainedSources(_SelectionPlan plan,
      SupportAppActionContext context) {
    final revision = plan.collateral.ownerRevision;
    final events = <String, Object>{};
    final owners = <String, Object>{};
    final publications = <String, int>{};
    for (final session in plan.inventory.sessions) {
      if (!context.domainEffectForSession(session)) return null;
      final event = sources.mutations.sessionCheckpoint(session);
      if (event == null) return null;
      events[session] = event;
      final owner = plan.collateral.owners[session];
      if (owner != null) {
        final publication = context.domainPublication(session);
        if (publication == null) return null;
        owners[session] = owner;
        publications[session] = publication;
      }
    }
    bool current() => _current && plan.inventory.current && plan.targetsCurrent() &&
        sources.owners.revision == revision &&
        events.entries.every((e) =>
            identical(e.value, sources.mutations.sessionCheckpoint(e.key))) &&
        owners.entries.every((e) {
          final actual = sources.owners.existing(e.key);
          return identical(actual, e.value) && actual != null &&
              sources.owners.retains(actual, e.key) &&
              actual.queue.isCurrentPublication(publications[e.key]!);
        });
    return current() ? current : null;
  }
}
