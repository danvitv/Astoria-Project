import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/agent_runner.dart';
import 'package:glaze_flutter/core/llm/agent_stream_runner.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/llm_call_event.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

class _FakeTransport implements ChatTransport {
  _FakeTransport({
    this.delay,
    this.waitForCancellation = false,
    this.completedText = 'complete response',
    this.completedReasoning,
    this.chunks = const [],
    this.chunkDelay = Duration.zero,
  });

  final Duration? delay;
  final bool waitForCancellation;
  final String completedText;
  final String? completedReasoning;
  final List<(String, String?)> chunks;
  final Duration chunkDelay;
  final ready = Completer<void>();
  final returnedAfterCancellation = Completer<void>();
  ChatTransportOnUpdate? savedOnUpdate;
  ChatTransportOnComplete? savedOnComplete;
  ChatTransportOnError? savedOnError;
  ChatTransportRequest? request;
  bool cancelled = false;

  @override
  Future<void> stream({
    required ChatTransportRequest request,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
    ChatTransportOnError? onError,
  }) async {
    this.request = request;
    savedOnUpdate = onUpdate;
    savedOnComplete = onComplete;
    savedOnError = onError;
    await Future<void>.delayed(delay ?? Duration.zero);
    for (final (text, reasoning) in chunks) {
      if (chunkDelay != Duration.zero) {
        await Future<void>.delayed(chunkDelay);
      }
      onUpdate?.call(text, reasoning);
    }
    if (!ready.isCompleted) ready.complete();
    if (waitForCancellation) {
      await cancelToken!.whenCancel;
      cancelled = true;
      returnedAfterCancellation.complete();
      return;
    }
    onComplete?.call(completedText, completedReasoning);
  }

  @override
  Future<List<Map<String, dynamic>>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) async => const [];
}

class _FakeCallEventSink implements LlmCallEventSink {
  final events = <LlmCallEvent>[];

  @override
  void recordCallEvent(LlmCallEvent event) {
    events.add(event);
  }
}

const _agent = StudioAgent(id: 'final', name: 'Final');
const _resolved = ResolvedAgentConfig(
  endpoint: 'https://example.com',
  apiKey: 'key',
  model: 'model',
  protocol: 'openai',
  stream: false,
);

const _streamingResolved = ResolvedAgentConfig(
  endpoint: 'https://example.com',
  apiKey: 'key',
  model: 'model',
  protocol: 'custom_chat_completion',
  stream: true,
);

_FakeCallEventSink _captureEvents() {
  final sink = _FakeCallEventSink();
  final previousSink = LlmCallEventCapture.sink;
  LlmCallEventCapture.sink = sink;
  addTearDown(() => LlmCallEventCapture.sink = previousSink);
  return sink;
}

