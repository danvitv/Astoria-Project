import '../../llm/transport/endpoint_normalizer.dart';
import 'backup_secret_urls.dart';

/// Fail-closed proof for live credential destinations, not a routing engine.
abstract final class BackupSecretRoutes {
  static const apiColumns = [
    'endpoint',
    'embedding_endpoint',
    'protocol',
    'model',
    'stream',
    'use_responses_api',
    'mode',
    'embedding_use_same',
    'embedding_llm_preset_id',
  ];

  static bool flag(Object? value, bool fallback) => value is bool
      ? value
      : value is num
      ? value != 0
      : fallback;

  static String llm(Map<String, dynamic>? row) {
    if (row == null) return '';
    final raw = row['endpoint']?.toString() ?? '';
    if (raw.trim().isEmpty) return '';
    if (!EndpointNormalizer.parse(raw).isValid) return '';
    return EndpointNormalizer.persistedLlmEndpoint(
      raw: raw,
      protocol: row['protocol']?.toString() ?? 'openai',
      model: row['model']?.toString() ?? '',
      stream: flag(row['stream'], true),
      useResponsesApi: flag(row['use_responses_api'], false),
    );
  }

  static bool same(String? a, String? b, bool Function(String) credential) =>
      a != null &&
      b != null &&
      a.isNotEmpty &&
      b.isNotEmpty &&
      BackupSecretUrls.sameDestination(a, b, credential);

  static bool sameLlm(
    Map<String, dynamic>? a,
    Map<String, dynamic>? b,
    bool Function(String) credential,
  ) =>
      a != null &&
      b != null &&
      (a['protocol'] ?? 'openai') == (b['protocol'] ?? 'openai') &&
      same(llm(a), llm(b), credential);

  static String embedding(
    Map<String, dynamic>? row,
    Map<String, Map<String, dynamic>> routes,
    Map<String, dynamic> prefs,
  ) {
    if (row == null) return '';
    final endpoint = row['embedding_endpoint']?.toString() ?? '';
    if (!flag(row['embedding_use_same'], true) && endpoint.isNotEmpty) {
      return EndpointNormalizer.persistedEmbeddingEndpoint(endpoint);
    }
    // Dedicated embedding presets borrow the pinned/active LLM route.
    final source = row['mode'] == 'embedding'
        ? routes[(row['embedding_llm_preset_id']?.toString().isNotEmpty ??
                  false)
              ? row['embedding_llm_preset_id']
              : prefs['activeApiConfigId']]
        : row;
    return llm(source);
  }

  static String cleaner(
    Map<String, dynamic>? preset,
    Map<String, Map<String, dynamic>> routes,
    Map<String, dynamic> prefs,
  ) {
    if (preset == null) return '';
    final route = cleanerRoute(preset, routes, prefs);
    if (route == null || route['mode'] == 'embedding') return '';
    // Model/Responses overrides can alter the concrete destination; retain
    // narrow scalar ownership alongside the slot rather than whole runtime.
    final model = preset['cleaner_model']?.toString() ?? '';
    return llm({
      ...route,
      if (model.isNotEmpty) 'model': model,
      if (preset['cleaner_responses'] != null)
        'use_responses_api': preset['cleaner_responses'],
    });
  }

  static Map<String, dynamic>? cleanerRoute(
    Map<String, dynamic>? preset,
    Map<String, Map<String, dynamic>> routes,
    Map<String, dynamic> prefs,
  ) {
    if (preset == null) return null;
    final slot = preset['cleaner_api_config_id']?.toString() ?? '';
    return routes[slot.isNotEmpty ? slot : prefs['activeApiConfigId']];
  }
}
