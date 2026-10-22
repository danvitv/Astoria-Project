import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_recipient_resolution.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_recipient_projection.dart';

// Pure projection only: static fake config/redactor, no providers/storage/IO.
const _canary = 'STATIC_PROJECTION_SECRET_785319';
const _projection = SupportRecipientProjection();
const _context = SupportRecipientContext(
  supportSessionId: 'synthetic-support',
  epoch: 1,
);

SupportResolvedRecipient? _project(
  String endpoint, {
  String protocol = LlmProtocol.openai,
  bool stream = true,
  bool responses = false,
  SecretRedactor? redactor,
}) => _projection.project(
  context: _context,
  config: ApiConfig(
    id: 'synthetic-connection',
    name: 'Same label',
    apiKey: _canary,
    endpoint: endpoint,
    protocol: protocol,
    stream: stream,
    useResponsesApi: responses,
  ),
  modelId: 'synthetic-model',
  revision: 1,
  redactor: redactor ?? SecretRedactor(knownSecrets: [_canary]),
);

void main() {
  for (final entry in [
    (
      'https://synthetic.invalid/v1/chat/completions',
      'HTTPS · synthetic.invalid',
    ),
    (
      'http://synthetic.invalid/v1/chat/completions',
      'HTTP · synthetic.invalid',
    ),
    (
      'https://replacement.invalid/v1/chat/completions',
      'HTTPS · replacement.invalid',
    ),
    (
      'https://synthetic.invalid:8443/v1/chat/completions',
      'HTTPS · synthetic.invalid:8443',
    ),
    (
      'http://synthetic.invalid:8080/v1/chat/completions',
      'HTTP · synthetic.invalid:8080',
    ),
    (
      'https://[2001:db8::1]:8443/v1/chat/completions',
      'HTTPS · [2001:db8::1]:8443',
    ),
  ]) {
    test(
      'validated origin ${entry.$2} is accurately bounded and has no raw URL',
      () {
        final projected = _project(entry.$1)!;
        expect(projected.originLabel, entry.$2);
        expect(projected.operationLabel, 'Chat Completions');
        expect(projected.connectionLabel, 'Same label');
        expect(projected.recipient.modelId, 'synthetic-model');
        expect(projected.originLabel, isNot(contains('://')));
        expect(projected.originLabel, isNot(contains('/v1/')));
        expect(projected.originLabel, isNot(contains(_canary)));
        expect(projected.originLabel.length, lessThanOrEqualTo(512));
      },
    );
  }

  for (final endpoint in [
    'https://synthetic.invalid:443/v1/chat/completions',
    'http://synthetic.invalid:80/v1/chat/completions',
  ]) {
    test('raw explicit default port alias stays unavailable: $endpoint', () {
      // Existing raw URI spelling validation rejects Uri normalization aliases.
      // Do not invent a review or weaken that rule for the new display fields.
      expect(_project(endpoint), isNull);
    });
  }

  test('specific actual operations, including both checked Gemini suffixes', () {
    for (final entry in [
      (LlmProtocol.openaiResponses, '/v1/responses', 'Responses'),
      (LlmProtocol.anthropic, '/v1/messages', 'Messages'),
    ]) {
      expect(
        _project(
          'https://synthetic.invalid${entry.$2}',
          protocol: entry.$1,
        )!.operationLabel,
        entry.$3,
      );
    }
    expect(
      _project(
        'https://synthetic.invalid/v1/responses',
        protocol: LlmProtocol.customChatCompletion,
        responses: true,
      )!.operationLabel,
      'Responses',
    );
    for (final stream in [false, true]) {
      final operation = stream ? 'streamGenerateContent' : 'generateContent';
      final result = _project(
        'https://synthetic.invalid/v1beta/models/synthetic-model:$operation',
        protocol: LlmProtocol.gemini,
        stream: stream,
      )!;
      expect(result.originLabel, 'HTTPS · synthetic.invalid');
      expect(result.operationLabel, 'Gemini $operation');
      expect(
        _project(
          'https://synthetic.invalid/v1beta/models/synthetic-model:$operation',
          protocol: LlmProtocol.gemini,
          stream: !stream,
        ),
        isNull,
      );
    }
  });

  test(
    'OpenRouter display uses fixed actual route, not arbitrary saved endpoint',
    () {
      final result = _project(
        'http://saved.invalid:8080/private?key=$_canary',
        protocol: LlmProtocol.openrouter,
      )!;
      expect(result.originLabel, 'HTTPS · openrouter.ai');
      expect(result.operationLabel, 'Chat Completions');
      expect(result.routingLabel, contains('downstream'));
      expect(result.routingLabel, contains('не подтверждён'));
      expect(result.originLabel, isNot(contains('saved')));
    },
  );

  for (final endpoint in [
    'https://user:$_canary@synthetic.invalid/v1/chat/completions',
    'https://synthetic.invalid/v1/chat/completions?key=$_canary',
    'https://synthetic.invalid/v1/chat/completions#$_canary',
    'https://$_canary.invalid/v1/chat/completions',
    'https://synthetic.invalid/$_canary/v1/chat/completions',
    'https://synthetic.invalid/private-deployment/v1/chat/completions',
    'https://synthetic.invalid/v1/chat/%63ompletions',
    'https://synthetic.invalid/v1/chat/completions\n',
  ]) {
    test('unsafe input never fabricates display: $endpoint', () {
      expect(_project(endpoint), isNull);
    });
  }

  test(
    'current redactor remains authoritative before projecting origin/operation',
    () {
      expect(
        _project(
          'https://synthetic.invalid/v1/chat/completions',
          redactor: SecretRedactor(knownSecrets: ['synthetic.invalid']),
        ),
        isNull,
      );
      expect(
        _project(
          'https://synthetic.invalid/v1/chat/completions',
          redactor: SecretRedactor(knownSecrets: ['completions']),
        ),
        isNull,
      );
    },
  );
}
