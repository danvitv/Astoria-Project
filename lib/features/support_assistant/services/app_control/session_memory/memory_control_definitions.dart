import '../../../models/support_app_action.dart';

final class MemoryControlDefinitions {
  static const id = SupportAppActionField.text(128);
  static const boolean = SupportAppActionField.boolean();
  static final settings = <String, SupportAppActionField>{
    'enabled': boolean,
    'maxInjectedEntries': const SupportAppActionField.integer(0, 32),
    'maxInjectedTokens': const SupportAppActionField.integer(128, 32768),
    'memoryExcerptingEnabled': boolean,
    'memoryPackingMode': SupportAppActionField.choice([
      'full',
      'hybrid',
      'chunk_first',
    ]),
    'injectionTarget': SupportAppActionField.choice(['hard_block', 'macro']),
    'sourceWindowExclusion': boolean,
    'factualContinuityGuardEnabled': boolean,
  };

  static List<SupportAppActionDefinition> get all => [
    SupportAppActionDefinition(
      name: 'astoria_memory_inspect',
      description:
          'Read a session Memory Book: fixed scalar settings or paged '
          'entry/draft IDs and status. No titles, keys, errors, source hashes or text.',
      risk: SupportAppActionRisk.metadata,
      fields: {
        'sessionId': id,
        'view': SupportAppActionField.choice(['settings', 'entries', 'drafts']),
        'offset': const SupportAppActionField.integer(0, 1000000),
        'limit': const SupportAppActionField.integer(1, 16),
      },
      requiredFields: {'sessionId', 'view'},
    ),
    SupportAppActionDefinition(
      name: 'astoria_memory_create',
      description:
          'Create an EMPTY session-owned Memory Book after exact native '
          'confirmation. Automation, consolidation and vector search start OFF; '
          'existing books are never replaced. No generation or network work.',
      risk: SupportAppActionRisk.configuration,
      fields: {'sessionId': id, 'enabled': boolean},
      requiredFields: {'sessionId', 'enabled'},
    ),
    SupportAppActionDefinition(
      name: 'astoria_memory_settings',
      description:
          'Patch only supplied finite Memory Book retrieval settings '
          'after native confirmation and exact durable row CAS. Preserves all '
          'entries, drafts, bindings and automation/provider settings.',
      risk: SupportAppActionRisk.configuration,
      fields: {'sessionId': id, ...settings},
      requiredFields: {'sessionId'},
    ),
    SupportAppActionDefinition(
      name: 'astoria_memory_draft_vector',
      description:
          'Set one idle draft vector-search flag after native '
          'confirmation and exact row CAS. Does not generate, approve, index, '
          'delete or cancel any draft; content/provenance are preserved.',
      risk: SupportAppActionRisk.configuration,
      fields: {'sessionId': id, 'draftId': id, 'vectorSearch': boolean},
      requiredFields: {'sessionId', 'draftId', 'vectorSearch'},
    ),
    SupportAppActionDefinition(
      name: 'astoria_memory_catalog_rebuild',
      description:
          'Rebuild only the disposable LOCAL catalog for the exact '
          'book after native source lease and confirmation. No embeddings, '
          'Memory Graph purge, paid call, retry or background worker.',
      risk: SupportAppActionRisk.configuration,
      fields: {'sessionId': id},
      requiredFields: {'sessionId'},
    ),
  ];
}
