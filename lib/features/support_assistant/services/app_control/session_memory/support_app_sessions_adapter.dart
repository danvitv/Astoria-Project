import '../../../../../core/db/repositories/chat_repo.dart';
import '../../../models/support_app_action.dart';
import 'session_memory_guard.dart';

/// Persisted roleplay metadata, not ChatNotifier hydration or UI selection.
/// Mutation definitions are absent until the shared chat queue/gen owner is a
/// trusted public port; index-only calls cannot serve as that authority.
final class SupportAppSessionsAdapter implements SupportAppActionAdapter {
  SupportAppSessionsAdapter({required this.repo, required this.guard});
  final ChatRepo repo;
  final SessionMemoryGuard guard;

  @override
  List<SupportAppActionDefinition> get definitions => [
    SupportAppActionDefinition(
      name: 'astoria_roleplay_inspect',
      description:
          'Inspect one persisted roleplay session or its stable message '
          'IDs and variation counts. Never reads a title, preview or message body '
          'into the result; does not hydrate or select a chat.',
      risk: SupportAppActionRisk.metadata,
      fields: {
        'sessionId': const SupportAppActionField.text(128),
        'view': SupportAppActionField.choice(['session', 'messages']),
        'offset': const SupportAppActionField.integer(0, 1000000),
        'limit': const SupportAppActionField.integer(1, 16),
      },
      requiredFields: {'sessionId', 'view'},
    ),
  ];

  @override
  Future<SupportAppPreparedAction?> prepare(
    String action,
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  ) async {
    if (action != definitions.single.name ||
        !definitions.single.accepts(arguments))
      return null;
    final id = arguments['sessionId']! as String;
    final valid = guard.observe(id, context);
    if (valid == null) return null;
    final session = await repo.getById(id);
    if (!valid() || session == null) return null;
    final offset = arguments['offset'] as int? ?? 0;
    final limit = arguments['limit'] as int? ?? 16;
    final data = arguments['view'] == 'session'
        ? <String, Object?>{
            'sessionId': session.id,
            'characterId': session.characterId,
            'sessionIndex': session.sessionIndex,
            'messageCount': session.messages.length,
            'status': 'persisted',
          }
        : <String, Object?>{
            'sessionId': session.id,
            'messageCount': session.messages.length,
            'offset': offset,
            'messages': session.messages
                .skip(offset)
                .take(limit)
                .map(
                  (m) => <String, Object?>{
                    'messageId': m.id,
                    'swipeId': m.swipeId,
                    'agentSwipeId': m.agentSwipeId,
                    'swipeCount': m.swipes.length,
                    'hidden': m.isHidden,
                  },
                )
                .toList(growable: false),
            'truncated': session.messages.length > offset + limit,
          };
    return SupportAppPreparedAction(
      target: id,
      observation: session,
      observationIsCurrent: valid,
      execute: (current) async => current() && valid()
          ? SupportAppActionOutcome(SupportAppActionCode.completed, data: data)
          : SessionMemoryGuard.interrupted(context),
    );
  }
}
