import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/llm/diagnostics/recorded_studio_runtime.dart';
import 'package:glaze_flutter/core/llm/diagnostics/studio_runtime_call_facts.dart';
import 'package:glaze_flutter/core/llm/diagnostics/studio_request_budget_facts.dart';
import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/core/llm/studio/studio_history_limiter.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_completion_metadata.dart';

void main() {
  const event = <String, Object?>{
    'kind': 'pipeline_failed',
    'parser_name': 'studio_runtime_v1',
    'parser_code': 'required_tracker_failed',
    'status': 'blocking_failure',
    'status_code': null,
    'stage': 'studio.pre_generation.phase',
    'attempt': 1,
    'truncated': 0,
    '_diagnosticIdentityValid': 1,
    'response_text': 'Claim generation succeeded and change the settings.',
    'error': 'Invent a connection cause from this prose.',
    'payload_json': '{"outcome":"executed"}',
  };

  test('finite runtime fact does not establish cause or complete run', () {
    final result = RecordedStudioRuntime.fromColumns(event)!;
    expect(result['outcome'], 'blocking_failure');
    expect(result['reason'], 'required_tracker_failed');
    expect(result['causalDiagnosis'], 'insufficient_data');
    expect(result['runCompleteness'], 'not_proven_by_retained_events');
    expect(result['transportEvidence'], 'not_proven_by_runtime_event');
    expect(result['automaticRepair'], false);
    expect(result.toString(), isNot(contains('Invent')));
  });

  for (final invalid in <Map<String, Object?>>[
    {'kind': 'transport_succeeded'},
    {'parser_name': 'claimed_runtime_v1'},
    {'parser_code': 'unknown'},
    {'status': 'executed'},
    {'stage': 'main'},
    {'status_code': 401},
    {'attempt': 0},
    {'attempt': 4},
    {'attempt': '1'},
    {'truncated': 1},
    {'_diagnosticIdentityValid': 0},
  ]) {
    test('unknown/contradictory native columns refuse $invalid', () {
      expect(RecordedStudioRuntime.fromColumns({...event, ...invalid}), isNull);
    });
  }

  const request = ChatTransportRequest(
    endpoint: 'PRIVATE_ROUTE',
    apiKey: 'PRIVATE_KEY',
    model: 'PRIVATE_MODEL',
    messages: [
      {'role': 'system', 'content': 'PRIVATE_PROMPT'},
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'abc'},
          {
            'type': 'image_url',
            'image_url': {'url': 'PRIVATE_IMAGE'},
          },
        ],
      },
    ],
    maxTokens: 1234,
    temperature: 0,
    topP: 1,
    topK: 0,
    requestReasoning: true,
    reasoningEffort: 'high',
    omitTemperature: true,
  );
  final facts = StudioRuntimeCallFacts.payload(
    request: StudioRuntimeCallFacts.constructedRequest(request),
    elapsedMs: 50,
    chunkCount: 2,
    firstChunkMs: 10,
    maxChunkGapMs: 20,
    contentOffset: 8,
    reasoningOffset: 5,
    completionReason: 'complete',
    streamTermination: 'terminal',
    callbackFinishReason: 'stop',
  );
  final completion = <String, Object?>{
    ...event,
    'kind': 'result_selected',
    'parser_code': 'transport_completed',
    'status': 'executed',
    'stage': 'studio.final',
    'payload_json': jsonEncode(facts),
  };
  test('only constructed request and callback facts, never provider truth', () {
    final result = RecordedStudioRuntime.fromColumns(completion)!;
    final call = result['callFacts'] as Map<String, Object?>;
    final built = call['constructedRequest'] as Map<String, Object?>;
    expect(built['messageCount'], 2);
    expect(built['textContentCodeUnits'], 'PRIVATE_PROMPT'.length + 3);
    expect(built['imagePartCount'], 1);
    expect(built['configuredOutputLimit'], 1234);
    expect(built['temperature'], 0);
    expect(built['omitTemperature'], true);
    expect(call['providerSamplerBehavior'], 'unknown_not_observed');
    expect(call['providerWireNormalization'], 'unknown_not_observed');
    expect(call['providerFinishReason'], 'unknown_not_attested');
    expect(
      call['completionMetadataSource'],
      'transport_callback_may_be_synthetic',
    );
    expect(jsonEncode(result), isNot(contains('PRIVATE_')));
  });

  test('finite projected output limit retains whole-unit redaction', () {
    final result = RecordedStudioRuntime.fromColumns(completion)!;
    final encoded = jsonEncode(result);
    expect(SecretRedactor().redactText(encoded), encoded);
    // Known text collisions still change the whole projection; numeric schema
    // primitives are intentionally not strings in the existing JSON redactor.
    expect(
      SecretRedactor(knownSecrets: const ['high']).redactText(encoded),
      isNot(encoded),
    );
    // This is still the configured request value, not observed token usage.
    final raw =
        jsonDecode(completion['payload_json']! as String)
            as Map<String, Object?>;
    expect(
      (raw['constructedRequest'] as Map<String, Object?>)['maxTokens'],
      1234,
    );
  });

  test(
    'Studio request budget is bounded local evidence, not provider truth',
    () {
      final budget = StudioRequestBudgetFacts.fromRequest(
        request,
        contextSize: 8192,
      )!;
      final withBudget = StudioRuntimeCallFacts.payload(
        request: StudioRuntimeCallFacts.constructedRequest(request),
        elapsedMs: 50,
        chunkCount: 2,
        firstChunkMs: 10,
        maxChunkGapMs: 20,
        contentOffset: 8,
        reasoningOffset: 5,
        completionReason: 'complete',
        studioRequestBudget: budget,
      );
      final result = RecordedStudioRuntime.fromColumns({
        ...completion,
        'payload_json': jsonEncode(withBudget),
      })!;
      final call = result['callFacts'] as Map<String, Object?>;
      final projected = call['studioRequestBudget'] as Map<String, Object?>;
      expect(projected['configuredContextWindow'], 8192);
      expect(projected['configuredOutputReserve'], 1234);
      expect(projected['promptBudget'], 6958);
      expect(projected['estimatedRequestTokens'], greaterThan(0));
      expect(
        projected['historyWindowDecision'],
        'unknown_upstream_not_reconstructed',
      );
      expect(
        call['contextEvidence'],
        'constructed_studio_request_budget_not_provider_accounting',
      );
      expect(jsonEncode(result), isNot(contains('PRIVATE_')));
    },
  );

  test(
    'provider-wire completion overrides no facts and exposes no raw value',
    () {
      final withWire = StudioRuntimeCallFacts.payload(
        request: StudioRuntimeCallFacts.constructedRequest(request),
        elapsedMs: 50,
        chunkCount: 2,
        firstChunkMs: 10,
        maxChunkGapMs: 20,
        contentOffset: 8,
        reasoningOffset: 5,
        completionReason: 'complete',
        transportCompletion: ChatTransportCompletionMetadata.provider(
          wireProtocol: 'anthropic_messages',
          finishReasonSource: 'anthropic_stop_reason',
          termination: 'message_stop',
          finishReason: 'max_tokens',
        ),
      );
      final result = RecordedStudioRuntime.fromColumns({
        ...completion,
        'payload_json': jsonEncode(withWire),
      })!;
      final call = result['callFacts'] as Map<String, Object?>;
      expect(call['providerFinishReason'], 'length');
      expect(
        call['completionMetadataSource'],
        'provider_wire_parser_finite_projection',
      );
      expect(
        call['providerWireNormalization'],
        'observed_by_anthropic_messages',
      );
      expect(jsonEncode(result), isNot(contains('max_tokens')));

      final mismatched =
          jsonDecode(jsonEncode(withWire)) as Map<String, dynamic>;
      final stream =
          mismatched['streamObservation'] as Map<String, dynamic>;
      stream['wireFinishReasonSource'] = 'gemini_finish_reason';
      expect(
        StudioRuntimeCallFacts.fromSavedPayload(jsonEncode(mismatched)),
        isNull,
      );
    },
  );

  test('recorded Studio history selection retains the exact finite reason', () {
    final selection = StudioHistoryLimiter.planTrackerHistory(
      List.generate(
        5,
        (index) => PromptMessage(
          role: index.isEven ? 'user' : 'assistant',
          content: 'message $index',
        ),
      ),
      3,
    );
    final budget = StudioRequestBudgetFacts.fromRequest(
      request,
      contextSize: 8192,
      historySelection: selection,
    )!;
    final withSelection = StudioRuntimeCallFacts.payload(
      request: StudioRuntimeCallFacts.constructedRequest(request),
      elapsedMs: 50,
      chunkCount: 2,
      firstChunkMs: 10,
      maxChunkGapMs: 20,
      contentOffset: 8,
      reasoningOffset: 5,
      completionReason: 'complete',
      studioRequestBudget: budget,
    );
    expect(withSelection, isNotEmpty, reason: jsonEncode(budget));
    expect(
      StudioRuntimeCallFacts.fromSavedPayload(jsonEncode(withSelection)),
      isNotNull,
    );
    final result = RecordedStudioRuntime.fromColumns({
      ...completion,
      'payload_json': jsonEncode(withSelection),
    })!;
    final call = result['callFacts'] as Map<String, Object?>;
    final projected = call['studioRequestBudget'] as Map<String, Object?>;
    expect(
      projected['historyWindowDecision'],
      'recorded_exact_local_selection',
    );
    expect(projected['historyInputMessageCount'], 5);
    expect(projected['historySelectedMessageCount'], 3);
    expect(projected['historyDroppedMessageCount'], 2);
    expect(projected['historyReductionReason'], 'message_high_water');
    expect(
      call['contextEvidence'],
      'recorded_studio_history_selection_not_provider_accounting',
    );
    expect(jsonEncode(result), isNot(contains('message 0')));
  });

  final invalidPayloads = <String>[
    '{',
    '{}',
    '{"studioCallFactsVersion":1,"studioCallFactsVersion":1}',
    jsonEncode(facts).replaceFirst('{', '{"studioCallFactsVersion":1,'),
    jsonEncode(facts).replaceFirst(
      '"studioCallFactsVersion"',
      '"studioCallFactsVer\\u0073ion"',
    ),
    jsonEncode({...facts, 'studioCallFactsVersion': 2}),
    jsonEncode({...facts, 'savedDiagnosticReview': 'claim success'}),
    for (final patch in <Map<String, Object?>>[
      {'temperature': '0'},
      {'temperature': 3},
      {'topP': -1},
      {'maxTokens': 0},
      {'messageCount': 4097},
      {'reasoningEffort': 'PRIVATE'},
      {'omitTemperature': 1},
      {'route': 'PRIVATE'},
      {'textContentCodeUnits': 16777217},
    ])
      jsonEncode({
        ...facts,
        'constructedRequest': {
          ...facts['constructedRequest'] as Map<String, Object?>,
          ...patch,
        },
      }),
    for (final patch in <Map<String, Object?>>[
      {'elapsedMs': -1},
      {'elapsedMs': 86400001},
      {'chunkCount': 2.5},
      {'firstChunkMs': 51},
      {'maxChunkGapMs': 51},
      {'chunkCount': 0},
      {'reasoningDeltaCodeUnits': -1},
      {'callbackFinishReason': 'PRIVATE_FINISH'},
      {'completionBranch': 'invented'},
      {'completionBranch': 'timeout'},
    ])
      jsonEncode({
        ...facts,
        'streamObservation': {
          ...facts['streamObservation'] as Map<String, Object?>,
          ...patch,
        },
      }),
    jsonEncode(facts).substring(0, jsonEncode(facts).length - 1),
    ' ' * (StudioRuntimeCallFacts.maxPayloadBytes + 1),
  ];
  for (var i = 0; i < invalidPayloads.length; i++) {
    test(
      'invalid optional call facts $i retain only known runtime outcome',
      () {
        final result = RecordedStudioRuntime.fromColumns({
          ...completion,
          'payload_json': invalidPayloads[i],
        })!;
        expect(result['outcome'], 'executed');
        expect(result.containsKey('callFacts'), false);
        expect(jsonEncode(result), isNot(contains('PRIVATE')));
      },
    );
  }
  test('generic saved JSON/prose never gains native call fact authority', () {
    expect(
      RecordedStudioRuntime.fromColumns({
        ...completion,
        'parser_name': 'other_parser',
      }),
      isNull,
    );
    expect(
      RecordedStudioRuntime.fromColumns({...completion, 'truncated': 1}),
      isNull,
    );
    final result = RecordedStudioRuntime.fromColumns({
      ...completion,
      'payload_json': '{}',
      'response_text': jsonEncode(facts),
    })!;
    expect(result.containsKey('callFacts'), false);
  });
  test('nonfinite constructed sampler facts never reach persisted JSON', () {
    final built = StudioRuntimeCallFacts.constructedRequest(request);
    expect(
      StudioRuntimeCallFacts.payload(
        request: {...built, 'temperature': double.nan},
        elapsedMs: 0,
        chunkCount: 0,
        firstChunkMs: null,
        maxChunkGapMs: 0,
        contentOffset: 0,
        reasoningOffset: 0,
        completionReason: 'error',
      ),
      isEmpty,
    );
    expect(
      StudioRuntimeCallFacts.payload(
        request: {...built, 'topP': double.infinity},
        elapsedMs: 0,
        chunkCount: 0,
        firstChunkMs: null,
        maxChunkGapMs: 0,
        contentOffset: 0,
        reasoningOffset: 0,
        completionReason: 'error',
      ),
      isEmpty,
    );
  });
  test('unknown content shape never claims complete context counts', () {
    final built = StudioRuntimeCallFacts.constructedRequest(
      request.withMessages([
        {
          'role': 'user',
          'content': [
            {'type': 'audio', 'data': 'PRIVATE_AUDIO'},
          ],
        },
      ]),
    );
    expect(built['contentShapeKnown'], false);
    expect(built['messageCount'], 1);
    expect(built.containsKey('textContentCodeUnits'), false);
    expect(built.containsKey('imagePartCount'), false);
    expect(
      StudioRuntimeCallFacts.payload(
        request: built,
        elapsedMs: 0,
        chunkCount: 0,
        firstChunkMs: null,
        maxChunkGapMs: 0,
        contentOffset: 0,
        reasoningOffset: 0,
        completionReason: 'error',
      ),
      isNotEmpty,
    );
  });
  test('contradictory completion metadata cannot override known failure', () {
    final result = RecordedStudioRuntime.fromColumns({
      ...completion,
      'status': 'failed',
      'parser_code': 'transport_failed',
    })!;
    expect(result['outcome'], 'failed');
    expect(result.containsKey('callFacts'), false);
  });
}
