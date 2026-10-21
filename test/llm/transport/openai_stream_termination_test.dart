import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/chat_stream_exception.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/openai_chat_transport.dart';

import '_sse_adapter.dart';

const _request = ChatTransportRequest(
  endpoint: 'https://example.com/v1/chat/completions',
  apiKey: 'test',
  model: 'test',
  messages: [],
  maxTokens: 100,
  temperature: 1,
  topP: 1,
);
const _partial =
    'data: {"choices":[{"delta":{"content":"Hello",'
    '"reasoning_content":"Thinking"}}]}\n\n';

class _Result {
  final updates = <String>[];
  final errors = <Object>[];
  final completions = <String>[];
  String? raw;
}

Future<_Result> _run(String body, {CancelToken? cancelToken}) async {
  final result = _Result();
  final dio = Dio()
    ..httpClientAdapter = SseAdapter(body, chunkSizes: [7, 19, 3]);
  await OpenAiChatTransport(dio: dio).stream(
    request: _request,
    cancelToken: cancelToken,
    onUpdate: (text, reasoning) {
      result.updates.add(text);
      cancelToken?.cancel();
    },
    onComplete: (text, reasoning, {rawResponseJson}) {
      result.completions.add(text);
      result.raw = rawResponseJson;
    },
    onError: result.errors.add,
  );
  dio.close();
  return result;
}

void main() {
  test('DONE completes once and ignores subsequent data', () async {
    final result = await _run('${_partial}data: [DONE]\n\ndata: invalid\n');
    expect(result.completions, ['Hello']);
    expect(result.errors, isEmpty);
    expect(result.updates, ['Hello']);
  });

  for (final reason in ['stop', 'length', 'content_filter', 'tool_calls']) {
    test('finish_reason $reason permits EOF and survives usage event', () async {
      final result = await _run(
        '${_partial}data: {"choices":[{"delta":{},"finish_reason":"$reason"}]}\n\n'
        'data: {"choices":[],"usage":{"completion_tokens":1}}\n\n',
      );
      expect(result.completions, ['Hello']);
      expect(result.errors, isEmpty);
      final raw = jsonDecode(result.raw!) as Map<String, dynamic>;
      expect(raw['choices'][0]['finish_reason'], reason);
      expect(raw['usage']['completion_tokens'], 1);
    });
  }

  test('finish_reason is parsed without a final newline', () async {
    final result = await _run(
      '${_partial}data: {"choices":[{"finish_reason":"stop"}]}',
    );
    expect(result.completions, ['Hello']);
    expect(result.errors, isEmpty);
  });

  final failures = <String, (String, String)>{
    'premature EOF': (_partial, 'unexpected_eof'),
    'empty EOF': ('', 'unexpected_eof'),
    'provider error': (
      '${_partial}data: {"error":{"message":"Provider overloaded"}}\n\n'
          'data: [DONE]\n\n',
      'provider_error',
    ),
    'named error event': (
      '${_partial}event: error\ndata: {"message":"Provider overloaded"}\n\n',
      'provider_error',
    ),
    'malformed JSON': ('${_partial}data: {broken}\n\n', 'malformed_event'),
    'malformed trailing JSON': ('${_partial}data: {broken', 'malformed_event'),
    'non-object JSON': ('${_partial}data: []\n\n', 'malformed_event'),
  };
  for (final entry in failures.entries) {
    test('${entry.key} fails once with partial output', () async {
      final result = await _run(entry.value.$1);
      expect(result.completions, isEmpty);
      expect(result.errors, hasLength(1));
      final error = result.errors.single as ChatStreamException;
      expect(error.reason, entry.value.$2);
      expect(error.partialText, entry.key == 'empty EOF' ? '' : 'Hello');
      expect(
        error.partialReasoning,
        entry.key == 'empty EOF' ? '' : 'Thinking',
      );
      expect(error.toString(), contains(error.message));
      if (error.reason == 'provider_error') {
        expect(error.message, 'Provider overloaded');
      }
    });
  }

  test('cancel after delta suppresses terminal callbacks', () async {
    final result = await _run(
      '${_partial}data: [DONE]\n\n',
      cancelToken: CancelToken(),
    );
    expect(result.updates, ['Hello']);
    expect(result.completions, isEmpty);
    expect(result.errors, isEmpty);
  });
}
