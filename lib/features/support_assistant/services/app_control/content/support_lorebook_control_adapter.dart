import '../../../../../core/db/repositories/lorebook_repo.dart';
import '../../../../../core/models/lorebook.dart';
import '../../../models/support_app_action.dart';
import 'support_content_mutation.dart';
import 'support_content_text_arguments.dart';

enum SupportLorebookOperation { create, editText, setEnabled, settings }

enum SupportLorebookEntryOperation { create, editText, settings }

final class SupportLorebookControlAdapter implements SupportAppActionAdapter {
  const SupportLorebookControlAdapter({
    required this.repo,
    required this.mutations,
    required this.newId,
    required this.refresh,
  });
  final LorebookRepo repo;
  final SupportContentMutation mutations;
  final String Function() newId;
  final void Function() refresh;

  @override
  List<SupportAppActionDefinition> get definitions => [
    SupportAppActionDefinition(
      name: 'astoria_lorebook_manage',
      description:
          'Create an unbound global book, replace a short name or exact description body, or edit enabled/scan settings. Empty body clears. Session canon overlays are protected.',
      risk: SupportAppActionRisk.configuration,
      fields: {
        'operation': SupportAppActionField.choice(
          SupportLorebookOperation.values.map((o) => o.name),
        ),
        'id': SupportContentArguments.id,
        'name': SupportContentTextArguments.name,
        'field': SupportAppActionField.choice(
          LorebookControlText.values.map((f) => f.name),
        ),
        'text': SupportContentTextArguments.body,
        'clearText': const SupportAppActionField.boolean(),
        'enabled': const SupportAppActionField.boolean(),
        'scanDepth': const SupportAppActionField.integer(0, 200),
        'maxInjectedEntries': const SupportAppActionField.integer(0, 1000),
      },
      requiredFields: {'operation'},
    ),
    SupportAppActionDefinition(
      name: 'astoria_lorebook_entry_manage',
      description:
          'Create an entry, replace exact supplied content (empty clears) or a short single-line comment/title, or patch entry settings in an editable base lorebook. No body reads.',
      risk: SupportAppActionRisk.configuration,
      fields: {
        'operation': SupportAppActionField.choice(
          SupportLorebookEntryOperation.values.map((o) => o.name),
        ),
        'id': SupportContentArguments.id,
        'entryId': SupportContentArguments.id,
        'field': SupportAppActionField.choice(['content', 'comment']),
        'text': SupportContentTextArguments.body,
        'clearText': const SupportAppActionField.boolean(),
        'enabled': const SupportAppActionField.boolean(),
        'constant': const SupportAppActionField.boolean(),
        'probability': const SupportAppActionField.integer(0, 100),
        'order': const SupportAppActionField.integer(0, 10000),
      },
      requiredFields: {'operation', 'id'},
    ),
  ];

