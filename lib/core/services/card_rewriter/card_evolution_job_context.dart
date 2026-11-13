import 'dart:convert';

import '../../llm/aux_llm_client.dart';
import '../../llm/card_rewrite_slot_resolver.dart';
import '../../llm/studio_turn_config_snapshot.dart';
import '../../models/card_rewriter_settings.dart';
import '../../utils/cast_helpers.dart';

/// Credentials and prepared native-source authority stay in memory only. The
/// durable descriptor records routing/settings fingerprints, never API keys,
/// endpoints (which may contain credentials), or extra-parameter values.
final class CardEvolutionJobContext {
  CardEvolutionJobContext({
    required this.collector,
    required this.writer,
    required this.settings,
  });

  factory CardEvolutionJobContext.capture(StudioTurnConfigSnapshot turn) {
    final settings = turn.pipelineSettings.cardRewriter;
    AuxApiConfig? writer;
    try {
      writer = CardRewriteSlotResolver.resolve(
        apiConfigs: turn.apiConfigs,
        apiConfigId: settings.apiConfigId,
        modelOverride: settings.modelOverride,
      );
    } on CardRewriteModelNotConfigured {
      // Collector work remains useful before the dedicated writer is set up.
      // The writer fails explicitly when its own cadence is reached.
    }
    return CardEvolutionJobContext(
      collector: turn.resolveLedgerConfig(errorLabel: 'card-collector'),
      writer: writer,
      settings: settings,
    );
  }

  final AuxApiConfig collector;
  final AuxApiConfig? writer;
  final CardRewriterSettings settings;

  String get descriptorJson => jsonEncode({
    'version': 1,
    'settings': settings.toJson(),
    'collector': _route(collector),
    'writer': writer == null ? null : _route(writer!),
  });

  bool matches(String descriptor) => descriptorJson == descriptor;

  static Map<String, Object?> _route(AuxApiConfig config) => {
    'connectionId': config.savedConnectionId,
    'endpointHash': computeHash(config.endpoint),
    'model': config.model,
    'protocol': config.protocol,
    'maxTokens': config.maxTokens,
    'responses': config.useResponsesApi,
    'omitTemperature': config.omitTemperature,
    'extraParametersHash': computeHash(
      jsonEncode(
        config.extraRequestParameters
            .map((parameter) => parameter.toJson())
            .toList(),
      ),
    ),
  };
}
