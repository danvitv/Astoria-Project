import '../../../../../core/db/repositories/chat_repo.dart';
import '../../../models/support_app_action.dart';
import 'support_native_domain_sources.dart';

/// Finite native composition. Repositories still own every domain patch/CAS;
/// this adds only exact ROOT admission and original source/queue lifetime.
final class SupportNativeDomainAdapter implements SupportAppActionAdapter {
  SupportNativeDomainAdapter({
    required this.adapter,
    required this.chats,
    required this.sources,
    this.repairSession,
    this.refreshSession,
  });
  final SupportAppActionAdapter adapter;
  final ChatRepo chats;
  final SupportNativeDomainSources sources;
  final String? Function(String, Map<String, Object?>, SupportAppActionContext)?
  repairSession;
  final Future<bool> Function(String, bool Function())? refreshSession;
  @override
  List<SupportAppActionDefinition> get definitions => adapter.definitions;

  @override
  Future<SupportAppPreparedAction?> prepare(
    String action,
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  ) async {
    final prepared = await adapter.prepare(action, arguments, context);
    if (prepared == null || !context.current) return null;
    final operation = SupportAppDomainOperation.forAction(action);
    if (operation == null || context.domainRoot == null) return prepared;
    final isMemory = action.startsWith('astoria_memory_');
    final isRepair =
        operation == SupportAppDomainOperation.sessionRepair ||
        operation == SupportAppDomainOperation.sessionUndo;
    final queued = isMemory
        ? arguments['sessionId'] as String?
        : isRepair
        ? repairSession?.call(action, arguments, context)
        : null;
    if ((isMemory || isRepair) && queued == null) return null;
    final fresh =
        arguments['operation'] == 'create' &&
        const {
          SupportAppDomainOperation.character,
          SupportAppDomainOperation.persona,
          SupportAppDomainOperation.lorebook,
          SupportAppDomainOperation.preset,
        }.contains(operation);
    final ids = queued != null
        ? <String>[queued]
        : fresh
        ? <String>[]
        : (await chats.getAllSessionMetadata())
              .map((s) => s.sessionId)
              .toList();
    if (!context.current) return null;
    // Content/global configuration can be used by any session. Conservative
    // all-session admission is explicit collateral, never guessed bindings.
    final observed = sources.observe(
      ids,
      queuedSession: queued,
      allowMaintenance: isRepair,
    );
    if (observed == null) return null;
    return SupportAppPreparedAction(
      target: prepared.target,
      observation: prepared.observation,
      observationIsCurrent: () =>
          context.current &&
          observed.current &&
          prepared.observationIsCurrent(),
      preview: {
        ...prepared.preview,
        'sourceSessionsFenced': ids.length,
        'existingNativeOwners': observed.owners.length,
        'nativeSourceFence': true,
      },
      execute: (admitted) async {
        if (!admitted() || !observed.current) {
          return SupportAppActionOutcome(SupportAppActionCode.stale);
        }
        final dispatch = await context.admitDomainEffect(
          operation: operation,
          target: prepared.target,
          observation: prepared.observation,
        );
        if (dispatch == null || !admitted() || !observed.current) {
          return SupportAppActionOutcome(SupportAppActionCode.stale);
        }
        final custody = dispatch.consume();
        if (custody == null)
          return SupportAppActionOutcome(SupportAppActionCode.stale);
        final scope = observed.begin(
          custody,
        ); // synchronous BEFORE any effect await
        if (scope == null || !context.bindDomainEffect(custody, scope)) {
          scope?.settle();
          custody.close();
          return SupportAppActionOutcome(SupportAppActionCode.stale);
        }
        try {
          Future<SupportAppActionOutcome> effect() async {
            if (!scope.isCurrent)
              return SupportAppActionOutcome(SupportAppActionCode.stale);
            if (queued == null && !fresh) {
              // Resolve the latest related session inventory in the native owner
              // before effect. New/removed sessions change confirmed collateral;
              // do not silently extend the already-admitted fence or plan.
              final latest = (await chats.getAllSessionMetadata())
                  .map((s) => s.sessionId)
                  .toSet();
              if (!scope.isCurrent ||
                  latest.length != ids.toSet().length ||
                  !latest.containsAll(ids)) {
                return SupportAppActionOutcome(SupportAppActionCode.conflict);
              }
            }
            return prepared.execute(() => scope.isCurrent);
          }

          // Repair runtime already uses this ORIGINAL queue. Never nest run().
          final outcome = await (isRepair ? effect() : scope.run(effect));
          if (outcome.effect != SupportAppActionEffect.persisted)
            return outcome;
          var refreshed = false;
          try {
            refreshed = await scope.refreshLatest();
          } catch (_) {
            /* Keep fact. */
          }
          if (queued != null && refreshSession != null) {
            try {
              refreshed =
                  await refreshSession!(queued, () => scope.isCurrent) &&
                  refreshed;
            } catch (_) {
              refreshed = false;
            }
          }
          return SupportAppActionOutcome(
            outcome.code,
            effect: outcome.effect,
            data: {
              ...outcome.data,
              'refreshPending':
                  !refreshed ||
                  (!isRepair && outcome.data['refreshPending'] == true),
            },
          );
        } finally {
          context.closeDomainEffect();
        }
      },
    );
  }
}
