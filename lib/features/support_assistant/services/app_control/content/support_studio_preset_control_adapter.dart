import '../../../../../core/db/repositories/studio_preset_repo.dart';
import '../../../../../core/models/studio_config.dart';
import '../../../../../core/llm/studio_controller_ontology.dart';
import '../../../../studio/studio_agent_toggle.dart';
import '../../../models/support_app_action.dart';
import 'support_content_mutation.dart';
import 'support_content_text_arguments.dart';

enum SupportStudioPresetOperation { clone, rename, historyLimit }

enum SupportStudioBlockOperation { create, editText, settings }

/// Studio table only. All persisted edits are next-turn inputs, not an attempt
/// to replace an already resolved StudioTurnConfigSnapshot or live controllers.
final class SupportStudioPresetControlAdapter
    implements SupportAppActionAdapter {
  const SupportStudioPresetControlAdapter({
    required this.repo,
    required this.mutations,
    required this.newId,
    required this.clock,
    required this.refresh,
  });
  final StudioPresetRepo repo;
  final SupportContentMutation mutations;
  final String Function() newId;
  final int Function() clock;
  final void Function() refresh;

  @override
  List<SupportAppActionDefinition> get definitions => [
    SupportAppActionDefinition(
      name: 'astoria_studio_preset_manage',
      description:
          'Clone an exact saved Studio preset, rename it, or set final history limit for the next turn. Ordinary presets are a separate domain.',
      risk: SupportAppActionRisk.configuration,
      fields: {
        'operation': SupportAppActionField.choice(
          SupportStudioPresetOperation.values.map((o) => o.name),
        ),
        'id': SupportContentArguments.id,
        'name': SupportContentTextArguments.name,
        'limit': const SupportAppActionField.integer(0, 1000),
      },
      requiredFields: {'operation', 'id'},
    ),
    SupportAppActionDefinition(
      name: 'astoria_studio_block_manage',
      description:
          'Create or edit a direct instruction block with an exact supplied body (empty clears) and a short title for the next Studio turn. Locked/static/history/context/prefill are protected.',
      risk: SupportAppActionRisk.configuration,
      fields: {
        'operation': SupportAppActionField.choice(
          SupportStudioBlockOperation.values.map((o) => o.name),
        ),
        'id': SupportContentArguments.id,
        'blockId': SupportContentArguments.id,
        'title': SupportContentTextArguments.name,
        'text': SupportContentTextArguments.body,
        'clearText': const SupportAppActionField.boolean(),
        'enabled': const SupportAppActionField.boolean(),
        'role': SupportAppActionField.choice(['system', 'user', 'assistant']),
        'section': SupportAppActionField.choice([
          'pregen',
          'final',
          'cleaner',
          'ledger',
        ]),
        'order': const SupportAppActionField.integer(0, 10000),
        'depth': const SupportAppActionField.integer(0, 200),
      },
      requiredFields: {'operation', 'id'},
    ),
    SupportAppActionDefinition(
      name: 'astoria_studio_agent_set',
      description:
          'Set a native Studio controller state with canonical dependency/radio-block semantics for the next turn. Main Writer is locked on.',
      risk: SupportAppActionRisk.configuration,
      fields: {
        'id': SupportContentArguments.id,
        'controller': SupportAppActionField.choice(
          StudioControllerOntology.specs.map((s) => s.id),
        ),
        'enabled': const SupportAppActionField.boolean(),
      },
      requiredFields: {'id', 'controller', 'enabled'},
    ),
  ];

  @override
  Future<SupportAppPreparedAction?> prepare(
    String action,
    Map<String, Object?> a,
    SupportAppActionContext context,
  ) async {
    final definition = definitions.where((d) => d.name == action).firstOrNull;
    if (definition == null) return null;
    SupportContentArguments.validate(definition, a);
    if (!context.current) return null;
    if (action == 'astoria_studio_agent_set') return _agent(a, context);
    if (action == 'astoria_studio_block_manage') return _block(a, context);
    final op = SupportStudioPresetOperation.values.byName(
      a['operation']! as String,
    );
    SupportContentArguments.shape(
      a,
      op == SupportStudioPresetOperation.historyLimit
          ? {'operation', 'id', 'limit'}
          : {'operation', 'id', 'name'},
      op == SupportStudioPresetOperation.historyLimit ? {'limit'} : {'name'},
    );
    final before = await repo.getById(a['id']! as String);
    if (!context.current || before == null) return null;
    final id = op == SupportStudioPresetOperation.clone ? newId() : before.id;
    return mutations.prepare(
      domain: SupportContentDomain.studioPreset,
      target: id,
      observation: before,
      context: context,
      // Cloning reads an existing source natively; it still needs its fence.
      preview: {
        'operation': op.name,
        'sourceId': before.id,
        'nextTurnOnly': true,
      },
      persist: (current) => op == SupportStudioPresetOperation.clone
          ? repo.controlClone(
              expected: before,
              id: id,
              name: a['name']! as String,
              timestamp: clock(),
              current: current,
            )
          : repo.controlPatch(
              expected: before,
              name: a['name'] as String?,
              maxFinalHistoryMessages: a['limit'] as int?,
              timestamp: clock(),
              current: current,
            ),
      refresh: refresh,
    );
  }

  Future<SupportAppPreparedAction?> _block(
    Map<String, Object?> a,
    SupportAppActionContext context,
  ) async {
    final op = SupportStudioBlockOperation.values.byName(
      a['operation']! as String,
    );
    String? text;
    if (op == SupportStudioBlockOperation.create) {
      SupportContentArguments.shape(
        a,
        {'operation', 'id', 'title', 'text', 'clearText', 'section', 'role'},
        {'title', 'section'},
      );
      if (a.containsKey('text') || a.containsKey('clearText')) {
        text = SupportContentTextArguments.selected(a);
      }
    } else if (op == SupportStudioBlockOperation.editText) {
      SupportContentArguments.shape(
        a,
        {'operation', 'id', 'blockId', 'text', 'clearText'},
        {'blockId'},
      );
      text = SupportContentTextArguments.selected(a);
    } else {
      SupportContentArguments.shape(
        a,
        {'operation', 'id', 'blockId', 'enabled', 'role', 'order', 'depth'},
        {'blockId'},
      );
      if (a.length < 4) {
        throw const SupportAppActionRefused(
          SupportAppActionCode.invalidArguments,
        );
      }
    }
    final before = await repo.getById(a['id']! as String);
    if (!context.current || before == null) return null;
    StudioPresetBlock block;
    if (op == SupportStudioBlockOperation.create) {
      final section = a['section']! as String;
      block = StudioPresetBlock(
        id: newId(),
        title: a['title']! as String,
        content: text ?? '',
        section: section,
        injectionPoint: section,
        role: a['role'] as String? ?? 'system',
      );
    } else {
      final selected = before.blocks
          .where((b) => b.id == a['blockId'])
          .firstOrNull;
      if (selected == null) return null;
      if (selected.locked ||
          selected.isStatic ||
          selected.type != StudioBlockType.instruction ||
          selected.mode != 'direct') {
        throw const SupportAppActionRefused(SupportAppActionCode.denied);
      }
      block = selected.copyWith(
        content: text ?? selected.content,
        enabled: a['enabled'] as bool? ?? selected.enabled,
        role: a['role'] as String? ?? selected.role,
        order: a['order'] as int? ?? selected.order,
        depth: a['depth'] as int? ?? selected.depth,
        insertionMode: a.containsKey('depth')
            ? 'depth'
            : selected.insertionMode,
      );
    }
    return mutations.prepare(
      domain: SupportContentDomain.studioPreset,
      target: before.id,
      observation: before,
      context: context,
      preview: {
        'operation': op.name,
        'blockId': block.id,
        'nextTurnOnly': true,
        if (text != null) 'field': 'content',
        if (text != null) 'textLength': text.length,
      },
      persist: (current) => repo.controlPatch(
        expected: before,
        block: block,
        blockFields: {
          if (op == SupportStudioBlockOperation.editText)
            StudioControlBlockField.content,
          if (a.containsKey('enabled')) StudioControlBlockField.enabled,
          if (a.containsKey('role')) StudioControlBlockField.role,
          if (a.containsKey('order')) StudioControlBlockField.order,
          if (a.containsKey('depth')) StudioControlBlockField.depth,
        },
        addBlock: op == SupportStudioBlockOperation.create,
        timestamp: clock(),
        current: current,
      ),
      refresh: refresh,
    );
  }

  Future<SupportAppPreparedAction?> _agent(
    Map<String, Object?> a,
    SupportAppActionContext context,
  ) async {
    final spec = StudioControllerOntology.specs.firstWhere(
      (s) => s.id == a['controller'],
    );
    if (spec.lockedOn) {
      throw const SupportAppActionRefused(SupportAppActionCode.denied);
    }
    final before = await repo.controlObserve(a['id']! as String);
    if (!context.current || before == null) return null;
    final next = applyStudioAgentToggle(before, spec.id, a['enabled']! as bool);
    final changedAgents = StudioControllerOntology.specs
        .where(
          (s) =>
              (before.agentEnabled[s.id] ?? true) !=
              (next.agentEnabled[s.id] ?? true),
        )
        .length;
    final changedBlocks = before.blocks
        .where(
          (b) => next.blocks.any((n) => n.id == b.id && n.enabled != b.enabled),
        )
        .length;
    return mutations.prepare(
      domain: SupportContentDomain.studioPreset,
      target: before.id,
      observation: before,
      context: context,
      preview: {
        'controller': spec.id,
        'affectedControllers': changedAgents,
        'affectedBlocks': changedBlocks,
        'nextTurnOnly': true,
      },
      persist: (current) => repo.controlAgentToggle(
        expected: before,
        toggled: next,
        timestamp: clock(),
        current: current,
      ),
      refresh: refresh,
    );
  }
}
