part of '../support_source_text_repo.dart';

extension _NavPresets on SupportSourceNavigationRepo {
  List<nav.DataRecord> _ordinaryUnits(
    _NavSource source,
    Map<String, Object?> row,
  ) {
    final preset = _shape.map(_decode(row['data_json']));
    _shape.fields(
      preset,
      strings: const {
        'id',
        'name',
        'author',
        'imagePath',
        'reasoningStart',
        'reasoningEnd',
        'guidedGenerationPrompt',
        'guidedImpersonationPrompt',
        'impersonationPrompt',
        'summaryPrompt',
      },
      bools: const {'reasoningEnabled'},
      ints: const {'createdAt'},
      nullable: const {
        'author',
        'imagePath',
        'reasoningStart',
        'reasoningEnd',
        'guidedGenerationPrompt',
        'guidedImpersonationPrompt',
        'impersonationPrompt',
        'summaryPrompt',
      },
      nested: const {'blocks', 'regexes'},
      required: const {'id', 'name', 'blocks', 'regexes'},
    );
    if (_shape.id(preset['id']) != source.observation.key.nativeId)
      _shape.bad();
    final records = <nav.DataRecord>[];
    final seen = <String>{};
    var index = 0;
    for (final raw in _shape.list(preset['blocks'])) {
      final block = _shape.map(raw);
      _shape.fields(
        block,
        strings: const {
          'id',
          'name',
          'role',
          'content',
          'insertionMode',
          'prefix',
        },
        bools: const {
          'enabled',
          'isStashed',
          'isStatic',
          'appendToLastMessage',
          'sendEmptyBlock',
        },
        ints: const {'depth'},
        nullable: const {'depth', 'prefix'},
        required: const {'id', 'name', 'role', 'content'},
      );
      if (!seen.add(_shape.id(block['id']))) _shape.bad();
      _shape.choice(block, 'role', const {
        'system',
        'user',
        'assistant',
        'tool',
      });
      _shape.choice(block, 'insertionMode', const {'relative', 'depth'});
      records.addAll(
        _fields(
          source,
          'blocks',
          'block:$index',
          nav.SectionKind.presetBlock,
          {...block, 'savedArrayOrder': index},
          private: const {'id'},
        ),
      );
      index++;
    }
    seen.clear();
    index = 0;
    for (final raw in _shape.list(preset['regexes'])) {
      final regex = _shape.map(raw);
      _shape.fields(
        regex,
        strings: const {
          'id',
          'name',
          'regex',
          'replacement',
          'trimOut',
          'macroRules',
        },
        bools: const {
          'disabled',
          'markdownOnly',
          'promptOnly',
          'runOnEdit',
          'memoryBookRetrieval',
        },
        ints: const {'minDepth', 'maxDepth', 'substituteRegex'},
        nested: const {'placement', 'ephemerality'},
        nullable: const {'minDepth', 'maxDepth'},
        required: const {'id', 'name', 'regex'},
      );
      if (!seen.add(_shape.id(regex['id']))) _shape.bad();
      for (final key in ['placement', 'ephemerality']) {
        if (!regex.containsKey(key)) continue;
        if (_shape.list(regex[key]).any((v) => v is! int || v < 0 || v > 16))
          _shape.bad();
      }
      records.addAll(
        _fields(
          source,
          'regex',
          'regex:${index++}',
          nav.SectionKind.regexDefinitions,
          regex,
          private: const {'id'},
        ),
      );
    }
    final reasoning = <String, Object?>{};
    for (final key in ['reasoningEnabled', 'reasoningStart', 'reasoningEnd']) {
      if (preset.containsKey(key)) reasoning[key] = preset[key];
    }
    records.addAll(
      _fields(
        source,
        'reasoning',
        'reasoning',
        nav.SectionKind.reasoning,
        reasoning,
      ),
    );
    final templates = <String, Object?>{};
    for (final key in [
      'name',
      'author',
      'createdAt',
      'guidedGenerationPrompt',
      'guidedImpersonationPrompt',
      'impersonationPrompt',
      'summaryPrompt',
    ]) {
      if (preset.containsKey(key)) templates[key] = preset[key];
    }
    // imagePath is neither followed nor emitted as source text.
    records.addAll(
      _fields(
        source,
        'templates',
        'template',
        nav.SectionKind.templates,
        templates,
      ),
    );
    return records;
  }

