import 'dart:async';

import '../../../../../core/db/app_db.dart';
import '../../../../../core/db/repositories/chat_repo.dart';
import '../../../../chat/state/chat_native_owner_registry.dart';
import '../../../../chat/state/chat_session_write_queue.dart';
import '../../../models/support_app_action.dart';

/// Actual process-local native maintenance owners, not ChatNotifier substitutes.
/// Constructors perform no private reads. Claims capture inventory synchronously;
/// the owning repository proves strict idle source in the ORIGINAL owned queue.
final class SupportNativeSessionMaintenanceOwners {
  SupportNativeSessionMaintenanceOwners({
    required this.db,
    required this.chats,
    required this.owners,
    required this.original,
    required this.captureJobInventory,
  });
  final AppDatabase db;
  final ChatRepo chats;
  final ChatNativeOwnerRegistry owners;
  final bool Function() original;
  final bool Function()? Function(String session) captureJobInventory;
  final _claims = <String, SupportNativeSessionMaintenanceOwner>{};
  bool _disposed = false;
  bool get current =>
      !_disposed && original() && owners.isCurrent && chats.usesDatabase(db);

  SupportNativeSessionMaintenanceOwner? resolve(
    String session,
    SupportAppActionContext context,
  ) {
    if (!current) return null;
    final retained = _claims[session];
    if (retained != null &&
        retained.current &&
        identical(retained.context, context))
      return retained;
    if (retained != null) {
      // Never replace actual admitted effect custody with a fresh request.
      if (retained.admitted) return null;
      retained.retire();
      if (retained._queued != 0) return null;
    }
    if (!context.current ||
        owners.loaded.any(
          (o) =>
              o.sessionId() == null || !o.isIdle() || o.sessionId() == session,
        ))
      return null;
    final jobs = captureJobInventory(
      session,
    ); // Exact native inventory BEFORE await.
    if (jobs == null || !jobs()) return null;
    if (_claims.length >= 64) {
      final idle = _claims.values
          .where((o) => !o.admitted && o._queued == 0)
          .firstOrNull;
      if (idle == null) return null;
      idle.retire();
    }
    final claim = SupportNativeSessionMaintenanceOwner._(
      this,
      session,
      context,
      owners.revision,
      List.unmodifiable(owners.loaded),
      jobs,
    );
    _claims[session] = claim;
    claim._unregister = owners.registerMaintenance(claim);
    return claim;
  }

  SupportNativeSessionMaintenanceOwner? existing(String session) {
    final claim = _claims[session];
    return claim != null && claim.current && claim.proven ? claim : null;
  }

  SupportNativeSessionMaintenanceOwner? claimForQueue(
    String session,
    ChatSessionWriteQueue queue,
  ) {
    final claim = _claims[session];
    return claim != null && claim.current && identical(claim.queue, queue)
        ? claim
        : null;
  }

  void queuedStarted(String session, ChatSessionWriteQueue queue) {
    claimForQueue(session, queue)?._queuedStarted();
  }

  void queuedSettled(String session, ChatSessionWriteQueue queue) {
    final claim = _claims[session];
    if (claim != null && identical(claim.queue, queue)) claim._queuedSettled();
  }

  Future<void> settleOwnedWork() => Future.wait<void>([
    for (final claim in _claims.values.toList()) claim.queue.settle(),
  ]).then<void>((_) {});
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final claim in _claims.values.toList()) {
      claim.retire();
    }
  }
}

/// One native source/queue claim binds this actual AppDatabase, original run and
/// Astoria parent, exact session/character/raw generation/selection observation.
/// The core plan/receipt separately retains head, canon and manual revision CAS.
final class SupportNativeSessionMaintenanceOwner
    implements ChatNativeMaintenanceBarrier {
  SupportNativeSessionMaintenanceOwner._(
    this.owner,
    this.session,
    this.context,
    this.inventoryRevision,
    this.inventory,
    this._jobsCurrent,
  );
  final SupportNativeSessionMaintenanceOwners owner;
  final String session;
  final SupportAppActionContext context;
  final int inventoryRevision;
  final List<ChatNativeOwner> inventory;
  final bool Function() _jobsCurrent;
  final queue = ChatSessionWriteQueue();
  ChatNativeMaintenanceSource? _source;
  SupportAppDomainCustody? _custody;
  final _effectSettled = Completer<void>();
  void Function()? _unregister;
  bool _retired = false;
  int _queued = 0;
  Completer<void>? _queuedSettlement;
  bool get admitted => _custody != null && !_effectSettled.isCompleted;
  bool get proven => _source != null;
  String? get characterId => _source?.characterId;
  NativeDataSourceIdentity? _databaseIdentity;
  bool get nativeCurrent {
    if (_retired ||
        !owner.current ||
        !_jobsCurrent() ||
        (_databaseIdentity != null &&
            !_databaseIdentity!.belongsTo(owner.db))) {
      retire();
      return false;
    }
    if (admitted) return true; // Replacement registrations await effectSettled.
    if (owner.owners.revision != inventoryRevision ||
        inventory.any(
          (o) =>
              o.sessionId() == null ||
              !o.isIdle() ||
              o.sessionId() == session ||
              (characterId != null && o.characterId == characterId),
        )) {
      retire();
      return false;
    }
    return true;
  }

  bool get current {
    if (!nativeCurrent) return false;
    if (admitted ? !_custody!.isCurrent : !context.current) {
      retire();
      return false;
    }
    return true;
  }

  Future<bool> validateQueuedSource() async {
    if (!current) return false;
    final latest = await owner.chats.readNativeMaintenanceSource(
      session,
      () => current,
    );
    if (!current ||
        latest == null ||
        inventory.any((o) => o.characterId == latest.characterId) ||
        (_source != null && !_source!.sameOriginal(latest))) {
      // Read fault/unknown source is not an idle default or automatic retry.
      if (!admitted) retire();
      return false;
    }
    _source ??= latest;
    _databaseIdentity ??= owner.db.nativeDataSourceIdentity;
    return true;
  }

  bool admit(SupportAppDomainCustody custody) {
    // consume() deliberately retired context.current. This accepts only the
    // identical native request of this original run, never a replacement run.
    if (!nativeCurrent ||
        !proven ||
        admitted ||
        !custody.isCurrent ||
        !identical(custody.request.context, context) ||
        !const {
          SupportAppDomainOperation.sessionRepair,
          SupportAppDomainOperation.sessionUndo,
        }.contains(custody.operation))
      return false;
    _custody = custody;
    return true;
  }

  @override
  Future<void>? beforeLiveOwner() {
    if (admitted) return _effectSettled.future;
    retire(); // A loading/live registration revokes all pre-admission claims.
    return _queued > 0 ? _queuedSettlement!.future : null;
  }

  void _queuedStarted() {
    if (_queued++ == 0) _queuedSettlement = Completer<void>();
  }

  void _queuedSettled() {
    if (_queued == 0 || --_queued != 0) return;
    _queuedSettlement?.complete();
    if (_retired && !admitted) _remove();
  }

  void retire() {
    _retired = true;
    if (!admitted && _queued == 0) _remove();
  }

  void settleEffect() {
    // Called by the native source scope ONLY after original queue work joined.
    if (!_effectSettled.isCompleted) _effectSettled.complete();
    _retired = true;
    _remove();
  }

  void _remove() {
    _unregister?.call();
    _unregister = null;
    if (identical(owner._claims[session], this)) owner._claims.remove(session);
  }
}