void main() {
  for (final partialText in ['', 'partial reply']) {
    test('silent transport cancellation settles with "$partialText"', () async {
      final sink = _captureEvents();
      final transport = _FakeTransport(
        waitForCancellation: true,
        chunks: [if (partialText.isNotEmpty) (partialText, null)],
      );
      final token = CancelToken();
      final updates = <String>[];
      final run = AgentStreamRunner((_) => transport).run(
        agent: _agent,
        messages: const [],
        resolved: _streamingResolved,
        sessionId: 'session',
        isFinalResponse: true,
        cancelToken: token,
        timeoutMs: 10000,
        onFinalResponseUpdate: (text, _) => updates.add(text),
      );
      // Bound the assertion independently of the runner's timeout: a transport
      // may return on cancellation without invoking any terminal callback.
      final settled = expectLater(
        run.timeout(const Duration(seconds: 1)),
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      await transport.ready.future;
      token.cancel('user stopped');
      await settled;
      await transport.returnedAfterCancellation.future;

      expect(transport.cancelled, isTrue);
      expect(updates, partialText.isEmpty ? isEmpty : [partialText]);
      expect(sink.events, hasLength(1));
      expect(sink.events.single.status, 'cancelled');
      expect(sink.events.single.payload['completionReason'], 'cancelled');
      expect(sink.events.single.responseText, partialText);
      expect(
        sink.events.single.payload['chunkCount'],
        partialText.isEmpty ? 0 : 1,
      );
    });
  }

  for (final isFinalResponse in [true, false]) {
    test(
      'late callbacks after cancellation are ignored (final=$isFinalResponse)',
      () async {
        final sink = _captureEvents();
        final transport = _FakeTransport(
          waitForCancellation: true,
          chunks: const [('partial', null)],
        );
        final token = CancelToken();
        final updates = <String>[];
        final run = AgentStreamRunner((_) => transport).run(
          agent: _agent,
          messages: const [],
          resolved: _streamingResolved,
          sessionId: 'session',
          isFinalResponse: isFinalResponse,
          cancelToken: token,
          timeoutMs: 10000,
          onFinalResponseUpdate: (text, _) => updates.add(text),
          onIntermediateUpdate: updates.add,
        );
        final settled = expectLater(
          run.timeout(const Duration(seconds: 1)),
          throwsA(isA<DioException>()),
        );
        await transport.ready.future;
        token.cancel();
        await settled;
        await transport.returnedAfterCancellation.future;
        transport.savedOnUpdate!(' late', 'late reasoning');
        transport.savedOnComplete!('late replacement', 'late reasoning');
        transport.savedOnError!(StateError('late error'));
        await Future<void>.delayed(Duration.zero);

        expect(updates, ['partial']);
        expect(sink.events, hasLength(1));
        expect(sink.events.single.payload['completionReason'], 'cancelled');
        expect(sink.events.single.responseText, 'partial');
        expect(sink.events.single.payload['chunkCount'], 1);
        expect(sink.events.single.payload['chunkTrace'], hasLength(1));
      },
    );
  }

  test(
    'parent token groups pipeline identity across runner instances',
    () async {
      final sink = _captureEvents();
      final sharedToken = CancelToken();
      final transports = <_FakeTransport>[];
      for (final token in [sharedToken, sharedToken, CancelToken()]) {
        final transport = _FakeTransport();
        transports.add(transport);
        await AgentStreamRunner((_) => transport).run(
          agent: _agent,
          messages: const [],
          resolved: _resolved,
          sessionId: 'session',
          isFinalResponse: true,
          cancelToken: token,
          timeoutMs: 1000,
        );
      }
      final contexts = transports
          .map((t) => t.request!.captureContext!)
          .toList();
      expect(contexts.first.pipelineRunId, isNotEmpty);
      expect(contexts[1].pipelineRunId, contexts[0].pipelineRunId);
      expect(contexts[2].pipelineRunId, isNot(contexts[0].pipelineRunId));
      expect(contexts.map((context) => context.callId).toSet(), hasLength(3));
      expect(
        contexts.every((context) => context.callId?.isNotEmpty == true),
        isTrue,
      );
      expect(sink.events, hasLength(3));
    },
  );

  test(
    'chunk trace tracks content and reasoning offsets through empty deltas',
    () async {
      final sink = _captureEvents();
      final transport = _FakeTransport(
        chunks: const [('', 'why'), ('Hi', null), ('', null), (' there', '!')],
        chunkDelay: const Duration(milliseconds: 5),
      );
      await AgentStreamRunner((_) => transport).run(
        agent: _agent,
        messages: const [],
        resolved: _streamingResolved,
        sessionId: 'session',
        isFinalResponse: true,
        cancelToken: CancelToken(),
        timeoutMs: 1000,
      );
      final payload = sink.events.single.payload;
      final trace = (payload['chunkTrace'] as List).cast<Map<String, int>>();
      expect(payload['chunkCount'], 3);
      expect(payload['chunkTraceTruncated'], isFalse);
      expect(
        trace
            .map(
              (chunk) => [
                chunk['contentOffset'],
                chunk['contentLength'],
                chunk['reasoningOffset'],
                chunk['reasoningLength'],
              ],
            )
            .toList(),
        [
          [0, 0, 0, 3],
          [0, 2, 3, 0],
          [2, 6, 3, 1],
        ],
      );
      final elapsed = trace.map((chunk) => chunk['elapsedMs']!).toList();
      expect(elapsed.first, greaterThanOrEqualTo(0));
      expect(elapsed, orderedEquals([...elapsed]..sort()));
      expect(payload['firstChunkMs'], elapsed.first);
      final gaps = [elapsed[1] - elapsed[0], elapsed[2] - elapsed[1]];
      final maxGap = gaps.reduce((a, b) => a > b ? a : b);
      expect(maxGap, greaterThan(0));
      expect(payload['maxChunkGapMs'], maxGap);
      final gapIndex = gaps.indexOf(maxGap) + 1;
      expect(payload['longestGap'], {
        'gapMs': maxGap,
        'contentOffset': trace[gapIndex]['contentOffset'],
        'reasoningOffset': trace[gapIndex]['reasoningOffset'],
        'chunk': gapIndex + 1,
      });
    },
  );

  test('pure request builder matches the request sent by run', () async {
    final transport = _FakeTransport(delay: Duration.zero);
    final runner = AgentStreamRunner((_) => transport);
    const agent = StudioAgent(id: 'agent', controllerId: 'agency');
    const resolved = ResolvedAgentConfig(
      endpoint: 'https://example.test',
      apiKey: 'key',
      model: 'model',
      protocol: 'openai',
      stream: false,
    );
    const messages = [
      {'role': 'user', 'content': 'hello'},
    ];
    final expected = AgentStreamRunner.buildRequest(
      agent: agent,
      messages: messages,
      resolved: resolved,
      sessionId: 'session',
      isFinalResponse: false,
      maxTokensOverride: 321,
      temperatureOverride: 0.4,
    );

    await runner.run(
      agent: agent,
      messages: messages,
      resolved: resolved,
      sessionId: 'session',
      isFinalResponse: false,
      cancelToken: CancelToken(),
      timeoutMs: 1000,
      maxTokensOverride: 321,
      temperatureOverride: 0.4,
    );

    expect(transport.request?.messages, expected.messages);
    expect(transport.request?.maxTokens, expected.maxTokens);
    expect(transport.request?.temperature, expected.temperature);
    expect(
      transport.request?.captureContext?.toJson(),
      expected.captureContext?.toJson(),
    );
  });

  test(
    'non-streaming response can complete within configured timeout',
    () async {
      final transport = _FakeTransport(delay: const Duration(milliseconds: 30));
      final runner = AgentStreamRunner((_) => transport);

      final result = await runner.run(
        agent: _agent,
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        resolved: _resolved,
        sessionId: 'session',
        isFinalResponse: true,
        cancelToken: CancelToken(),
        timeoutMs: 100,
        charName: 'Character',
        userName: 'User',
      );

      expect(result.text, 'complete response');
      expect(transport.request?.receiveTimeoutMs, 0);
      expect(transport.request?.charName, 'Character');
      expect(transport.request?.userName, 'User');
      expect(transport.request?.captureContext?.stage, 'studio.final');
      expect(transport.request?.captureContext?.sessionId, 'session');
      expect(transport.request?.captureContext?.agentId, 'final');
    },
  );

  test('final request preserves configured inline reasoning tags', () {
    const messages = [
      {
        'role': 'system',
        'content': 'Use <think>reasoning</think> before the response.',
      },
    ];

    final request = AgentStreamRunner.buildRequest(
      agent: _agent,
      messages: messages,
      resolved: const ResolvedAgentConfig(
        endpoint: 'https://example.com',
        apiKey: 'key',
        model: 'model',
        protocol: 'custom_chat_completion',
        requestReasoning: false,
        omitReasoning: true,
        reasoningTagStart: '<think>',
        reasoningTagEnd: '</think>',
      ),
      sessionId: 'session',
      isFinalResponse: true,
    );

    expect(request.messages, messages);
    expect(request.messages.single['content'], contains('<think>'));
    expect(
      request.messages.single['content'],
      isNot(contains('hidden reasoning')),
    );
  });

  test(
    'final request still neutralizes think tags without a configured pair',
    () {
      final request = AgentStreamRunner.buildRequest(
        agent: _agent,
        messages: const [
          {
            'role': 'system',
            'content': 'Use <think>reasoning</think> before the response.',
          },
        ],
        resolved: _resolved,
        sessionId: 'session',
        isFinalResponse: true,
      );

      expect(request.messages.single['content'], contains('hidden reasoning'));
      expect(request.messages.single['content'], isNot(contains('<think>')));
    },
  );

  test(
    'non-streaming inline reasoning tags are split out of the reply',
    () async {
      final transport = _FakeTransport(
        delay: Duration.zero,
        completedText: '<audit>step analysis</audit>actual reply',
        completedReasoning: null,
      );
      final runner = AgentStreamRunner((_) => transport);

      final result = await runner.run(
        agent: _agent,
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        resolved: const ResolvedAgentConfig(
          endpoint: 'https://example.com',
          apiKey: 'key',
          model: 'model',
          protocol: 'custom_chat_completion',
          stream: false,
          reasoningTagStart: '<audit>',
          reasoningTagEnd: '</audit>',
        ),
        sessionId: 'session',
        isFinalResponse: true,
        cancelToken: CancelToken(),
        timeoutMs: 100,
        tagStart: '<audit>',
        tagEnd: '</audit>',
      );

      expect(result.text, 'actual reply');
      expect(result.reasoning, 'step analysis');
    },
  );

  test(
    'Think tracker streams and retains native and visible thinking',
    () async {
      final transport = _FakeTransport(
        delay: Duration.zero,
        completedText: '<thinking>audit complete</thinking>',
        completedReasoning: 'native steps',
        chunks: [
          ('', 'native '),
          ('', 'steps'),
          ('<thinking>audit ', null),
          ('complete</thinking>', null),
        ],
      );
      final updates = <String>[];
      final result = await AgentStreamRunner((_) => transport).run(
        agent: const StudioAgent(
          id: 'think',
          controllerId: 'think',
          reasoningMode: 'think-replacement',
        ),
        messages: const [
          {'role': 'user', 'content': 'audit'},
        ],
        resolved: const ResolvedAgentConfig(
          endpoint: 'https://example.com',
          apiKey: 'key',
          model: 'model',
          protocol: 'custom_chat_completion',
          stream: true,
          reasoningTagStart: '<thinking>',
          reasoningTagEnd: '</thinking>',
        ),
        sessionId: 'session',
        isFinalResponse: false,
        cancelToken: CancelToken(),
        timeoutMs: 100,
        onIntermediateUpdate: updates.add,
      );

      expect(result.text, '<thinking>audit complete</thinking>');
      expect(result.reasoning, 'native steps');
      expect(updates.first, contains('native '));
      expect(updates.last, contains('<thinking>audit complete</thinking>'));
      expect(updates.last, contains('native steps'));
      expect(updates.where((update) => update == updates.last), hasLength(1));
    },
  );

  test('Think tracker returns a reasoning-only provider response', () async {
    final transport = _FakeTransport(
      delay: Duration.zero,
      completedText: '',
      completedReasoning: 'completed analysis',
      chunks: [('', 'completed '), ('', 'analysis')],
    );
    final updates = <String>[];
    final result = await AgentStreamRunner((_) => transport).run(
      agent: const StudioAgent(
        id: 'think',
        controllerId: 'think',
        reasoningMode: 'think-replacement',
      ),
      messages: const [
        {'role': 'user', 'content': 'audit'},
      ],
      resolved: const ResolvedAgentConfig(
        endpoint: 'https://example.com',
        apiKey: 'key',
        model: 'model',
        protocol: 'custom_chat_completion',
        stream: true,
      ),
      sessionId: 'session',
      isFinalResponse: false,
      cancelToken: CancelToken(),
      timeoutMs: 100,
      onIntermediateUpdate: updates.add,
    );

    expect(result.text, isEmpty);
    expect(result.reasoning, 'completed analysis');
    expect(updates.last, contains('completed analysis'));
  });

  test('timeout cancels the in-flight transport request', () async {
    final transport = _FakeTransport(waitForCancellation: true);
    final runner = AgentStreamRunner((_) => transport);

    await expectLater(
      runner.run(
        agent: _agent,
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        resolved: _resolved,
        sessionId: 'session',
        isFinalResponse: true,
        cancelToken: CancelToken(),
        timeoutMs: 20,
      ),
      throwsA(isA<TimeoutException>()),
    );
    await Future<void>.delayed(Duration.zero);

    expect(transport.cancelled, isTrue);
  });

  test(
    'records transport outcome and stream chunk telemetry when capture sink is active',
    () async {
      final sink = _FakeCallEventSink();
      final previousSink = LlmCallEventCapture.sink;
      LlmCallEventCapture.sink = sink;
      addTearDown(() {
        LlmCallEventCapture.sink = previousSink;
      });

      final transport = _FakeTransport(
        delay: Duration.zero,
        completedText: 'first chunk second chunk',
        chunks: const [('first chunk ', null), ('second chunk', null)],
      );
      final runner = AgentStreamRunner((_) => transport);

      final result = await runner.run(
        agent: _agent,
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        resolved: const ResolvedAgentConfig(
          endpoint: 'https://example.com',
          apiKey: 'key',
          model: 'model',
          protocol: 'custom_chat_completion',
          stream: true,
        ),
        sessionId: 'session',
        isFinalResponse: true,
        cancelToken: CancelToken(),
        timeoutMs: 100,
      );

      expect(result.text, 'first chunk second chunk');
      expect(transport.request?.captureContext?.pipelineRunId, isNotEmpty);
      expect(transport.request?.captureContext?.callId, isNotEmpty);
      expect(transport.request?.captureContext?.attempt, 1);
      expect(sink.events, hasLength(1));
      expect(sink.events.single.kind, 'transport_succeeded');
      expect(sink.events.single.status, 'ok');
      expect(sink.events.single.responseText, 'first chunk second chunk');
      expect(sink.events.single.payload['chunkCount'], 2);
      expect(sink.events.single.payload['completionReason'], 'complete');
      expect(sink.events.single.payload['maxChunkGapMs'], isA<int>());
    },
  );
}
