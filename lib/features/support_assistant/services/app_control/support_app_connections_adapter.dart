import '../../../../core/db/repositories/api_config_repo.dart';
import '../../../../core/models/keyless_api_config.dart';
import '../../models/support_app_action.dart';
import '../../models/support_app_action_connections.dart';

/// All effects use native-custodied keyless repository transactions and exact
/// preimages. No ApiConfig hydration, keys, route edits or legacy migration.
final class SupportAppConnectionsAdapter implements SupportAppActionAdapter {
  SupportAppConnectionsAdapter({required this.repo, required this.native});
  final ApiConfigRepo repo;
  final SupportAppConnectionNativePort native;
  static const _id = SupportAppActionField.text(
    128,
    pattern: r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$',
  );
  static const _patchFields = {
    'name': SupportAppActionField.text(128),
    'model': SupportAppActionField.text(
      192,
      pattern: r'^[A-Za-z0-9][A-Za-z0-9._/:\-]{0,191}$',
    ),
    'maxTokens': SupportAppActionField.integer(1, 32768),
    'contextSize': SupportAppActionField.integer(1, 2000000),
    'temperature': SupportAppActionField.number(0, 2),
  };

  @override
  List<SupportAppActionDefinition> get definitions => [
    SupportAppActionDefinition(
      name: 'astoria_connections_list',
      description:
          'List up to 32 keyless saved LLM connection metadata records. No keys or probes.',
      risk: SupportAppActionRisk.metadata,
    ),
    SupportAppActionDefinition(
      name: 'astoria_connection_read',
      description:
          'Read keyless settings and native credential configured/count metadata only.',
      risk: SupportAppActionRisk.metadata,
      fields: {'connectionId': _id},
      requiredFields: {'connectionId'},
    ),
    SupportAppActionDefinition(
      name: 'astoria_connection_create',
      description:
          'Create a keyless native LLM connection using a fixed standard template. Exact native confirmation required; no key/purpose assignment or network call.',
      risk: SupportAppActionRisk.configuration,
      fields: {
        ..._patchFields,
        'template': SupportAppActionField.choice(
          SupportAppConnectionTemplate.values.map((t) => t.name),
        ),
      },
      requiredFields: {'template', 'name', 'model'},
    ),
    SupportAppActionDefinition(
      name: 'astoria_connection_update',
      description:
          'Edit supplied name/model/token/context/temperature fields only, with exact native confirmation and fresh CAS. No endpoint/protocol/purpose/key changes.',
      risk: SupportAppActionRisk.configuration,
      fields: {'connectionId': _id, ..._patchFields},
      requiredFields: {'connectionId'},
    ),
  ];

  @override
  Future<SupportAppPreparedAction?> prepare(
    String action,
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  ) async {
    if (!context.current) return null;
    if (action == 'astoria_connection_create') {
      return _create(arguments, context);
    }
    if (action == 'astoria_connections_list') return _list(context);
    final id = arguments['connectionId']! as String;
    final facts = await native.readCredentialMetadata(id, context);
    if (!context.current || facts == null) return null;
    final observed = await repo.inspectKeyless(id);
    if (!context.current || observed == null) return null;
    final before = observed.view;
    final preview = _project(before, facts);
    if (preview == null) return null;
    bool fresh() =>
        context.current &&
        repo.sameKeylessObservation(observed, observed) &&
        context.current;
    if (action == 'astoria_connection_read') {
      return SupportAppPreparedAction(
        target: id,
        observation: observed,
        observationIsCurrent: fresh,
        execute: (current) async => current() && fresh()
            ? SupportAppActionOutcome(
                SupportAppActionCode.completed,
                data: preview,
              )
            : SupportAppActionOutcome(SupportAppActionCode.conflict),
      );
    }
    if (arguments.length == 1) {
      throw const SupportAppActionRefused(
        SupportAppActionCode.invalidArguments,
      );
    }
    final patch = KeylessApiConfigPatch(
      displayName: arguments['name'] as String? ?? before.displayName,
      model: arguments['model'] as String? ?? before.model,
      maxTokens: arguments['maxTokens'] as int? ?? before.maxTokens,
      contextSize: arguments['contextSize'] as int? ?? before.contextSize,
      temperature:
          (arguments['temperature'] as num?)?.toDouble() ?? before.temperature,
    );
    KeylessApiConfigView after;
    try {
      after = patch.applyTo(before);
    } on FormatException {
      throw const SupportAppActionRefused(
        SupportAppActionCode.invalidArguments,
      );
    }
    final terminal = native is SupportAppConnectionTerminalPort
        ? (native as SupportAppConnectionTerminalPort).terminalEffects(
            repo,
            context,
          )
        : null;
    if (context.terminalRoot != null && terminal == null) return null;
    final plan = terminal?.update(observed, patch);
    return SupportAppPreparedAction(
      target: id,
      observation: plan ?? observed,
      observationIsCurrent: fresh,
      preview: {'before': preview, 'after': _project(after, facts)},
      execute: (current) async {
        if (!current() || !fresh() || !current()) {
          return SupportAppActionOutcome(SupportAppActionCode.conflict);
        }
        if (after == before) {
          return SupportAppActionOutcome(
            SupportAppActionCode.noChange,
            data: preview,
          );
        }
        final receipt = terminal != null
            ? await terminal.execute(plan!)
            : await repo.updateKeyless(
                expected: observed,
                patch: patch,
                isCurrent: current,
              );
        return _settled(receipt, current);
      },
    );
  }

