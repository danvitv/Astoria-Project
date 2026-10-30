import '../../../../../core/db/repositories/chat_repo.dart';
import '../../../../../core/services/card_rewriter/effective_canon_assembler.dart';
import '../../../../../core/services/card_rewriter/effective_canon_read_repository.dart';
import '../../../models/support_app_action.dart';
import 'session_memory_guard.dart';

/// Pure effective-canon validation over the actual transactional read owner.
/// No lineage reconciliation, tracker edits, durable claims or rewrite apply.
final class SupportAppCanonAdapter implements SupportAppActionAdapter {
  SupportAppCanonAdapter({
    required this.chats,
    required this.canon,
    required this.guard,
  });
  final ChatRepo chats;
  final EffectiveCanonReadRepository canon;
  final SessionMemoryGuard guard;

  @override
  List<SupportAppActionDefinition> get definitions => [
    SupportAppActionDefinition(
      name: 'astoria_canon_validate',
      description:
          'Validate effective canon assembly locally for one persisted '
          'session. Return only fixed status, decision flag and record counts. '
          'Advisory only: does not repair lineage, approve a rewrite or change canon.',
      risk: SupportAppActionRisk.metadata,
      fields: {'sessionId': const SupportAppActionField.text(128)},
      requiredFields: {'sessionId'},
    ),
  ];

  @override
  Future<SupportAppPreparedAction?> prepare(
    String action,
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  ) async {
    if (action != definitions.single.name ||
        !definitions.single.accepts(arguments)) {
      return null;
    }
    final id = arguments['sessionId']! as String;
    final valid = guard.observe(id, context);
    if (valid == null) return null;
    final session = await chats.getById(id);
    if (session == null || !valid()) return null;
    final input = await canon.read(
      sessionId: id,
      characterId: session.characterId,
    );
    if (!valid()) return null;
    Map<String, Object?> data;
    try {
      final result = const EffectiveCanonAssembler().assemble(
        EffectiveCanonReadRepository.withInitialLineage(input),
      );
      data = {
        'status': 'assembled',
        'requiresBaselineDecision': result.requiresBaselineDecision,
        'lineageCount': input.lineage.length,
        'factCount': input.facts.length,
        'manualControlCount': input.manualControls.length,
        'transitionCount': input.transitions.length,
      };
    } on EffectiveCanonAssemblyUnavailable {
      data = {'status': 'invalid'};
    }
    return SupportAppPreparedAction(
      target: id,
      observation: input,
      observationIsCurrent: valid,
      execute: (current) async => current() && valid()
          ? SupportAppActionOutcome(SupportAppActionCode.completed, data: data)
          : SessionMemoryGuard.interrupted(context),
    );
  }
}
