import '../credentials/native_provider_credentials.dart';
import '../models/api_config.dart';
import '../models/memory_book_api_settings.dart';
import 'aux_llm_client.dart';
import 'memory_book_api_config_resolver.dart';
import 'native_saved_connection_source.dart';
import 'transport/llm_protocol.dart';

/// Memory-only source selection, injected independently from prompt/read owners.
/// This never reconstructs saved identity from an Aux DTO or acquires a key.
final class MemoryDraftApiSourceResolver {
  const MemoryDraftApiSourceResolver({
    required this.loadApiConfigs,
    required this.readActiveApiConfig,
    this.sources,
  });
  final Future<List<ApiConfig>> Function() loadApiConfigs;
  final ApiConfig? Function() readActiveApiConfig;
  final NativeSavedConnectionSourceResolver? sources;

  Future<ResolvedMemoryDraftApiSource> resolve({
    required MemoryBookApiSettings settings,
    required NativeConnectionStamp? originalStamp,
    required bool Function() isCurrent,
  }) async {
    void requireCurrent() {
      if (!isCurrent() ||
          (sources != null &&
              (originalStamp == null ||
                  !sources!.isOriginalCurrent(originalStamp, isCurrent)))) {
        throw const NativeProviderException(NativeProviderFailure.stale);
      }
    }

    requireCurrent();
    if (settings.generationSource == 'custom') {
      final config = AuxApiConfig(
        endpoint: settings.generationEndpoint,
        apiKey: settings.generationApiKey,
        model: settings.generationModel,
        protocol: LlmProtocol.customChatCompletion,
      );
      _requireConfigured(config);
      return ResolvedMemoryDraftApiSource(config: config);
    }
    final rows = await loadApiConfigs();
    requireCurrent();
    final resolver = MemoryBookApiConfigResolver(
      apiConfigs: rows,
      activeConfig: readActiveApiConfig(),
    );
    final selected = resolver.resolve(settings);
    if (selected == null) throw Exception('No chat API config available');
    final source = sources == null
        ? null
        : await sources!.prepare(
            originalStamp: originalStamp!,
            configuration: selected,
            purpose: NativeProviderPurpose.memoryBooks,
            isCurrent: isCurrent,
          );
    requireCurrent();
    source?.requireCurrent();
    final configuration = source?.configuration ?? selected;
    final model = settings.generationModel.isNotEmpty
        ? settings.generationModel
        : configuration.model;
    source?.requireModel(model);
    final config = AuxApiConfig(
      endpoint: configuration.endpoint,
      apiKey: configuration.apiKey,
      model: model,
      protocol: configuration.protocol,
      useResponsesApi: configuration.useResponsesApi,
      omitTemperature: configuration.omitTemperature,
      extraRequestParameters: configuration.extraRequestParameters,
      savedConnectionId: configuration.id,
      savedConnectionAuth: source?.savedConnectionAuth,
      nativeSource: source,
    );
    _requireConfigured(config);
    return ResolvedMemoryDraftApiSource(
      config: config,
      configuration: configuration,
      source: source,
      receiveTimeoutMs: resolver.resolveTimeoutMs(settings),
    );
  }

  static void _requireConfigured(AuxApiConfig config) {
    if ((config.protocol != LlmProtocol.openrouter &&
            config.endpoint.isEmpty) ||
        config.model.isEmpty) {
      throw Exception('API not configured for memory generation');
    }
  }
}

final class ResolvedMemoryDraftApiSource {
  const ResolvedMemoryDraftApiSource({
    required this.config,
    this.configuration,
    this.source,
    this.receiveTimeoutMs,
  });
  final AuxApiConfig config;
  final ApiConfig? configuration;
  final NativePreparedSavedConnection? source;
  final int? receiveTimeoutMs;
}
