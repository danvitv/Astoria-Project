import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/models/card_rewriter_settings.dart';
import 'package:glaze_flutter/core/models/extra_request_parameter.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_evolution_job_context.dart';

void main() {
  CardEvolutionJobContext context({
    String model = 'model',
    String key = 'secret-key',
  }) => CardEvolutionJobContext(
    collector: AuxApiConfig(
      savedConnectionId: 'saved',
      endpoint: 'https://example.test?token=endpoint-secret',
      apiKey: key,
      model: model,
      protocol: 'openai',
      extraRequestParameters: const [
        ExtraRequestParameter(key: 'secret', value: 'parameter-secret'),
      ],
    ),
    writer: null,
    settings: const CardRewriterSettings(enabled: true),
  );

  test('durable context contains no credentials or raw extra parameters', () {
    final saved = context().descriptorJson;
    expect(saved, isNot(contains('secret-key')));
    expect(saved, isNot(contains('endpoint-secret')));
    expect(saved, isNot(contains('parameter-secret')));
    expect(saved, isNot(contains('https://')));
    expect(context().matches(saved), isTrue);
  });

  test(
    'recovery refuses rerouting but permits credential renewal on same route',
    () {
      final saved = context().descriptorJson;
      expect(context(model: 'different').matches(saved), isFalse);
      expect(context(key: 'rotated-key').matches(saved), isTrue);
    },
  );
}
