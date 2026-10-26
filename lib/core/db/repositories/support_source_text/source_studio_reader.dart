part of '../support_source_text_repo.dart';

extension _SourceStudioReader on SupportSourceTextRepo {
  static const _definitionColumns = [
    'blocks_json',
    'agents_json',
    'agent_enabled_json',
    'runtime_settings_json',
  ];
  static const _definitionSize = '''length(CAST(blocks_json AS BLOB)) +
    length(CAST(agents_json AS BLOB)) + length(CAST(agent_enabled_json AS BLOB)) +
    length(CAST(runtime_settings_json AS BLOB)) + length(CAST(expensive_api_config_id AS BLOB)) +
    length(CAST(cheap_api_config_id AS BLOB)) + length(CAST(cleaner_api_config_id AS BLOB)) +
    length(CAST(ledger_api_config_id AS BLOB)) + length(CAST(execution_mode AS BLOB)) +
    length(CAST(max_final_history_messages AS TEXT))''';
  Future<(int, int)> _studioExtent(String id, void Function() guard) async {
    guard();
    final row = await _db
        .customSelect(
          '''SELECT $_definitionSize AS bytes,
      length(blocks_json) + length(agents_json) + length(agent_enabled_json) + length(runtime_settings_json) +
      length(expensive_api_config_id) + length(cheap_api_config_id) + length(cleaner_api_config_id) +
      length(ledger_api_config_id) + length(execution_mode) + length(CAST(max_final_history_messages AS TEXT)) AS chars,
      CASE WHEN typeof(blocks_json) = 'text' AND typeof(agents_json) = 'text' AND
        typeof(agent_enabled_json) = 'text' AND typeof(runtime_settings_json) = 'text' AND
        typeof(max_final_history_messages) = 'integer' AND max_final_history_messages BETWEEN 0 AND 2000 AND
        execution_mode IN ('legacy','agentic') THEN 1 ELSE 0 END AS valid
      FROM studio_preset_rows WHERE preset_id = ? LIMIT 1''',
          variables: [Variable.withString(id)],
        )
        .getSingleOrNull();
    guard();
    if (row == null) _deny(SupportSourceReadFailure.notFound);
    if (row.read<int>('valid') != 1)
      _deny(SupportSourceReadFailure.unsupportedFormat);
    if (row.read<int>('bytes') > 65536)
      _deny(SupportSourceReadFailure.tooLarge);
    return (row.read<int>('chars'), row.read<int>('bytes'));
  }