  List<nav.DataRecord> _studioUnits(
    _NavSource source,
    Map<String, Object?> row,
  ) {
    final decoded = <String, Object?>{};
    for (final key in _SourceStudioReader._definitionColumns)
      decoded[key] = _decode(row[key]);
    _StudioSourceShape(_boundary)._validate(decoded);
    if (row['max_final_history_messages'] is! int ||
        (row['max_final_history_messages'] as int) < 0 ||
        (row['max_final_history_messages'] as int) > 2000 ||
        !const ['legacy', 'agentic'].contains(row['execution_mode']))
      _shape.bad();
    final records = <nav.DataRecord>[];
    final blocks = _shape.list(decoded['blocks_json']).map(_shape.map).toList();
    final agents = _shape.list(decoded['agents_json']).map(_shape.map).toList();
    final blockIndices = {
      for (var i = 0; i < blocks.length; i++) blocks[i]['id'] as String: i,
    };
    final agentIndices = {
      for (var i = 0; i < agents.length; i++) agents[i]['id'] as String: i,
    };
    final controllerIndices = <String, int>{};
    for (final agent in agents) {
      final id = agent['controllerId'];
      if (id is String)
        controllerIndices.putIfAbsent(id, () => controllerIndices.length);
    }
    int reference(Object? id, Map<String, int> indices) {
      final index = indices[id];
      if (index == null) _shape.bad();
      return index;
    }

    Map<String, Object?> booleanReferences(Object? raw) {
      final values = _shape.map(raw);
      return {
        'bindings': [
          for (final e in values.entries)
            {'agentIndex': reference(e.key, agentIndices), 'enabled': e.value},
        ],
      };
    }

    final runtime = Map<String, Object?>.of(
      _shape.map(decoded['runtime_settings_json']),
    );
    if (runtime.containsKey('agentEnabledBeforeDependencyOff')) {
      runtime['agentEnabledBeforeDependencyOff'] = booleanReferences(
        runtime['agentEnabledBeforeDependencyOff'],
      );
    }
    if (runtime.containsKey('broadcastBlocks')) {
      runtime['broadcastBlockIndices'] = [
        for (final id in _shape.list(runtime.remove('broadcastBlocks')))
          reference(id, blockIndices),
      ];
    }
    for (final key in [
      'agentBlockRestoreState',
      'controllerAlternativeBlockIds',
    ]) {
      if (!runtime.containsKey(key)) continue;
      final values = _shape.map(runtime.remove(key));
      runtime['${key}Indices'] = {
        for (final e in values.entries)
          'owner${reference(e.key, key == 'controllerAlternativeBlockIds' ? controllerIndices : agentIndices)}':
              [
                for (final id in _shape.list(e.value))
                  reference(id, blockIndices),
              ],
      };
    }
    var index = 0;
    for (final raw in _shape.list(decoded['blocks_json'])) {
      // Preserve canonical title/type AND raw-seed name/kind, never normalize.
      records.addAll(
        _fields(
          source,
          'blocks',
          'block:$index',
          nav.SectionKind.studioBlock,
          {..._shape.map(raw), 'savedArrayOrder': index},
          private: const {'id', 'targetAgentId', 'sourceAgentId'},
        ),
      );
      index++;
    }
    index = 0;
    for (final raw in _shape.list(decoded['agents_json'])) {
      records.addAll(
        _fields(
          source,
          'agents',
          'agent:${index++}',
          nav.SectionKind.studioAgents,
          _shape.map(raw),
          private: const {'id', 'controllerId', 'specId'},
        ),
      );
    }
    records.addAll(
      _fields(source, 'agents', 'enabled', nav.SectionKind.studioAgents, {
        'agentEnabled': booleanReferences(decoded['agent_enabled_json']),
      }),
    );
    records.addAll(
      _fields(
        source,
        'runtime',
        'runtime',
        nav.SectionKind.runtime,
        runtime,
        private: const {'apiConfigId'},
      ),
    );
    final settings = <String, Object?>{};
    for (final key in [
      'max_final_history_messages',
      'execution_mode',
      'updated_at',
    ])
      settings[key] = row[key];
    // API slot identities stay in exact private raw captures. Availability is a
    // fixed finite saved flag, not a credential or a resolved connection.
    for (final key in [
      'expensive_api_config_id',
      'cheap_api_config_id',
      'cleaner_api_config_id',
      'ledger_api_config_id',
    ]) {
      _shape.id(row[key], empty: true);
      settings['${key}_selected'] = (row[key] as String).isNotEmpty;
    }
    records.addAll(
      _fields(
        source,
        'settings',
        'settings',
        nav.SectionKind.settings,
        settings,
      ),
    );
    return records;
  }
}