  Future<SupportAppPreparedAction?> _list(
    SupportAppActionContext context,
  ) async {
    final revision = native.observeRevision();
    if (revision == null || !context.current) return null;
    // The extra ID distinguishes a complete page from a truncated one.
    final ids = await repo.getConfigIds(limit: 33);
    if (!context.current || !native.isRevisionCurrent(revision)) return null;
    final records = <Map<String, Object?>>[];
    final observations = <KeylessApiConfigObservation>[];
    var skipped = 0;
    for (final id in ids.take(32)) {
      if (!context.current) return null;
      final facts = await native.readCredentialMetadata(id, context);
      if (!context.current || !native.isRevisionCurrent(revision)) return null;
      if (facts == null) {
        skipped++;
        continue;
      }
      final observation = await repo.inspectKeyless(id);
      if (!context.current || !native.isRevisionCurrent(revision)) return null;
      final projected = observation == null
          ? null
          : _project(observation.view, facts);
      if (projected == null) {
        skipped++;
        continue;
      }
      observations.add(observation!);
      records.add(projected);
    }
    bool fresh() =>
        context.current &&
        native.isRevisionCurrent(revision) &&
        observations.every((o) => repo.sameKeylessObservation(o, o)) &&
        context.current;
    return SupportAppPreparedAction(
      target: 'saved-llm-connections',
      observation: revision,
      observationIsCurrent: fresh,
      execute: (current) async => current() && fresh()
          ? SupportAppActionOutcome(
              SupportAppActionCode.completed,
              data: {
                'connections': records,
                'truncated': ids.length > 32,
                'unavailableRecords': skipped,
              },
            )
          : SupportAppActionOutcome(SupportAppActionCode.conflict),
    );
  }

  SupportAppPreparedAction? _create(
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  ) {
    final revision = native.observeRevision();
    if (revision == null || !context.current) return null;
    final template = SupportAppConnectionTemplate.values.byName(
      arguments['template']! as String,
    );
    final protocol = switch (template) {
      SupportAppConnectionTemplate.openaiChat => 'openai',
      SupportAppConnectionTemplate.openaiResponses => 'openai_responses',
      SupportAppConnectionTemplate.anthropic => 'anthropic',
      SupportAppConnectionTemplate.gemini => 'gemini',
      SupportAppConnectionTemplate.openrouter => 'openrouter',
    };
    final model = arguments['model']! as String;
    final endpoint = native.standardEndpoint(template, model);
    if (endpoint == null ||
        !context.current ||
        !native.isRevisionCurrent(revision)) {
      return null;
    }
    KeylessApiConfigDraft draft;
    try {
      draft = KeylessApiConfigDraft(
        nativeId: NativeKeylessConnectionId.generate(),
        displayName: arguments['name']! as String,
        providerId: template == SupportAppConnectionTemplate.openaiResponses
            ? 'openai'
            : protocol,
        protocol: protocol,
        endpoint: endpoint,
        model: model,
        maxTokens: arguments['maxTokens'] as int? ?? 4096,
        contextSize: arguments['contextSize'] as int? ?? 32768,
        temperature: (arguments['temperature'] as num?)?.toDouble() ?? 0.7,
      );
    } on FormatException {
      throw const SupportAppActionRefused(
        SupportAppActionCode.invalidArguments,
      );
    }
    final terminal = native is SupportAppConnectionTerminalPort
        ? (native as SupportAppConnectionTerminalPort).terminalEffects(
            repo,
            context,
          )
        : null;
    if (context.terminalRoot != null && terminal == null) return null;
    final plan = terminal?.create(draft);
    return SupportAppPreparedAction(
      target: draft.view.connectionId,
      observation: plan ?? draft,
      observationIsCurrent: () =>
          context.current &&
          native.isRevisionCurrent(revision) &&
          context.current,
      preview: {
        'template': template.name,
        'connectionId': draft.view.connectionId,
        'name': draft.view.displayName,
        'model': model,
        'maxTokens': draft.view.maxTokens,
        'contextSize': draft.view.contextSize,
        'temperature': draft.view.temperature,
      },
      execute: (current) async {
        if (!current() || !native.isRevisionCurrent(revision) || !current()) {
          return SupportAppActionOutcome(SupportAppActionCode.conflict);
        }
        final receipt = terminal != null
            ? await terminal.execute(plan!)
            : await repo.createKeyless(draft: draft, isCurrent: current);
        return _settled(receipt, current);
      },
    );
  }

  SupportAppActionOutcome _settled(
    KeylessApiConfigReceipt? receipt,
    bool Function() current,
  ) => SupportAppActionOutcome(
    receipt == null
        ? SupportAppActionCode.conflict
        : current()
        ? SupportAppActionCode.completed
        : SupportAppActionCode.stale,
    effect: receipt == null
        ? SupportAppActionEffect.none
        : SupportAppActionEffect.persisted,
    data: receipt == null
        ? const {}
        : {
            'connectionId': receipt.connectionId,
            'saved': true,
            'verification': 'notTested',
          },
  );

  Map<String, Object?>? _project(
    KeylessApiConfigView view,
    SupportAppCredentialMetadata facts,
  ) => facts.characterCount < 0 || facts.characterCount > 32768
      ? null
      : {
          'connectionId': view.connectionId,
          'name': view.displayName,
          'provider': view.providerId,
          'protocol': view.protocol,
          'model': view.model,
          'maxTokens': view.maxTokens,
          'contextSize': view.contextSize,
          'temperature': view.temperature,
          'credentialConfigured': facts.configured,
          'credentialCharacterCount': facts.characterCount,
          'verification': 'notTested',
        };
}
