import '../../../../../core/application/chat_source_mutation_registry.dart';
import '../../../models/support_app_action.dart';

/// Only chat admission checkpoints, not a fabricated native source lease or a
/// generation token. Memory writes retain their own repository CAS ownership.
final class SessionMemoryGuard {
  SessionMemoryGuard(this.mutations);
  final ChatSourceMutationRegistry mutations;

  bool Function()? observe(String sessionId, SupportAppActionContext context) {
    if (!context.current || mutations.isSessionPending(sessionId)) return null;
    final checkpoint = mutations.sessionCheckpoint(sessionId);
    if (checkpoint == null) return null;
    bool ownNativeEffect() =>
        context.domainEffectForSession(sessionId) &&
        const [
          SupportAppDomainOperation.memoryCreate,
          SupportAppDomainOperation.memorySettings,
          SupportAppDomainOperation.memoryDraft,
          SupportAppDomainOperation.memoryCatalog,
        ].any(context.domainEffectForOperation);
    return () =>
        ownNativeEffect() ||
        (context.current &&
            !mutations.isSessionPending(sessionId) &&
            identical(checkpoint, mutations.sessionCheckpoint(sessionId)) &&
            context.current);
  }

  static SupportAppActionOutcome interrupted(
    SupportAppActionContext context, {
    bool persisted = false,
  }) => SupportAppActionOutcome(
    context.cancelToken.isCancelled
        ? SupportAppActionCode.cancelled
        : SupportAppActionCode.stale,
    effect: persisted
        ? SupportAppActionEffect.persisted
        : SupportAppActionEffect.none,
  );

  static String status(String value, Set<String> allowed) =>
      allowed.contains(value) ? value : 'unknown';
}