  Future<SupportSourceSnapshot> _studio(
    SupportSourceObservation observation,
    void Function() guard,
  ) async {
    final extent = await _studioExtent(observation.sourceId, guard);
    guard();
    if (extent != (observation.textCharacters, observation.textBytes))
      _deny(SupportSourceReadFailure.changed);
    final row = await _db
        .customSelect(
          '''SELECT blocks_json, agents_json, agent_enabled_json,
      runtime_settings_json, max_final_history_messages, execution_mode,
      expensive_api_config_id, cheap_api_config_id, cleaner_api_config_id, ledger_api_config_id
      FROM studio_preset_rows WHERE preset_id = ? AND $_definitionSize <= 65536 LIMIT 1''',
          variables: [Variable.withString(observation.sourceId)],
        )
        .getSingleOrNull();
    guard();
    if (row == null) _deny(SupportSourceReadFailure.changed);
    final raw = row.data;
    final decoded = <String, Object?>{};
    for (final key in _definitionColumns) {
      if (raw[key] is! String)
        _deny(SupportSourceReadFailure.unsupportedFormat);
      decoded[key] = SupportSourceJson.decode(raw[key] as String);
    }
    _StudioSourceShape(this)._validate(decoded);
    for (final key in [
      'expensive_api_config_id',
      'cheap_api_config_id',
      'cleaner_api_config_id',
      'ledger_api_config_id',
    ]) {
      if (raw[key] is! String ||
          ((raw[key] as String).isNotEmpty && !_identity(raw[key])))
        _deny(SupportSourceReadFailure.unsupportedFormat);
    }
    final definition = <String, Object?>{
      'blocks': decoded['blocks_json'],
      'agents': decoded['agents_json'],
      'agentEnabled': decoded['agent_enabled_json'],
      'runtime': decoded['runtime_settings_json'],
      'maxFinalHistoryMessages': raw['max_final_history_messages'],
      'executionMode': raw['execution_mode'],
      'expensiveApiConfigId': raw['expensive_api_config_id'],
      'cheapApiConfigId': raw['cheap_api_config_id'],
      'cleanerApiConfigId': raw['cleaner_api_config_id'],
      'ledgerApiConfigId': raw['ledger_api_config_id'],
    };
    // Sanitize every actual authored string, not serialized JSON syntax. No
    // defaults, macro expansion, runtime assembly, model lookup or code runner.
    Object? safe(Object? value) {
      if (value is String) {
        final result = _currentRedactor()
            .withKnownSecrets(
              const [],
              maxInputLength: 65536,
              maxOutputLength: 65536,
            )
            .redactText(value);
        if (result.contains(SecretRedactor.limited))
          _deny(SupportSourceReadFailure.tooLarge);
        return result;
      }
      if (value is List) return [for (final item in value) safe(item)];
      if (value is Map<String, Object?>)
        return {
          for (final entry in value.entries) entry.key: safe(entry.value),
        };
      return value;
    }

    return _snapshot(
      observation,
      [observation._header, raw],
      {
        'domain': 'studioPreset',
        'sourceId': observation.sourceId,
        'state': 'CURRENT SAVED',
        'scope':
            'Saved definition/instruction configuration only. Not a historical assembled prompt; '
            'no assertion that this preset generated any previous game response.',
        'definition': safe(definition),
      },
    );
  }
}

/// Deliberately strict saved-definition shape, not the migration/default codec.
/// Supports the exact canonical serializer and the finite raw built-in seed
/// dialect. Unsupported fields refuse the whole snapshot, never disappear.
final class _StudioSourceShape {
  _StudioSourceShape(this.repo);
  final SupportSourceTextRepo repo;
  Never bad() => repo._deny(SupportSourceReadFailure.unsupportedFormat);
  Map<String, Object?> map(Object? value) {
    if (value is! Map<String, Object?>) bad();
    return value;
  }

  List<Object?> list(Object? value) {
    if (value is! List<Object?> || value.length > 128) bad();
    return value;
  }

  void fields(
    Map<String, Object?> value, {
    Set<String> strings = const {},
    Set<String> booleans = const {},
    Set<String> integers = const {},
    Set<String> numbers = const {},
    Set<String> nullable = const {},
  }) {
    for (final entry in value.entries) {
      final key = entry.key, item = entry.value;
      if (nullable.contains(key) && item == null) continue;
      if ((strings.contains(key) && item is String) ||
          (booleans.contains(key) && item is bool) ||
          (integers.contains(key) &&
              item is int &&
              item.abs() <= 8640000000000000) ||
          (numbers.contains(key) && item is num && item.isFinite))
        continue;
      bad();
    }
  }

  void choice(Map<String, Object?> value, String key, Set<String> choices) {
    if (value.containsKey(key) &&
        value[key] != null &&
        !choices.contains(value[key]))
      bad();
  }

  void stringList(Object? value) {
    final ids = list(value), seen = <String>{};
    for (final id in ids) {
      if (!repo._identity(id) || !seen.add(id as String)) bad();
    }
  }

