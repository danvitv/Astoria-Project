import 'dart:convert';

import 'package:drift/drift.dart';

import '../app_db.dart';
import '../../models/api_config.dart';
import '../../application/sync_repo_interfaces.dart';
import '../../models/extra_request_parameter.dart';
import '../../llm/history_trim.dart';
import '../../llm/transport/endpoint_normalizer.dart';
import '../../models/keyless_api_config.dart';
import '../../models/support_models.dart';
import 'support_repo.dart';

part 'api_config_keyless_contract.dart';
part 'api_config_keyless_store.dart';
part 'api_config_keyless_operation.dart';
part 'api_config_keyless_terminal.dart';
part 'api_config_keyless_ordinary_guard.dart';
part 'api_config_keyless_shape.dart';
part 'api_config_keyless_evidence.dart';
part 'support_provider_setup_repo.dart';

class ApiConfigRepo implements SyncApiConfigStore {
  final AppDatabase _db;
  final void Function(ApiConfig)? onConfigObserved;
  // Feature-free fence: no settings, credentials or feature models cross it.
  late final void Function() Function()? onMutationStarted;
  final void Function() Function()? _mutationHook;
  final KeylessNativeMutationPort? _keylessMutations;
  final KeylessCreateUndoProofPort? _keylessCreateUndoProof;
  final ApiConfigOrdinaryMutationGuard? _ordinaryMutations;
  final _keyless = _KeylessRevisionState();
  ApiConfigRepo(
    this._db, {
    this.onConfigObserved,
    void Function() Function()? onMutationStarted,
    this._keylessMutations,
    this._keylessCreateUndoProof,
    this._ordinaryMutations,
  }) : _mutationHook = onMutationStarted {
    this.onMutationStarted = () => _keyless.start(_mutationHook);
  }

  /// Commit notifications without rows or credentials. Drift defers updates
  /// until the true outer commit, including native setup, Undo and imports.
  Stream<void> watchChanges() => _db
      .tableUpdates(TableUpdateQuery.onTable(_db.apiConfigs))
      .map<void>((_) {});

  @override
  Future<List<ApiConfig>> getAll() async {
    final rows = await _db.select(_db.apiConfigs).get();
    final configs = rows.map(_toModel).toList();
    final observe = onConfigObserved;
    if (observe != null) {
      for (final config in configs) {
        observe(config);
      }
    }
    return configs;
  }

  /// Bounded native metadata projection. Does not select/observe credential
  /// columns or hydrate ApiConfig objects for a feature/tool list.
  Future<List<String>> getConfigIds({int limit = 256}) async {
    if (limit < 1 || limit > 256) throw const KeylessApiConfigException();
    try {
      final id = _db.apiConfigs.configId;
      final rows =
          await (_db.selectOnly(_db.apiConfigs)
                ..addColumns([id])
                ..orderBy([OrderingTerm.asc(id)])
                ..limit(limit))
              .get();
      return List.unmodifiable(rows.map((row) => row.read(id)!));
    } catch (_) {
      throw const KeylessApiConfigException();
    }
  }

  @override
  Future<ApiConfig?> getById(String id) async {
    final row = await (_db.select(
      _db.apiConfigs,
    )..where((t) => t.configId.equals(id))).getSingleOrNull();
    if (row == null) return null;
    final config = _toModel(row);
    onConfigObserved?.call(config);
    return config;
  }

  @override
  Future<void> put(ApiConfig config) async {
    final guard = _ordinaryMutations;
    if (guard != null) {
      // Diagnostic protection is synchronous, even when admission is queued or
      // denied. This only registers raw input; it does not migrate any key.
      onConfigObserved?.call(config);
      return _runOrdinaryGuard(
        guard,
        config.id,
        () => _putGuarded(config, guard),
      );
    }
    final finish = onMutationStarted?.call();
    try {
      await _put(config);
    } finally {
      finish?.call();
    }
  }

