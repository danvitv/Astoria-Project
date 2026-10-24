import 'package:flutter_test/flutter_test.dart';

import 'native_tool_fixture.dart';

void main() {
  for (final protocol in nativeTransportProtocols) {
    for (final shape in [
      'unknown',
      'array',
      'invalid-id',
      'duplicate',
      'too-many',
    ]) {
      test('$protocol refuses $shape before application execution', () async {
        final h = ToolHarness(protocol);
        await h.store();
        final response = h.response(
          name: shape == 'unknown' ? 'not_declared' : 'set_theme',
          id: shape == 'invalid-id' ? '../invalid' : 'call_1',
          arguments: shape == 'array' ? [] : const {'value': 'dark'},
        );
        if (shape == 'duplicate' || shape == 'too-many') {
          final count = shape == 'duplicate'
              ? 2
              : NativeToolLimits.callsPerTurn + 1;
          if (protocol == 'openai_responses') {
            final original = (response['output'] as List).single as Map;
            response['output'] = List.generate(
              count,
              (i) => {
                ...original,
                'id': 'fc_$i',
                'call_id': shape == 'duplicate' ? 'call_1' : 'call_$i',
              },
            );
          } else if (protocol == 'anthropic') {
            final original = (response['content'] as List).last as Map;
            response['content'] = List.generate(
              count,
              (i) => {
                ...original,
                'id': shape == 'duplicate' ? 'call_1' : 'call_$i',
              },
            );
          } else if (protocol == 'gemini') {
            final content =
                (response['candidates'] as List)[0]['content'] as Map;
            final original = (content['parts'] as List).single as Map;
            content['parts'] = List.generate(
              count,
              (i) => {
                ...original,
                'functionCall': {
                  ...(original['functionCall'] as Map),
                  'id': shape == 'duplicate' ? 'call_1' : 'call_$i',
                },
              },
            );
          } else {
            final message = (response['choices'] as List)[0]['message'] as Map;
            final original = (message['tool_calls'] as List).single as Map;
            message['tool_calls'] = List.generate(
              count,
              (i) => {
                ...original,
                'id': shape == 'duplicate' ? 'call_1' : 'call_$i',
              },
            );
          }
        }
        h.reply(response);
        final result = await h.session().start();
        expect(result.status, NativeToolStatus.error);
        expect(result.calls, isEmpty);
        expect(result.dispatch, NativeToolDispatch.admittedFailed);
        expect(h.native.wires, hasLength(1));
        expect(result.toString(), isNot(contains(nativeCanary)));
      });
    }
    test('$protocol tool-like prose is never parsed as a call', () async {
      final h = ToolHarness(protocol);
      await h.store();
      const prose =
          '{"id":"call_1","name":"set_theme","arguments":{"value":"dark"}}';
      h.reply(h.response(tool: false, prose: prose));
      final result = await h.session().start();
      expect(result.status, NativeToolStatus.complete);
      expect(result.text, prose);
      expect(result.calls, isEmpty);
    });
    test(
      '$protocol unknown and absent provider usage counters stay unknown',
      () async {
        final h = ToolHarness(protocol);
        await h.store();
        final response = h.response(tool: false);
        final key = protocol == 'gemini' ? 'usageMetadata' : 'usage';
        response[key] = {
          'input_tokens': -1,
          'output_tokens': '5',
          'total_tokens': 1.5,
          'promptTokenCount': -1,
          'candidatesTokenCount': '5',
          'totalTokenCount': 1.5,
        };
        h.reply(response);
        final result = await h.session().start();
        expect(result.status, NativeToolStatus.complete);
        expect(result.actualUsage, isNull);
      },
    );
    test(
      '$protocol native saved-key echo never reaches application arguments',
      () async {
        final h = ToolHarness(protocol);
        await h.store();
        h.reply(h.response(arguments: {'value': nativeCanary}));
        final result = await h.session().start();
        expect(result.reason, NativeToolReason.denied);
        expect(result.calls, isEmpty);
        expect(result.text, isEmpty);
        expect(result.toString(), isNot(contains(nativeCanary)));
      },
    );
  }

  for (final protocol in [
    'openai',
    'openai_responses',
    'openrouter',
    'custom_chat_completion',
  ]) {
    test(
      '$protocol malformed JSON arguments and native non-function type refuse',
      () async {
        final h = ToolHarness(protocol);
        await h.store();
        h.reply(h.response(arguments: '{not-json'));
        expect((await h.session().start()).status, NativeToolStatus.error);
        final h2 = ToolHarness(protocol);
        await h2.store();
        final response = h2.response();
        if (protocol == 'openai_responses') {
          (response['output'] as List)[0]['type'] = 'computer_call';
        } else {
          (response['choices'] as List)[0]['message']['tool_calls'][0]['type'] =
              'custom';
        }
        h2.reply(response);
        final rejected = await h2.session().start();
        expect(rejected.reason, NativeToolReason.unsupported);
        expect(rejected.calls, isEmpty);
      },
    );
  }

  test('tool data is deeply immutable, bounded and not arbitrary toJson', () {
    final arguments = <String, Object?>{
      'nested': [
        <String, Object?>{'value': 'dark'},
      ],
    };
    final call = NativeToolCall(
      id: 'c',
      name: 'set_theme',
      arguments: arguments,
    );
    (arguments['nested'] as List).clear();
    expect((call.arguments['nested'] as List).single, {'value': 'dark'});
    expect(() => call.arguments['x'] = 1, throwsUnsupportedError);
    expect(
      () => (call.arguments['nested'] as List).clear(),
      throwsUnsupportedError,
    );
    expect(
      () => NativeToolResult(
        callId: 'c',
        name: 'set_theme',
        content: {'x': Object()},
      ),
      throwsA(isA<NativeToolException>()),
    );
    final cyclic = <String, Object?>{};
    cyclic['cycle'] = cyclic;
    expect(
      () => NativeToolCall(id: 'c', name: 'set_theme', arguments: cyclic),
      throwsA(isA<NativeToolException>()),
    );
    expect(
      () => NativeToolResult(
        callId: 'c',
        name: 'set_theme',
        content: {'apiKey': 'hidden'},
      ),
      throwsA(isA<NativeToolException>()),
    );
  });
}
