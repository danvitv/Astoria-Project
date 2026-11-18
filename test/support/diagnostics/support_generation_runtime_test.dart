import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/llm/context_calculator.dart';
import 'package:glaze_flutter/core/llm/diagnostics/generation_runtime_call_facts.dart';
import 'package:glaze_flutter/core/llm/diagnostics/recorded_generation_runtime.dart';
import 'package:glaze_flutter/core/llm/diagnostics/recorded_runtime_source_projection.dart';
import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';

Map<String, dynamic> _payload({String completion = 'complete'}) {
  final request = const ChatTransportRequest(
    endpoint: 'https://private.invalid/v1',
    apiKey: 'PRIVATE_KEY',
    model: 'PRIVATE_MODEL',
    messages: [
      {'role': 'user', 'content': 'PRIVATE_PROMPT'},
    ],
    maxTokens: 321,
    temperature: 0.7,
    topP: 0.8,
    topK: 40,
    requestReasoning: true,
    reasoningEffort: 'medium',
  );
  return GenerationRuntimeCallFacts.payload(
    request: GenerationRuntimeCallFacts.constructedRequest(request),
    elapsedMs: 25,
    chunkCount: completion == 'complete' ? 2 : 0,
    firstChunkMs: completion == 'complete' ? 5 : null,
    maxChunkGapMs: completion == 'complete' ? 10 : 0,
    contentOffset: completion == 'complete' ? 3 : 0,
    reasoningOffset: completion == 'complete' ? 2 : 0,
    completionReason: completion,
    streamTermination: completion == 'complete' ? 'terminal' : null,
    callbackFinishReason: completion == 'complete' ? 'stop' : null,
    contextPlanning: GenerationRuntimeCallFacts.contextPlanning(
      breakdown: const TokenBreakdown(
        sourceTokens: {'history': 20},
        staticTotal: 40,
        historyBudget: 100,
        historyTokens: 20,
        totalTokens: 60,
        cutoffIndex: 1,
        trimmedHistory: [
          PromptMessage(role: 'user', content: 'kept'),
          PromptMessage(role: 'assistant', content: 'also kept'),
        ],
        fixedTotal: 40,
        remaining: 40,
        tokenEstimatorMode: 'heuristic_4_code_units',
        historyInputMessageCount: 3,
        historyInputTextCodeUnits: 24,
        historyKeptTextCodeUnits: 13,
      ),
      contextSize: 1000,
      outputReserve: 200,
      historyTrimMode: 'sliding',
    ),
  );
}

Map<String, Object?> _row({
  String kind = 'transport_succeeded',
  String status = 'ok',
  int statusCode = 200,
  String completion = 'complete',
}) => {
  'stage': 'main',
  'attempt': 1,
  '_diagnosticIdentityValid': 1,
  'truncated': 0,
  'parser_name': null,
  'parser_code': null,
  'parser_detail': null,
  'kind': kind,
  'status': status,
  'status_code': statusCode,
  'payload_json': jsonEncode(_payload(completion: completion)),
};

void main() {
  test(
    'ordinary main runtime exposes finite facts without request content',
    () {
      final result = RecordedGenerationRuntime.fromColumns(_row())!;
      expect(result['finding'], 'recorded_generation_runtime_outcome');
      expect(result['outcome'], 'completed');
      final call = result['callFacts'] as Map<String, Object?>;
      final request = call['constructedRequest'] as Map<String, Object?>;
      expect(request['configuredOutputLimit'], 321);
      expect(request['messageCount'], 1);
      expect(request['requestReasoning'], isTrue);
      expect(call['providerFinishReason'], 'unknown_not_attested');
      expect(call['providerWireNormalization'], 'unknown_not_observed');
      expect(call['providerSamplerBehavior'], 'unknown_not_observed');
      final context = call['contextPlanning'] as Map<String, Object?>;
      expect(context['configuredContextWindow'], 1000);
      expect(context['promptBudget'], 800);
      expect(context['historyMessagesBefore'], 3);
      expect(context['historyMessagesAfter'], 2);
      expect(context['historyTextCodeUnitsBefore'], 24);
      expect(context['historyTextCodeUnitsAfter'], 13);
      expect(context['reductionReason'], 'sliding_budget_limit');
      expect(
        call['contextEvidence'],
        'recorded_prompt_builder_plan_not_provider_accounting',
      );
      expect(result['contextBudgetEvidence'], 'recorded_prompt_builder_plan');
      final encoded = jsonEncode(result);
      for (final private in [
        'PRIVATE_KEY',
        'PRIVATE_MODEL',
        'PRIVATE_PROMPT',
        'private.invalid',
      ]) {
        expect(encoded, isNot(contains(private)));
      }
    },
  );

  test('outcome columns and callback branch must agree exactly', () {
    expect(
      RecordedGenerationRuntime.fromColumns(
        _row(
          kind: 'transport_failed',
          status: 'timeout',
          statusCode: 0,
          completion: 'timeout',
        ),
      )?['outcome'],
      'failed',
    );
    expect(
      RecordedGenerationRuntime.fromColumns(
        _row(
          kind: 'transport_failed',
          status: 'http_4xx',
          statusCode: 429,
          completion: 'error',
        ),
      )?['transportStatus'],
      'http_4xx',
    );
    expect(
      RecordedGenerationRuntime.fromColumns(
        _row(kind: 'transport_failed', status: 'timeout', statusCode: 0),
      ),
      isNull,
    );
    expect(
      RecordedGenerationRuntime.fromColumns(
        _row(
          kind: 'transport_failed',
          status: 'http_4xx',
          statusCode: 200,
          completion: 'error',
        ),
      ),
      isNull,
    );
  });

  test('Source4 projection survives native JSON-string secret scanning', () {
    final runtime = RecordedGenerationRuntime.fromColumns(_row())!;
    final projected = RecordedRuntimeSourceProjection.fromRuntime(runtime)!;
    final encoded = jsonEncode({
      'operation': 'astoria_source_read',
      'pieces': [
        {'complete': true, 'payload': projected},
      ],
    });

    expect(projected['actualUsageEvidence'], 'unknown_not_recorded');
    expect(projected, isNot(contains('actualTokenUse')));
    expect(SecretRedactor().redactJson(encoded), encoded);
  });

  test('Source4 projection safely re-keys Studio budget unit names', () {
    final projected = RecordedRuntimeSourceProjection.fromRuntime({
      'callFacts': {
        'studioRequestBudget': {
          'estimatedRequestTokens': 20,
          'estimatedRemainingTokens': 80,
          'historyTokenBudget': 60,
          'historyEstimatedInputTokens': 50,
          'historyEstimatedSelectedTokens': 40,
        },
      },
    })!;
    final encoded = jsonEncode(projected);

    expect(encoded, contains('estimatedRequestUnits'));
    expect(encoded, contains('historyEstimatedSelectedUnits'));
    expect(encoded, isNot(contains('Tokens')));
    expect(encoded, isNot(contains('TokenBudget')));
    expect(SecretRedactor().redactJson(encoded), encoded);
  });

  test('context planning rejects inconsistent reduction metadata', () {
    final payload = Map<String, dynamic>.from(_payload());
    final context = Map<String, Object?>.from(payload['contextPlanning'] as Map)
      ..['historyMessagesAfter'] = 3;
    payload['contextPlanning'] = context;
    expect(
      RecordedGenerationRuntime.fromColumns({
        ..._row(),
        'payload_json': jsonEncode(payload),
      }),
      isNull,
    );
  });
}