  void _validate(Map<String, Object?> decoded) {
    final ids = <String>{};
    for (final item in list(decoded['blocks_json'])) {
      final block = map(item);
      fields(
        block,
        strings: const {
          'id',
          'title',
          'name',
          'type',
          'kind',
          'contextSlot',
          'targetAgentId',
          'role',
          'content',
          'section',
          'mode',
          'prefillStyle',
          'injectionPoint',
          'sourceAgentId',
          'groupBoundary',
          'insertionMode',
        },
        booleans: const {
          'enabled',
          'locked',
          'isStatic',
          'appendToLastMessage',
        },
        integers: const {'order', 'depth'},
        nullable: const {'contextSlot', 'targetAgentId', 'depth'},
      );
      if (!repo._identity(block['id']) ||
          !ids.add(block['id'] as String) ||
          (block['type'] is! String && block['kind'] is! String) ||
          block['content'] is! String)
        bad();
      if (block['locked'] == true) repo._deny(SupportSourceReadFailure.locked);
      choice(block, 'type', const {
        'instruction',
        'context',
        'history',
        'priorBriefs',
      });
      // onCreate persists the raw seed rather than block.toJson(). Keep its
      // name/kind and authored text exactly; no conversion, guessed defaults,
      // macro expansion or silent acceptance of an unknown legacy kind.
      choice(block, 'kind', const {
        'instruction',
        'agent_instruction',
        'tracker_instruction',
        'custom_text',
        'previous_agents',
        'user_persona',
        'char_card',
        'scenario',
        'char_personality',
        'example_dialogue',
        'authors_note',
        'memory',
        'chat_history',
        'dynamic_context',
      });
      choice(block, 'role', const {'system', 'user', 'assistant', 'tool'});
      choice(block, 'mode', const {
        '',
        'direct',
        'pregenBrief',
        'functionPrefill',
        'agentResponse',
      });
      choice(block, 'section', const {
        '',
        'pregen',
        'final',
        'cleaner',
        'ledger',
        'build',
        'brief_parser',
      });
      choice(block, 'injectionPoint', const {
        'pregen',
        'specificAgent',
        'final',
        'cleaner',
        'ledger',
        'build',
        'brief_parser',
      });
      choice(block, 'prefillStyle', const {'tool', 'structured', 'two-pass'});
      choice(block, 'insertionMode', const {'relative', 'depth'});
      choice(block, 'groupBoundary', const {'none', 'open', 'close'});
      choice(block, 'contextSlot', const {
        'characterCard',
        'characterPersonality',
        'userPersona',
        'scenario',
        'exampleDialogue',
        'authorsNote',
        'summary',
        'memory',
        'loreBefore',
        'loreAfter',
        'loreMacro',
        'recalledMessages',
        'characterKnowledge',
        'studioSessionState',
        'runtimeDynamic',
        'staticContext',
        'dynamicContext',
      });
      if (block['type'] == 'context' && block['contextSlot'] == null) bad();
    }
    ids.clear();
    for (final item in list(decoded['agents_json'])) {
      final agent = map(item);
      fields(
        agent,
        strings: const {
          'id',
          'controllerId',
          'name',
          'role',
          'specId',
          'refreshPolicy',
          'phase',
          'reasoningMode',
        },
        booleans: const {'enabled'},
        integers: const {'order', 'maxParallelJobs'},
      );
      if (!repo._identity(agent['id']) || !ids.add(agent['id'] as String))
        bad();
      choice(agent, 'refreshPolicy', const {'static', 'scene', 'turn'});
      choice(agent, 'phase', const {'pre_generation', 'post_processing'});
      choice(agent, 'reasoningMode', const {'normal', 'think-replacement'});
    }
    booleanMap(decoded['agent_enabled_json']);
    _runtime(map(decoded['runtime_settings_json']));
  }

  void booleanMap(Object? value) {
    for (final item in map(value).entries) {
      if (!repo._identity(item.key) || item.value is! bool) bad();
    }
  }

