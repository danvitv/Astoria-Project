part of 'support_native_global_regex_adapter.dart';

final class _GlobalRegexPlan {
  const _GlobalRegexPlan(
    this.port,
    this.observed,
    this.inventory,
    this.collateral,
    this.target,
    this.retained,
    this.journal,
    this.beforeEvidence,
    this.afterEvidence,
  );
  final NativeGlobalRegexPort port;
  final NativeGlobalRegexObservation observed;
  final ChatNativeSelectionInventory inventory;
  final SupportNativeDomainObservation collateral;
  final String target, beforeEvidence, afterEvidence;
  final _RetainedGlobalRegex? retained;
  final SupportMutationReservation? journal;
  bool get undo => retained != null;
}

final class _RetainedGlobalRegex {
  _RetainedGlobalRegex(
    this.parent,
    this.receipt,
    this.journal,
    this.sourceCurrent,
    this.inventory,
  );
  final String parent;
  final NativeGlobalRegexReceipt receipt;
  final SupportMutationReservation journal;
  final bool Function() sourceCurrent;
  final ChatNativeSelectionInventory inventory;
  bool _retired = false;
  bool get current {
    if (_retired) return false;
    if (!receipt.current || !sourceCurrent() || !inventory.current)
      _retired = true;
    return !_retired;
  }
}

extension _GlobalRegexRetention on SupportNativeGlobalRegexAdapter {
  /// Only the once-admitted all-session fence's OWN events/publications survive.
  /// This is retained native custody, never renewed read/body/source authority.
  bool Function()? _retainedSources(
    _GlobalRegexPlan plan,
    SupportAppActionContext context,
  ) {
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
    bool current() =>
        _current &&
        plan.port.current &&
        plan.inventory.current &&
        sources.owners.revision == revision &&
        events.entries.every(
          (e) => identical(e.value, sources.mutations.sessionCheckpoint(e.key)),
        ) &&
        owners.entries.every((e) {
          final actual = sources.owners.existing(e.key);
          return identical(actual, e.value) &&
              actual != null &&
              sources.owners.retains(actual, e.key) &&
              actual.queue.isCurrentPublication(publications[e.key]!);
        });
    return current() ? current : null;
  }
}
