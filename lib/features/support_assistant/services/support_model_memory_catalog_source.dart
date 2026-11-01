part of 'support_model_service.dart';

/// Local input custody for ONE original native catalog effect, never a source
/// navigation/body grant. Exact confirmation/ROOT/consume precede acquisition;
/// the native queue and repository row/source-manifest CAS still own the write.
final class _ModelMemoryCatalogSourceAccess {
  _ModelMemoryCatalogSourceAccess(_ModelRun run, this.root)
    : service = run.service,
      binding = run.binding,
      originalHistory = run.history,
      database = run.service._db,
      source = run.service._db.nativeDataSourceIdentity,
      permissions = run.service._runtime.permissions,
      retirement = run.service._runtime.captureDataRetirement(),
      token = run.operation.token;

  final _ModelDomainTerminalRoot root;
  final SupportModelService service;
  final _ModelBinding binding;
  final SupportTextContextRepo originalHistory;
  final AppDatabase database;
  final NativeDataSourceIdentity? source;
  final SupportPermissionStore permissions;
  final SupportNativeDataRetirement retirement;
  final CancelToken token;
  bool _spent = false;

  Future<SupportAppSourceLease?> acquire({
    required String domain,
    required String sourceId,
    required Object observation,
    required SupportAppActionContext context,
  }) async {
    if (_spent ||
        domain != 'memory_book' ||
        observation is! MemoryBookControlObservation ||
        sourceId != observation.book.id ||
        !identical(context.sourceAccess, root) ||
        !identical(context.domainRoot, root) ||
        !identical(context.cancelToken, token) ||
        context.sessionId != binding.sessionId ||
        context.readOnlySources) {
      return null;
    }
    final custody = context.nativeDomainCustody;
    final sessionId = observation.book.sessionId;
    if (custody == null ||
        custody.operation != SupportAppDomainOperation.memoryCatalog ||
        custody.request.action !=
            SupportAppDomainOperation.memoryCatalog.action ||
        !identical(custody.request.context, context) ||
        custody.request.target != sessionId ||
        !identical(custody.request.observation, observation) ||
        !context.domainEffectMatches(sessionId, observation) ||
        !context.domainEffectForSession(sessionId)) {
      return null;
    }
    _spent = true; // No replay after failed acquisition, release or settlement.
    final lease = _ModelMemoryCatalogSourceLease(
      this,
      context,
      custody,
      observation,
    );
    if (!lease.isCurrent) return null;
    // Original native permission reader, not the now-cancelled model read gate.
    // It checks the durable global policy and original assistant parent. This
    // grants only local catalog input; no bodies, SQL, paths or tool grants escape.
    final latest = await permissions.readForNative(binding.sessionId);
    if (!lease.isCurrent ||
        !latest.isAvailable ||
        !_samePolicy(binding.policy, latest.preferences) ||
        latest.preferences?.isGlobal != true ||
        latest.preferences?.allows(SupportPermission.readApplicationData) !=
            true) {
      lease.release();
      return null;
    }
    return lease;
  }

  bool get nativeCurrent {
    final runtime = service._runtime;
    try {
      // No renewed requester/model binding. The lease below exempts only this
      // consumed effect's exact game-source retirement, not general data epochs.
      return service._ownerCurrent &&
          identical(service._db, database) &&
          database.hasCompletedOpening &&
          !database.isClosing &&
          source != null &&
          source!.belongsTo(database) &&
          identical(database.nativeDataSourceIdentity, source) &&
          originalHistory.retainsNativeDataSource(source!) &&
          // Explicit original DB settlement-owner withdrawal is denial only;
          // this never treats model liveness as native effect authority.
          root._run.settlementValid &&
          identical(runtime.permissions, permissions) &&
          permissions.repo.usesDatabase(database) &&
          runtime.alive &&
          runtime.sessionId == binding.sessionId &&
          runtime.lifetime == binding.lifetime &&
          runtime.writeOwner == binding.owner &&
          runtime.settingsPending == 0 &&
          runtime.configurationStable() &&
          runtime.configurationRevision() == binding.revision &&
          service._revisions.isStable &&
          service._revisions.revision == binding.revision &&
          identical(service._redaction.redactor, binding.redactor) &&
          _samePolicy(binding.policy, runtime.snapshot.preferences) &&
          !permissions.applicationDataReadDenied &&
          permissions.applicationDataRevocationRevision ==
              binding.applicationDataRevision;
    } catch (_) {
      return false;
    }
  }
}

final class _ModelMemoryCatalogSourceLease implements SupportAppSourceLease {
  _ModelMemoryCatalogSourceLease(
    this.owner,
    this.context,
    this.custody,
    this.observation,
  );
  final _ModelMemoryCatalogSourceAccess owner;
  final SupportAppActionContext context;
  final SupportAppDomainCustody custody;
  final MemoryBookControlObservation observation;
  bool _retired = false;

  @override
  bool get isCurrent {
    if (_retired) return false;
    if (!owner.nativeCurrent ||
        !owner.service._runtime.ownsDataRetirementExceptOwnSource(
          owner.retirement,
          observation.book.sessionId,
        ) ||
        !identical(context.sourceAccess, owner.root) ||
        !identical(context.domainRoot, owner.root) ||
        !identical(context.nativeDomainCustody, custody) ||
        !context.domainEffectForOperation(
          SupportAppDomainOperation.memoryCatalog,
        ) ||
        !context.domainEffectForSession(observation.book.sessionId) ||
        !context.domainEffectMatches(observation.book.sessionId, observation)) {
      _retired = true;
    }
    return !_retired;
  }

  @override
  void release() => _retired = true;
}