  void _runtime(Map<String, Object?> runtime) {
    final scalar = Map<String, Object?>.of(runtime);
    for (final key in [
      'cleaner',
      'ledger',
      'cardRewriter',
      'broadcastBlocks',
      'agentBlockRestoreState',
      'agentEnabledBeforeDependencyOff',
      'controllerAlternativeBlockIds',
    ]) {
      scalar.remove(key);
    }
    fields(
      scalar,
      strings: const {
        'ledgerEngine',
        'requestedLedgerPromptInjectionMode',
        'requestedLedgerPromptInjectionAlgorithmVersion',
        'reasoningTagStart',
        'reasoningTagEnd',
      },
      integers: const {'version'},
      nullable: const {
        'requestedLedgerPromptInjectionMode',
        'requestedLedgerPromptInjectionAlgorithmVersion',
        'reasoningTagStart',
        'reasoningTagEnd',
      },
    );
    if (runtime.containsKey('version') && runtime['version'] != 1) bad();
    choice(runtime, 'ledgerEngine', const {
      'currentReconciled',
      'legacyTurnOnly',
    });
    choice(runtime, 'requestedLedgerPromptInjectionMode', const {
      'legacy',
      'shadow',
      'gapFiller',
      'disabled',
    });
    if (runtime.containsKey('broadcastBlocks'))
      stringList(runtime['broadcastBlocks']);
    // Native controlAgentToggle persists this separate boolean restoration
    // map. Unlike the list-valued block restoration state, do not reinterpret
    // its values or let tolerant controlObserve discard malformed entries.
    if (runtime.containsKey('agentEnabledBeforeDependencyOff'))
      booleanMap(runtime['agentEnabledBeforeDependencyOff']);
    for (final key in [
      'agentBlockRestoreState',
      'controllerAlternativeBlockIds',
    ]) {
      if (!runtime.containsKey(key)) continue;
      for (final item in map(runtime[key]).entries) {
        if (!repo._identity(item.key)) bad();
        stringList(item.value);
      }
    }
    if (runtime['ledger'] != null) {
      final ledger = map(runtime['ledger']);
      fields(
        ledger,
        strings: const {'studioLedgerModel', 'studioLedgerRunMode'},
        integers: const {
          'studioLedgerTimeoutMs',
          'studioLedgerMaxTokens',
          'studioLedgerIntervalN',
        },
        numbers: const {'studioLedgerTemperature'},
        booleans: const {'studioLedgerRunWhenMentionedEntitiesChanged'},
      );
      choice(ledger, 'studioLedgerRunMode', const {
        'every_turn',
        'conditional',
        'every_n',
        'manual',
        'disabled',
      });
    }
    if (runtime['cardRewriter'] != null)
      fields(
        map(runtime['cardRewriter']),
        strings: const {'apiConfigId', 'modelOverride'},
        booleans: const {'enabled', 'lorebookEvolutionEnabled'},
        integers: const {
          'timeoutMs',
          'observationPromotionThreshold',
          'observationExpiryRuns',
        },
        numbers: const {'observationMinConfidence'},
      );
    if (runtime['cleaner'] != null) {
      final cleaner = Map<String, Object?>.of(map(runtime['cleaner']));
      final hasExtra = cleaner.containsKey('postCleanerExtraRequestParameters');
      final extra = cleaner.remove('postCleanerExtraRequestParameters');
      // Arbitrary extra wire parameters are outside the definition reader's
      // supported shape. Do not execute, discard, or silently normalize them.
      if (hasExtra && list(extra).isNotEmpty) bad();
      fields(
        cleaner,
        strings: const {
          'postCleanerModel',
          'postCleanerAuditModel',
          'postCleanerBannedWords',
          'postCleanerAvoidInstructions',
          'postCleanerStyleInstructions',
          'postCleanerReasoningEffort',
        },
        numbers: const {
          'postCleanerTemperature',
          'postCleanerTopP',
          'postCleanerFrequencyPenalty',
          'postCleanerPresencePenalty',
        },
        integers: const {
          'postCleanerMaxTokens',
          'postCleanerTopK',
          'postCleanerTimeoutMs',
          'postCleanerHistoryMessages',
          'postCleanerMaxCharsPerMessage',
        },
        booleans: const {
          'postCleanerTopPOverride',
          'postCleanerTopKOverride',
          'postCleanerFrequencyPenaltyOverride',
          'postCleanerPresencePenaltyOverride',
          'postCleanerDisableReasoning',
          'postCleanerRequestReasoning',
          'postCleanerShowNativeReasoning',
          'postCleanerUseResponsesApi',
          'postCleanerOmitTemperature',
          'postCleanerOmitTopP',
          'postCleanerOmitReasoning',
          'postCleanerOmitReasoningEffort',
          'postCleanerRequestReasoningOverride',
          'postCleanerShowNativeReasoningOverride',
          'postCleanerUseResponsesApiOverride',
          'postCleanerReasoningEffortOverride',
          'postCleanerEnabled',
        },
      );
    }
  }
}