  @override
  Future<SupportAppPreparedAction?> prepare(
    String action,
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  ) async {
    final definition = definitions.where((d) => d.name == action).firstOrNull;
    if (definition == null) return null;
    SupportContentArguments.validate(definition, arguments);
    if (!context.current) return null;
    if (action == 'astoria_lorebook_entry_manage')
      return _entry(arguments, context);
    final op = SupportLorebookOperation.values.byName(
      arguments['operation']! as String,
    );
    if (op == SupportLorebookOperation.create) {
      SupportContentArguments.shape(arguments, {'operation', 'name'}, {'name'});
      final value = Lorebook(id: newId(), name: arguments['name']! as String);
      return mutations.prepare(
        domain: SupportContentDomain.lorebook,
        target: value.id,
        observation: value,
        context: context,
        createsNew: true,
        persist: (current) => repo.controlCreate(value, current),
        refresh: refresh,
      );
    }
    String? text;
    LorebookControlText? field;
    if (op == SupportLorebookOperation.editText) {
      SupportContentArguments.shape(
        arguments,
        {'operation', 'id', 'field', 'text', 'clearText'},
        {'id', 'field'},
      );
      field = LorebookControlText.values.byName(arguments['field']! as String);
      text = SupportContentTextArguments.selected(
        arguments,
        isBody: field == LorebookControlText.description,
        allowClear: field != LorebookControlText.name,
      );
    } else if (op == SupportLorebookOperation.setEnabled) {
      SupportContentArguments.shape(
        arguments,
        {'operation', 'id', 'enabled'},
        {'id', 'enabled'},
      );
    } else {
      SupportContentArguments.shape(
        arguments,
        {'operation', 'id', 'scanDepth', 'maxInjectedEntries'},
        {'id'},
      );
      if (arguments.length < 3)
        throw const SupportAppActionRefused(
          SupportAppActionCode.invalidArguments,
        );
    }
    final before = await repo.getById(arguments['id']! as String);
    if (!context.current || before == null) return null;
    if (before.activationScope == 'chat')
      throw const SupportAppActionRefused(SupportAppActionCode.denied);
    return mutations.prepare(
      domain: SupportContentDomain.lorebook,
      target: before.id,
      observation: before,
      context: context,
      preview: {
        'operation': op.name,
        if (field != null) 'field': field.name,
        if (text != null) 'textLength': text.length,
      },
      persist: (current) => repo.controlPatch(
        expected: before,
        field: field,
        value: text,
        enabled: arguments['enabled'] as bool?,
        scanDepth: arguments['scanDepth'] as int?,
        maxInjectedEntries: arguments['maxInjectedEntries'] as int?,
        current: current,
      ),
      refresh: refresh,
    );
  }

  Future<SupportAppPreparedAction?> _entry(
    Map<String, Object?> a,
    SupportAppActionContext context,
  ) async {
    final op = SupportLorebookEntryOperation.values.byName(
      a['operation']! as String,
    );
    String? text;
    if (op == SupportLorebookEntryOperation.create) {
      SupportContentArguments.shape(
        a,
        {'operation', 'id', 'text', 'clearText', 'enabled', 'constant'},
        {'id'},
      );
      if (a.containsKey('text') || a.containsKey('clearText'))
        text = SupportContentTextArguments.selected(a);
    } else if (op == SupportLorebookEntryOperation.editText) {
      SupportContentArguments.shape(
        a,
        {'operation', 'id', 'entryId', 'field', 'text', 'clearText'},
        {'entryId', 'field'},
      );
      text = SupportContentTextArguments.selected(
        a,
        isBody: a['field'] == 'content',
      );
    } else {
      SupportContentArguments.shape(
        a,
        {
          'operation',
          'id',
          'entryId',
          'enabled',
          'constant',
          'probability',
          'order',
        },
        {'entryId'},
      );
      if (a.length < 4)
        throw const SupportAppActionRefused(
          SupportAppActionCode.invalidArguments,
        );
    }
    final before = await repo.getById(a['id']! as String);
    if (!context.current || before == null) return null;
    if (before.activationScope == 'chat')
      throw const SupportAppActionRefused(SupportAppActionCode.denied);
    final id = op == SupportLorebookEntryOperation.create
        ? newId()
        : a['entryId']! as String;
    if (op != SupportLorebookEntryOperation.create &&
        !before.entries.any((e) => e.id == id))
      return null;
    return mutations.prepare(
      domain: SupportContentDomain.lorebook,
      target: before.id,
      observation: before,
      context: context,
      preview: {
        'entryId': id,
        'operation': op.name,
        if (text != null) 'field': a['field'] ?? 'content',
        if (text != null) 'textLength': text.length,
      },
      persist: (current) => repo.controlPatch(
        expected: before,
        entryId: id,
        addEntry: op == SupportLorebookEntryOperation.create,
        entryContent: a['field'] != 'comment' ? text : null,
        entryComment: a['field'] == 'comment' ? text : null,
        enabled: a['enabled'] as bool?,
        constant: a['constant'] as bool?,
        probability: a['probability'] as int?,
        order: a['order'] as int?,
        current: current,
      ),
      refresh: refresh,
    );
  }
}
