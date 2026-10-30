import '../../../../../core/db/repositories/preset_repo.dart';
import '../../../../../core/models/preset.dart';
import '../../../models/support_app_action.dart';
import 'support_content_mutation.dart';
import 'support_content_text_arguments.dart';

enum SupportPresetOperation { create, editText }

enum SupportPresetBlockOperation { create, editText, settings }

/// Ordinary roleplay presets exclusively. No Studio repository/id fallback.
final class SupportPresetControlAdapter implements SupportAppActionAdapter {
  const SupportPresetControlAdapter({
    required this.repo,
    required this.mutations,
    required this.newId,
    required this.clock,
    required this.refresh,
  });
  final PresetRepo repo;
  final SupportContentMutation mutations;
  final String Function() newId;
  final int Function() clock;
  final void Function() refresh;

  @override
  List<SupportAppActionDefinition> get definitions => [
    SupportAppActionDefinition(
      name: 'astoria_preset_manage',
      description:
          'Create an ordinary roleplay preset or replace a short name or exact supplied prompt body. Empty body clears; names stay single-line. Does not access Studio presets.',
      risk: SupportAppActionRisk.configuration,
      fields: {
        'operation': SupportAppActionField.choice(
          SupportPresetOperation.values.map((o) => o.name),
        ),
        'id': SupportContentArguments.id,
        'name': SupportContentTextArguments.name,
        'field': SupportAppActionField.choice(
          PresetControlText.values.map((f) => f.name),
        ),
        'text': SupportContentTextArguments.body,
        'clearText': const SupportAppActionField.boolean(),
      },
      requiredFields: {'operation'},
    ),
    SupportAppActionDefinition(
      name: 'astoria_preset_block_manage',
      description:
          'Create or edit a non-static ordinary block with an exact supplied body (empty clears), short name or enabled/role/depth scalars. System/history blocks are protected.',
      risk: SupportAppActionRisk.configuration,
      fields: {
        'operation': SupportAppActionField.choice(
          SupportPresetBlockOperation.values.map((o) => o.name),
        ),
        'id': SupportContentArguments.id,
        'blockId': SupportContentArguments.id,
        'name': SupportContentTextArguments.name,
        'text': SupportContentTextArguments.body,
        'clearText': const SupportAppActionField.boolean(),
        'enabled': const SupportAppActionField.boolean(),
        'role': SupportAppActionField.choice(['system', 'user', 'assistant']),
        'depth': const SupportAppActionField.integer(0, 200),
      },
      requiredFields: {'operation', 'id'},
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
    if (action == 'astoria_preset_block_manage') return _block(a, context);
    final op = SupportPresetOperation.values.byName(a['operation']! as String);
    if (op == SupportPresetOperation.create) {
      SupportContentArguments.shape(a, {'operation', 'name'}, {'name'});
      final value = Preset(
        id: newId(),
        name: a['name']! as String,
        createdAt: clock(),
      );
      return mutations.prepare(
        domain: SupportContentDomain.preset,
        target: value.id,
        observation: value,
        context: context,
        createsNew: true,
        persist: (current) => repo.controlCreate(value, current),
        refresh: refresh,
      );
    }
    SupportContentArguments.shape(
      a,
      {'operation', 'id', 'field', 'text', 'clearText'},
      {'id', 'field'},
    );
    final field = PresetControlText.values.byName(a['field']! as String);
    final text = SupportContentTextArguments.selected(
      a,
      isBody: field != PresetControlText.name,
      allowClear: field != PresetControlText.name,
    );
    final before = await repo.getById(a['id']! as String);
    if (!context.current || before == null) return null;
    return mutations.prepare(
      domain: SupportContentDomain.preset,
      target: before.id,
      observation: before,
      context: context,
      preview: {
        'field': field.name,
        'operation': op.name,
        'textLength': text.length,
      },
      persist: (current) => repo.controlPatch(
        expected: before,
        field: field,
        value: text,
        current: current,
      ),
      refresh: refresh,
    );
  }

  Future<SupportAppPreparedAction?> _block(
    Map<String, Object?> a,
    SupportAppActionContext context,
  ) async {
    final op = SupportPresetBlockOperation.values.byName(
      a['operation']! as String,
    );
    String? text;
    if (op == SupportPresetBlockOperation.create) {
      SupportContentArguments.shape(
        a,
        {'operation', 'id', 'name', 'text', 'clearText', 'role'},
        {'name'},
      );
      if (a.containsKey('text') || a.containsKey('clearText')) {
        text = SupportContentTextArguments.selected(a);
      }
    } else if (op == SupportPresetBlockOperation.editText) {
      SupportContentArguments.shape(
        a,
        {'operation', 'id', 'blockId', 'text', 'clearText'},
        {'blockId'},
      );
      text = SupportContentTextArguments.selected(a);
    } else {
      SupportContentArguments.shape(
        a,
        {'operation', 'id', 'blockId', 'enabled', 'role', 'depth'},
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
    final id = op == SupportPresetBlockOperation.create
        ? newId()
        : a['blockId']! as String;
    if (op != SupportPresetBlockOperation.create) {
      final block = before.blocks.where((b) => b.id == id).firstOrNull;
      if (block == null) return null;
      if (block.isStatic) {
        throw const SupportAppActionRefused(SupportAppActionCode.denied);
      }
    }
    return mutations.prepare(
      domain: SupportContentDomain.preset,
      target: before.id,
      observation: before,
      context: context,
      preview: {
        'blockId': id,
        'operation': op.name,
        if (text != null) 'field': 'content',
        if (text != null) 'textLength': text.length,
      },
      persist: (current) => repo.controlPatch(
        expected: before,
        blockId: id,
        addBlock: op == SupportPresetBlockOperation.create,
        blockName: a['name'] as String?,
        value: text,
        enabled: a['enabled'] as bool?,
        role: a['role'] as String?,
        depth: a['depth'] as int?,
        current: current,
      ),
      refresh: refresh,
    );
  }
}
