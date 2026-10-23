part of 'api_config_repo.dart';

extension _ApiConfigGuardedOrdinaryWrites on ApiConfigRepo {
  Future<T> _runOrdinaryGuard<T>(
    ApiConfigOrdinaryMutationGuard guard,
    String label,
    Future<T> Function() operation,
  ) async {
    try {
      // Optional native protection cannot settle inside a caller's still-open
      // outer transaction. Guard-null legacy transaction behavior is unchanged.
      // ignore: invalid_use_of_internal_member
      _requireKeyless(_db.resolvedEngine.executor is! TransactionExecutor);
      // Root run retains its native owner through completion/failure and installs
      // the observed zone. Hooks must never run outside that zone.
      return await guard.run(
        connectionId: label,
        operation: () async {
          final finish = onMutationStarted?.call();
          try {
            return await _db.transaction(operation);
          } finally {
            finish?.call();
          }
        },
      );
    } catch (_) {
      throw const KeylessApiConfigException();
    }
  }

  Future<void> _putGuarded(
    ApiConfig config,
    ApiConfigOrdinaryMutationGuard guard,
  ) async {
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
    // Fresh previous row and normalized proposal are read/checked in the SAME
    // held ordinary mutation. The guard may only deny/disable its actual target.
    final row = await (_db.select(
      _db.apiConfigs,
    )..where((t) => t.configId.equals(config.id))).getSingleOrNull();
    await guard.beforePut(
      existing: row == null ? null : _toModel(row),
      proposed: persisted,
    );
    await _db
        .into(_db.apiConfigs)
        .insertOnConflictUpdate(_toCompanion(persisted));
  }
}