  Future<void> _put(ApiConfig config) async {
    onConfigObserved?.call(config);
    final persisted = config.copyWith(
      endpoint: EndpointNormalizer.persistedLlmEndpoint(
        raw: config.endpoint,
        protocol: config.protocol,
        model: config.model,
        stream: config.stream,
        useResponsesApi: config.useResponsesApi,
      ),
      embeddingEndpoint: EndpointNormalizer.persistedEmbeddingEndpoint(
        config.embeddingEndpoint,
      ),
    );
    onConfigObserved?.call(persisted);
    await _db
        .into(_db.apiConfigs)
        .insertOnConflictUpdate(_toCompanion(persisted));
  }

  @override
  Future<void> delete(String id) async {
    final guard = _ordinaryMutations;
    if (guard != null) {
      return _runOrdinaryGuard(guard, id, () async {
        await guard.beforeDelete(id);
        await (_db.delete(
          _db.apiConfigs,
        )..where((t) => t.configId.equals(id))).go();
      });
    }
    final finish = onMutationStarted?.call();
    try {
      await (_db.delete(
        _db.apiConfigs,
      )..where((t) => t.configId.equals(id))).go();
    } finally {
      finish?.call();
    }
  }

  Future<void> putFromMap(Map<String, dynamic> m) async {
    final guard = _ordinaryMutations;
    if (guard != null) {
      ApiConfig? observed;
      try {
        observed = ApiConfig.fromJson(m);
      } catch (_) {
        // Malformed decode still belongs to the original fenced operation below.
      }
      if (observed != null) onConfigObserved?.call(observed);
      final label = m['id'];
      return _runOrdinaryGuard(guard, label is String ? label : '', () async {
        // The original observer begins INSIDE run, before even malformed decode.
        final config = ApiConfig.fromJson(m);
        await _putGuarded(config, guard);
      });
    }
    final finish = onMutationStarted?.call();
    try {
      final config = ApiConfig.fromJson(m);
      await _put(config);
    } finally {
      finish?.call();
    }
  }

  ApiConfig _toModel(ApiConfigRow c) => ApiConfig(
    id: c.configId,
    name: c.name,
    providerId: c.providerId,
    protocol: c.protocol,
    endpoint: c.endpoint ?? '',
    apiKey: c.apiKey ?? '',
    model: c.model ?? '',
    mode: c.mode,
    maxTokens: c.maxTokens,
    contextSize: c.contextSize,
    historyTrimMode: HistoryTrimMode.normalize(c.historyTrimMode),
    historyTrimTriggerPercent: c.historyTrimTriggerPercent,
    historyTrimStepPercent: c.historyTrimStepPercent,
    temperature: c.temperature,
    topP: c.topP,
    topK: c.topK,
    frequencyPenalty: c.frequencyPenalty,
    presencePenalty: c.presencePenalty,
    stream: c.stream,
    reasoningEffort: c.reasoningEffort ?? 'medium',
    requestReasoning: c.requestReasoning,
    useResponsesApi: c.useResponsesApi,
    showNativeReasoning: c.showNativeReasoning,
    reasoningHistoryCount: c.reasoningHistoryCount,
    excludeReasoningFromContextBudget: c.excludeReasoningFromContextBudget,
    reasoningTagStart: c.reasoningTagStart,
    reasoningTagEnd: c.reasoningTagEnd,
    embeddingUseSame: c.embeddingUseSame,
    embeddingEnabled: c.embeddingEnabled,
    embeddingEndpoint: c.embeddingEndpoint ?? '',
    embeddingApiKey: c.embeddingApiKey ?? '',
    embeddingModel: c.embeddingModel ?? '',
    embeddingMaxChunkTokens: c.embeddingMaxChunkTokens,
    embeddingRequestsPerMinute: c.embeddingRequestsPerMinute,
    embeddingLlmPresetId: c.embeddingLlmPresetId,
    omitTemperature: c.omitTemperature,
    omitTopP: c.omitTopP,
    omitTopK: c.omitTopK,
    omitFrequencyPenalty: c.omitFrequencyPenalty,
    omitPresencePenalty: c.omitPresencePenalty,
    omitReasoning: c.omitReasoning,
    omitReasoningEffort: c.omitReasoningEffort,
    cacheControlTtl: c.cacheControlTtl,
    cacheBreakpointMode: c.cacheBreakpointMode,
    sessionIdMode: c.sessionIdMode,
    promptPostProcessing: c.promptPostProcessing,
    firstChunkTimeoutMs: c.firstChunkTimeoutMs,
    useSystemInstruction: c.useSystemInstruction,
    extraRequestParameters:
        (jsonDecode(c.extraRequestParametersJson) as List<dynamic>)
            .map(
              (value) => ExtraRequestParameter.fromJson(
                Map<String, dynamic>.from(value as Map),
              ),
            )
            .toList(growable: false),
  );

