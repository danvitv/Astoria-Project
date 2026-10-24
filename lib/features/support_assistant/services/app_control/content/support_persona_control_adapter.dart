import '../../../../../core/db/repositories/persona_repo.dart';
import '../../../../../core/models/persona.dart';
import '../../../models/support_app_action.dart';
import 'support_content_mutation.dart';
import 'support_content_text_arguments.dart';

enum SupportPersonaOperation { create, editText }

final class SupportPersonaControlAdapter implements SupportAppActionAdapter {
  const SupportPersonaControlAdapter({
    required this.repo,
    required this.mutations,
    required this.newId,
    required this.clock,
    required this.refresh,
  });
  final PersonaRepo repo;
  final SupportContentMutation mutations;
  final String Function() newId;
  final int Function() clock;
  final void Function() refresh;

  @override
  List<SupportAppActionDefinition> get definitions => [
    SupportAppActionDefinition(
      name: 'astoria_persona_manage',
      description:
          'Create a persona or replace a short name/displayName or exact supplied prompt body. Empty body clears; names stay single-line. Existing text remains private.',
      risk: SupportAppActionRisk.configuration,
      fields: {
        'operation': SupportAppActionField.choice(
          SupportPersonaOperation.values.map((o) => o.name),
        ),
        'id': SupportContentArguments.id,
        'name': SupportContentTextArguments.name,
        'field': SupportAppActionField.choice(
          PersonaControlText.values.map((f) => f.name),
        ),
        'text': SupportContentTextArguments.body,
        'clearText': const SupportAppActionField.boolean(),
      },
      requiredFields: {'operation'},
    ),
  ];

  @override
  Future<SupportAppPreparedAction?> prepare(
    String action,
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  ) async {
    if (action != definitions.single.name) return null;
    SupportContentArguments.validate(definitions.single, arguments);
    if (!context.current) return null;
    final op = SupportPersonaOperation.values.byName(
      arguments['operation']! as String,
    );
    if (op == SupportPersonaOperation.create) {
      SupportContentArguments.shape(arguments, {'operation', 'name'}, {'name'});
      final value = Persona(
        id: newId(),
        name: arguments['name']! as String,
        createdAt: clock(),
      );
      return mutations.prepare(
        domain: SupportContentDomain.persona,
        target: value.id,
        observation: value,
        context: context,
        createsNew: true,
        persist: (current) => repo.controlCreate(value, current),
        refresh: refresh,
      );
    }
    SupportContentArguments.shape(
      arguments,
      {'operation', 'id', 'field', 'text', 'clearText'},
      {'id', 'field'},
    );
    final field = PersonaControlText.values.byName(
      arguments['field']! as String,
    );
    final text = SupportContentTextArguments.selected(
      arguments,
      isBody: field == PersonaControlText.prompt,
      allowClear: field != PersonaControlText.name,
    );
    final before = await repo.getById(arguments['id']! as String);
    if (!context.current || before == null) return null;
    return mutations.prepare(
      domain: SupportContentDomain.persona,
      target: before.id,
      observation: before,
      context: context,
      preview: {
        'field': field.name,
        'operation': op.name,
        'textLength': text.length,
      },
      persist: (current) => repo.controlText(
        expected: before,
        field: field,
        value: text,
        current: current,
      ),
      refresh: refresh,
    );
  }
}
