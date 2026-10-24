import '../../../../../core/application/chat_source_mutation_registry.dart';
import '../../../../chat/state/chat_native_owner_registry.dart';
import '../../../../chat/state/chat_session_write_queue.dart';
import '../../../models/support_app_action.dart';
import 'support_native_session_maintenance_owner.dart';

/// Source admission has no private reader or model/network authority.
final class SupportNativeDomainSources {
  SupportNativeDomainSources({
    required this.mutations,
    required this.owners,
    required this.isOriginalOwnerCurrent,
    this.maintenance,
  });
  final ChatSourceMutationRegistry mutations;
  final ChatNativeOwnerRegistry owners;
  final bool Function() isOriginalOwnerCurrent;
  final SupportNativeSessionMaintenanceOwners? maintenance;

  SupportNativeDomainObservation? observe(
    Iterable<String> sessions, {
    String? queuedSession,
    bool allowMaintenance = false,
  }) {
    if (!isOriginalOwnerCurrent() || mutations.isDisposed || !owners.isCurrent)
      return null;
    final checkpoints = <String, Object>{};
    final native = <String, ChatNativeOwner>{};
    final offline = <String, SupportNativeSessionMaintenanceOwner>{};
    for (final id in sessions.toSet()) {
      final checkpoint = mutations.sessionCheckpoint(id);
      if (checkpoint == null || mutations.isSessionPending(id)) return null;
      checkpoints[id] = checkpoint;
      final loaded = owners.loaded.where((o) => o.sessionId() == id).toList();
      if (loaded.isNotEmpty) {
        final owner = owners.existing(id);
        if (owner == null)
          return null; // Existing running owner is not replaced.
        native[id] = owner;
      }
    }
    if (queuedSession != null && !native.containsKey(queuedSession)) {
      if (!allowMaintenance) return null;
      final owner = maintenance?.existing(queuedSession);
      if (owner == null) return null;
      offline[queuedSession] = owner;
    }
    return SupportNativeDomainObservation._(
      this,
      checkpoints,
      native,
      queuedSession,
      offline,
    );
  }
}

final class SupportNativeDomainObservation {
  SupportNativeDomainObservation._(
    this.sources,
    this.checkpoints,
    this.owners,
    this.queuedSession,
    this.maintenanceOwners,
  ) : ownerRevision = sources.owners.revision;
  final SupportNativeDomainSources sources;
  final Map<String, Object> checkpoints;
  final Map<String, ChatNativeOwner> owners;
  final String? queuedSession;
  final Map<String, SupportNativeSessionMaintenanceOwner> maintenanceOwners;
  final int ownerRevision;
  bool _began = false;
  bool get current =>
      !_began &&
      sources.isOriginalOwnerCurrent() &&
      !sources.mutations.isDisposed &&
      sources.owners.isCurrent &&
      sources.owners.revision == ownerRevision &&
      checkpoints.entries.every(
        (e) =>
            !sources.mutations.isSessionPending(e.key) &&
            identical(e.value, sources.mutations.sessionCheckpoint(e.key)),
      ) &&
      owners.entries.every((e) => sources.owners.retains(e.value, e.key)) &&
      maintenanceOwners.values.every((o) => o.nativeCurrent && o.proven);

  SupportNativeDomainScope? begin(SupportAppDomainCustody custody) {
    if (!current || !custody.isCurrent) return null;
    _began = true; // The once-consumed capsule precedes ALL source fences.
    final finishes = <void Function()>[];
    final events = <String, Object>{};
    final publications = <String, int>{};
    try {
      for (final owner in maintenanceOwners.values) {
        if (!owner.admit(custody)) throw StateError('Native owner retired');
      }
      for (final id in checkpoints.keys) {
        finishes.add(sources.mutations.beginMutation(sessionId: id));
        events[id] = sources.mutations.sessionCheckpoint(id)!;
        final owner = owners[id];
        if (owner != null) publications[id] = owner.queue.beginPublication();
        final maintenance = maintenanceOwners[id];
        if (maintenance != null)
          publications[id] = maintenance.queue.beginPublication();
      }
      final scope = SupportNativeDomainScope._(
        this,
        custody,
        events,
        publications,
        finishes,
      );
      if (scope.isCurrent) return scope;
    } catch (_) {
      /* No exception or private source text leaves this port. */
    }
    for (final finish in finishes.reversed) {
      finish();
    }
    for (final owner in maintenanceOwners.values) {
      owner.settleEffect();
    }
    return null;
  }
}

final class SupportNativeDomainScope implements SupportAppDomainSourceLease {
  SupportNativeDomainScope._(
    this.observation,
    this.custody,
    this.events,
    this.publications,
    this.finishes,
  );
  final SupportNativeDomainObservation observation;
  final SupportAppDomainCustody custody;
  final Map<String, Object> events;
  final Map<String, int> publications;
  final List<void Function()> finishes;
  bool _closed = false, _retired = false;
  @override
  bool get isCurrent {
    if (_closed || _retired) return false;
    final sources = observation.sources;
    if (!custody.isCurrent ||
        !sources.isOriginalOwnerCurrent() ||
        sources.mutations.isDisposed ||
        !sources.owners.isCurrent ||
        (observation.maintenanceOwners.isEmpty &&
            sources.owners.revision != observation.ownerRevision) ||
        !events.entries.every(
          (e) => identical(e.value, sources.mutations.sessionCheckpoint(e.key)),
        ) ||
        !observation.owners.entries.every(
          (e) => sources.owners.retains(e.value, e.key),
        ) ||
        !observation.maintenanceOwners.values.every(
          (o) => o.current && o.admitted,
        )) {
      _retired = true;
    }
    return !_retired;
  }

  @override
  bool coversSession(String id) => events.containsKey(id);
  @override
  int? publicationForSession(String id) => publications[id];
  ChatSessionWriteQueue? get queue => observation.queuedSession == null
      ? null
      : observation.owners[observation.queuedSession]?.queue ??
            observation.maintenanceOwners[observation.queuedSession]?.queue;
  Future<T> run<T>(Future<T> Function() effect) {
    final owner = queue;
    return owner == null ? effect() : owner.run(effect);
  }

  Future<bool> refreshLatest() async {
    // A dormant owner has no ChatState to reload. Do not manufacture a UI-cache
    // refresh success from absence; retained durable facts report refreshPending.
    var refreshed = observation.maintenanceOwners.isEmpty;
    for (final entry in observation.owners.entries) {
      if (!isCurrent ||
          !entry.value.queue.isCurrentPublication(publications[entry.key]!)) {
        refreshed = false;
        continue;
      }
      refreshed =
          await entry.value.refresh(entry.key, publications[entry.key]!) &&
          refreshed;
    }
    return refreshed;
  }

  @override
  void settle() {
    if (_closed) return;
    _closed = true;
    for (final finish in finishes.reversed) {
      finish();
    }
    for (final owner in observation.maintenanceOwners.values) {
      owner.settleEffect();
    }
  }
}
