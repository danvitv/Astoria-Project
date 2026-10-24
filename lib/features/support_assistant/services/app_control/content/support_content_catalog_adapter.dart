import '../../../../../core/db/repositories/character_repo.dart';
import '../../../../../core/db/repositories/persona_repo.dart';
import '../../../../../core/db/repositories/lorebook_repo.dart';
import '../../../../../core/db/repositories/preset_repo.dart';
import '../../../../../core/db/repositories/studio_preset_repo.dart';
import '../../../models/support_app_action.dart';
import 'support_content_mutation.dart';

/// Pure ID/count projection. In particular ordinary PresetRepo.getAll repairs
/// rows, so it is deliberately never used for this metadata operation.
final class SupportContentCatalogAdapter implements SupportAppActionAdapter {
  const SupportContentCatalogAdapter({
    required this.characters,
    required this.personas,
    required this.lorebooks,
    required this.presets,
    required this.studioPresets,
  });
  final CharacterRepo characters;
  final PersonaRepo personas;
  final LorebookRepo lorebooks;
  final PresetRepo presets;
  final StudioPresetRepo studioPresets;

  @override
  List<SupportAppActionDefinition> get definitions => [
    SupportAppActionDefinition(
      name: 'astoria_content_catalog',
      description:
          'List up to 32 content IDs and the total count; no names, titles, prompts or previews.',
      risk: SupportAppActionRisk.metadata,
      fields: {
        'domain': SupportAppActionField.choice(
          SupportContentDomain.values.map((d) => d.name),
        ),
        'offset': const SupportAppActionField.integer(0, 1000000),
      },
      requiredFields: {'domain'},
    ),
    SupportAppActionDefinition(
      name: 'astoria_content_handles',
      description:
          'List up to 32 entry/block IDs and their count from a selected lorebook, ordinary preset, or Studio preset. No titles, keys or bodies.',
      risk: SupportAppActionRisk.metadata,
      fields: {
        'domain': SupportAppActionField.choice([
          'lorebook',
          'preset',
          'studioPreset',
        ]),
        'id': SupportContentArguments.id,
        'offset': const SupportAppActionField.integer(0, 1000000),
      },
      requiredFields: {'domain', 'id'},
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
    final domain = SupportContentDomain.values.byName(
      arguments['domain']! as String,
    );
    final offset = arguments['offset'] as int? ?? 0;
    final id = arguments['id'] as String?;
    final result = id != null
        ? await switch (domain) {
            SupportContentDomain.lorebook => lorebooks.controlEntryIds(
              id,
              offset,
            ),
            SupportContentDomain.preset => presets.controlBlockIds(id, offset),
            SupportContentDomain.studioPreset => studioPresets.controlBlockIds(
              id,
              offset,
            ),
            _ => Future<({List<String> ids, int count})?>.value(),
          }
        : await switch (domain) {
            SupportContentDomain.character => characters.controlIds(offset),
            SupportContentDomain.persona => personas.controlIds(offset),
            SupportContentDomain.lorebook => lorebooks.controlIds(offset),
            SupportContentDomain.preset => presets.controlIds(offset),
            SupportContentDomain.studioPreset => studioPresets.controlIds(
              offset,
            ),
          };
    if (!context.current || result == null) return null;
    return SupportAppPreparedAction(
      target: 'content-catalog:${domain.name}',
      observation: Object(),
      observationIsCurrent: () => context.current,
      execute: (current) async => SupportAppActionOutcome(
        current() ? SupportAppActionCode.completed : SupportAppActionCode.stale,
        data: current()
            ? {
                'domain': domain.name,
                'ids': result.ids,
                'count': result.count,
                'offset': offset,
              }
            : const {},
      ),
    );
  }
}
