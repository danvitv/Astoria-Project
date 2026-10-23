part of 'api_config_repo.dart';

extension _KeylessRowShape on ApiConfigRepo {
  Future<ApiConfigRow?> _keylessRow(String id, bool Function() current) async {
    _requireKeyless(current());
    // Check dynamic SQLite primitive types before Drift maps bool/int columns.
    final raw = await _db
        .customSelect(
          'SELECT * FROM api_configs WHERE config_id = ? LIMIT 1',
          variables: [Variable<String>(id)],
          readsFrom: {_db.apiConfigs},
        )
        .getSingleOrNull();
    _requireKeyless(current());
    if (raw == null) return null;
    for (final column in _db.apiConfigs.$columns) {
      final value = raw.data[column.$name];
      _requireKeyless(switch (column.type) {
        DriftSqlType.int => value is int,
        DriftSqlType.bool => value is int && (value == 0 || value == 1),
        DriftSqlType.double => value is num && value.isFinite,
        DriftSqlType.string => value is String || value == null,
        _ => false,
      });
    }
    final row = await (_db.select(
      _db.apiConfigs,
    )..where((t) => t.configId.equals(id))).getSingleOrNull();
    _requireKeyless(current());
    return row;
  }

  KeylessApiConfigView? _keylessView(ApiConfigRow row) {
    if (row.mode != 'chat' ||
        row.apiKey != '' ||
        row.embeddingApiKey != '' ||
        row.embeddingEnabled ||
        row.embeddingUseSame ||
        row.embeddingEndpoint != '' ||
        row.embeddingModel != '' ||
        row.embeddingLlmPresetId != '' ||
        row.extraRequestParametersJson != '[]' ||
        !row.stream ||
        row.useResponsesApi != (row.protocol == 'openai_responses')) {
      return null;
    }
    try {
      return KeylessApiConfigView.native(
        connectionId: row.configId,
        displayName: row.name,
        providerId: row.providerId,
        protocol: row.protocol,
        endpoint: row.endpoint ?? '',
        model: row.model ?? '',
        maxTokens: row.maxTokens,
        contextSize: row.contextSize,
        temperature: row.temperature,
      );
    } on FormatException {
      return null;
    }
  }

  ApiConfigsCompanion _keylessInsert(KeylessApiConfigView view) =>
      _keylessCreatedRow(view).toCompanion(false);

  ApiConfigRow _keylessCreatedRow(KeylessApiConfigView view) => ApiConfigRow(
    configId: view.connectionId,
    name: view.displayName,
    providerId: view.providerId,
    protocol: view.protocol,
    endpoint: view.endpoint,
    apiKey: '',
    model: view.model,
    mode: 'chat',
    maxTokens: view.maxTokens,
    contextSize: view.contextSize,
    historyTrimMode: 'sliding',
    historyTrimTriggerPercent: 85,
    historyTrimStepPercent: 30,
    temperature: view.temperature,
    topP: 0.9,
    topK: 0,
    frequencyPenalty: 0,
    presencePenalty: 0,
    stream: true,
    reasoningEffort: 'medium',
    requestReasoning: false,
    useResponsesApi: view.protocol == 'openai_responses',
    showNativeReasoning: true,
    includeLastReasoning: false,
    reasoningHistoryCount: 0,
    excludeReasoningFromContextBudget: false,
    omitTemperature: false,
    omitTopP: false,
    omitTopK: false,
    omitFrequencyPenalty: false,
    omitPresencePenalty: false,
    omitReasoning: false,
    omitReasoningEffort: false,
    embeddingUseSame: false,
    embeddingEnabled: false,
    embeddingEndpoint: '',
    embeddingApiKey: '',
    embeddingModel: '',
    embeddingMaxChunkTokens: 512,
    embeddingRequestsPerMinute: 50,
    embeddingLlmPresetId: '',
    cacheControlTtl: 'off',
    cacheBreakpointMode: 'depth',
    sessionIdMode: 'off',
    firstChunkTimeoutMs: 60000,
    promptPostProcessing: 'none',
    useSystemInstruction: true,
    extraRequestParametersJson: '[]',
  );

  ApiConfigsCompanion _keylessPatch(KeylessApiConfigView view) =>
      ApiConfigsCompanion(
        name: Value(view.displayName),
        model: Value(view.model),
        maxTokens: Value(view.maxTokens),
        contextSize: Value(view.contextSize),
        temperature: Value(view.temperature),
      );

  ApiConfigRow _keylessPatchedRow(
    ApiConfigRow before,
    KeylessApiConfigView view,
  ) => before.copyWith(
    name: view.displayName,
    model: Value(view.model),
    maxTokens: view.maxTokens,
    contextSize: view.contextSize,
    temperature: view.temperature,
  );

  /// NULL-safe SQL CAS over the entire captured row, not timestamp seconds.
  Expression<bool> _keylessExact(ApiConfigRow expected) {
    final values = expected.toColumns(false);
    Expression<bool> match = const Constant(true);
    for (final column in _db.apiConfigs.$columns) {
      final value = values[column.$name]!;
      match =
          match &
          (value is Variable && value.value == null
              ? column.isNull()
              : column.equalsExp(value));
    }
    return match;
  }
}

void _requireKeyless(bool value) {
  if (!value) throw const _KeylessRefused();
}