  ApiConfigsCompanion _toCompanion(ApiConfig m) => ApiConfigsCompanion(
    configId: Value(m.id),
    name: Value(m.name),
    providerId: Value(m.providerId),
    protocol: Value(m.protocol),
    endpoint: Value(m.endpoint),
    apiKey: Value(m.apiKey),
    model: Value(m.model),
    mode: Value(m.mode),
    maxTokens: Value(m.maxTokens),
    contextSize: Value(m.contextSize),
    historyTrimMode: Value(HistoryTrimMode.normalize(m.historyTrimMode)),
    historyTrimTriggerPercent: Value(m.historyTrimTriggerPercent),
    historyTrimStepPercent: Value(m.historyTrimStepPercent),
    temperature: Value(m.temperature),
    topP: Value(m.topP),
    topK: Value(m.topK),
    frequencyPenalty: Value(m.frequencyPenalty),
    presencePenalty: Value(m.presencePenalty),
    stream: Value(m.stream),
    reasoningEffort: Value(m.reasoningEffort),
    requestReasoning: Value(m.requestReasoning),
    useResponsesApi: Value(m.useResponsesApi),
    showNativeReasoning: Value(m.showNativeReasoning),
    includeLastReasoning: Value(m.reasoningHistoryCount != 0),
    reasoningHistoryCount: Value(m.reasoningHistoryCount),
    excludeReasoningFromContextBudget: Value(
      m.excludeReasoningFromContextBudget,
    ),
    reasoningTagStart: Value(m.reasoningTagStart),
    reasoningTagEnd: Value(m.reasoningTagEnd),
    embeddingUseSame: Value(m.embeddingUseSame),
    embeddingEnabled: Value(m.embeddingEnabled),
    embeddingEndpoint: Value(m.embeddingEndpoint),
    embeddingApiKey: Value(m.embeddingApiKey),
    embeddingModel: Value(m.embeddingModel),
    embeddingMaxChunkTokens: Value(m.embeddingMaxChunkTokens),
    embeddingRequestsPerMinute: Value(m.embeddingRequestsPerMinute),
    embeddingLlmPresetId: Value(m.embeddingLlmPresetId),
    omitTemperature: Value(m.omitTemperature),
    omitTopP: Value(m.omitTopP),
    omitTopK: Value(m.omitTopK),
    omitFrequencyPenalty: Value(m.omitFrequencyPenalty),
    omitPresencePenalty: Value(m.omitPresencePenalty),
    omitReasoning: Value(m.omitReasoning),
    omitReasoningEffort: Value(m.omitReasoningEffort),
    cacheControlTtl: Value(m.cacheControlTtl),
    cacheBreakpointMode: Value(m.cacheBreakpointMode),
    sessionIdMode: Value(m.sessionIdMode),
    promptPostProcessing: Value(m.promptPostProcessing),
    firstChunkTimeoutMs: Value(m.firstChunkTimeoutMs),
    useSystemInstruction: Value(m.useSystemInstruction),
    extraRequestParametersJson: Value(
      jsonEncode(
        m.extraRequestParameters.map((value) => value.toJson()).toList(),
      ),
    ),
  );
}
