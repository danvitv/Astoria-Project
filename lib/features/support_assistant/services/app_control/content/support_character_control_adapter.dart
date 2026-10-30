import '../../../../../core/db/repositories/character_repo.dart';
import '../../../../../core/models/character.dart';
import '../../../models/support_app_action.dart';
import 'support_content_mutation.dart';
import 'support_content_text_arguments.dart';

enum SupportCharacterOperation { create, editText, favoriteGroup, hideGroup }

final class SupportCharacterControlAdapter implements SupportAppActionAdapter {
  const SupportCharacterControlAdapter({
    required this.repo,
    required this.mutations,
    required this.newId,
    required this.clock,
    required this.refresh,
  });
  final CharacterRepo repo;
  final SupportContentMutation mutations;
  final String Function() newId;
  final int Function() clock;
  final void Function() refresh;

  @override
  List<SupportAppActionDefinition> get definitions => [
    SupportAppActionDefinition(
      name: 'astoria_character_manage',
      description:
          'Create a standalone card, replace one supplied body or short name field, or set whole-group flags. Body text preserves whitespace; empty clears. No stored body read.',
      risk: SupportAppActionRisk.configuration,
      fields: {
        'operation': SupportAppActionField.choice(
          SupportCharacterOperation.values.map((o) => o.name),
        ),
        'id': SupportContentArguments.id,
        'name': SupportContentTextArguments.name,
        'field': SupportAppActionField.choice(
          CharacterControlText.values.map((f) => f.name),
        ),
        'text': SupportContentTextArguments.body,
        'clearText': const SupportAppActionField.boolean(),
        'value': const SupportAppActionField.boolean(),
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
    final op = SupportCharacterOperation.values.byName(
      arguments['operation']! as String,
    );
    if (op == SupportCharacterOperation.create) {
      SupportContentArguments.shape(arguments, {'operation', 'name'}, {'name'});
      final id = newId();
      final value = Character(
        id: id,
        name: arguments['name']! as String,
        variantGroupId: id,
        createdAt: clock(),
        updatedAt: clock(),
      );
      return mutations.prepare(
        domain: SupportContentDomain.character,
        target: id,
        observation: value,
        context: context,
        createsNew: true,
        persist: (current) => repo.controlCreate(value, current),
        refresh: refresh,
      );
    }
    if (op == SupportCharacterOperation.editText) {
      SupportContentArguments.shape(
        arguments,
        {'operation', 'id', 'field', 'text', 'clearText'},
        {'id', 'field'},
      );
      final field = CharacterControlText.values.byName(
        arguments['field']! as String,
      );
      final text = SupportContentTextArguments.selected(
        arguments,
        isBody:
            field != CharacterControlText.name &&
            field != CharacterControlText.displayName &&
            field != CharacterControlText.world,
        allowClear: field != CharacterControlText.name,
      );
      final before = await repo.getById(arguments['id']! as String);
      if (!context.current || before == null) return null;
      if (before.variantOrder != 0) {
        throw const SupportAppActionRefused(SupportAppActionCode.denied);
      }
      return mutations.prepare(
        domain: SupportContentDomain.character,
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
    SupportContentArguments.shape(
      arguments,
      {'operation', 'id', 'value'},
      {'id', 'value'},
    );
    final selected = await repo.getById(arguments['id']! as String);
    if (!context.current || selected == null) return null;
    final before = await repo.getVariants(selected.variantGroupId);
    if (!context.current || before.isEmpty) return null;
    return mutations.prepare(
      domain: SupportContentDomain.character,
      target: selected.id,
      observation: List<Character>.unmodifiable(before),
      context: context,
      preview: {'operation': op.name, 'affectedRows': before.length},
      persist: (current) => repo.controlGroupFlags(
        expected: before,
        favorite: op == SupportCharacterOperation.favoriteGroup
            ? arguments['value']! as bool
            : null,
        hidden: op == SupportCharacterOperation.hideGroup
            ? arguments['value']! as bool
            : null,
        current: current,
      ),
      refresh: refresh,
    );
  }
}
