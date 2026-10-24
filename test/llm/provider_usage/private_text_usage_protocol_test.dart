import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_transport.dart';

import '_provider_usage_fixture.dart';

void main() {
  for (final route in usageRoutes) {
    final protocol = route.decoderProtocol;
    final label = '${route.protocol} responses=${route.responses}';
    test('$label complete numeric usage survives split UTF8', () async {
      final reported = usageFields(
        protocol,
        input: 100,
        output: 8,
        total: 111, // Preserve reported total, not a pretend input+output sum.
        cached: 60,
        creation: 20,
        reasoning: 3,
      );
      final result = await route.run(
        usageComplete(protocol, 'Привет 雪', usage: reported),
        split: true,
      );
      expect(result.status, PrivateTextStatus.complete);
      expect(result.reason, PrivateTextReason.none);
      expect(result.dispatch, PrivateTextDispatch.admitted);
      expect(result.text, 'Привет 雪');
      expect(usageNumbers(result.usage), [
        100,
        8,
        protocol == LlmProtocol.anthropic ? null : 111,
        60,
        protocol == LlmProtocol.anthropic ? 20 : null,
        protocol == LlmProtocol.anthropic ? null : 3,
      ]);
    });
    test('$label absent metadata remains unknown', () async {
      final result = await route.run(usageComplete(protocol, 'safe'));
      expect(result.status, PrivateTextStatus.complete);
      expect(result.usage, isNull);
    });
    test('$label returned zero is known, not absent', () async {
      final result = await route.run(
        usageComplete(protocol, 'safe', usage: usageFields(protocol, input: 0)),
      );
      expect(result.status, PrivateTextStatus.complete);
      expect(usageNumbers(result.usage), [0, null, null, null, null, null]);
    });
    test(
      '$label output-only report is not context input or inferred total',
      () async {
        final result = await route.run(
          usageComplete(
            protocol,
            'safe',
            usage: usageFields(protocol, output: 8),
          ),
        );
        expect(result.status, PrivateTextStatus.complete);
        expect(usageNumbers(result.usage), [null, 8, null, null, null, null]);
      },
    );
    test('$label accepted partial evidence does not prove terminal', () async {
      final result = await route.run(
        usagePartial(
          protocol,
          'partial',
          usage: usageFields(protocol, input: 100),
        ),
      );
      expect(result.status, PrivateTextStatus.partial);
      expect(result.reason, PrivateTextReason.unexpectedEof);
      expect(result.text, 'partial');
      expect(
        result.usage?.inputTokens,
        protocol == LlmProtocol.openaiResponses ? isNull : 100,
      );
    });
    test('$label JSON-looking prose never supplies a usage counter', () async {
      final text = jsonEncode(usageFields(protocol, input: 999));
      final sanitizedText = SecretRedactor().redactText(text);
      final result = await route.run(usageComplete(protocol, text));
      expect(result.status, PrivateTextStatus.complete);
      expect(result.text, sanitizedText);
      expect(result.usage, isNull);
    });
  }

  test(
    'Chat usage-only repeated cumulative frames preserve last valid fields',
    () async {
      final route = usageRoutes.first;
      String snapshot(Map<String, dynamic> usage) =>
          frame({'choices': <Object?>[], 'usage': usage});
      final body =
          '${frame(usageChatEvent('safe', usage: {'prompt_tokens': 100}))}'
          '${snapshot({'completion_tokens': 2})}'
          '${snapshot({'completion_tokens': 8, 'total_tokens': 111})}'
          '${snapshot({'completion_tokens': 8, 'total_tokens': 111})}'
          '${snapshot({'completion_tokens': 7, 'prompt_tokens': '900'})}'
          '${chatFinish()}'
          'data: [DONE]\n\n';
      final result = await route.run(body);
      expect(result.status, PrivateTextStatus.complete);
      expect(usageNumbers(result.usage), [100, 7, 111, null, null, null]);
    },
  );

  test(
    'Anthropic start and final delta are cumulative, not additive',
    () async {
      final body =
          frame(
            usageAnthropicStart(
              usage: {
                'input_tokens': 100,
                'output_tokens': 2,
                'cache_read_input_tokens': 60,
                'cache_creation_input_tokens': 20,
              },
            ),
          ) +
          anthropicText('safe') +
          frame({
            'type': 'message_delta',
            'delta': {'stop_reason': 'end_turn'},
            'usage': {'output_tokens': 8},
          }) +
          frame({'type': 'message_stop'});
      final result = await usageRoutes[5].run(body);
      expect(result.status, PrivateTextStatus.complete);
      expect(usageNumbers(result.usage), [100, 8, null, 60, 20, null]);
    },
  );

  test(
    'Gemini cumulative no-text snapshots are captured outside text chunks',
    () async {
      String snapshot(
        String text,
        Map<String, dynamic> usage, {
        String? finish,
      }) => frame(usageGeminiEvent(text, usage: usage, finish: finish));
      final body =
          snapshot('safe', {
            'promptTokenCount': 100,
            'candidatesTokenCount': 2,
          }) +
          snapshot('', {
            'candidatesTokenCount': 8,
            'cachedContentTokenCount': 60,
          }) +
          snapshot('', {'candidatesTokenCount': 8, 'thoughtsTokenCount': 3}) +
          snapshot('', {'totalTokenCount': 111}, finish: 'STOP');
      final result = await usageRoutes.last.run(body);
      expect(result.status, PrivateTextStatus.complete);
      expect(result.text, 'safe');
      expect(usageNumbers(result.usage), [100, 8, 111, 60, null, 3]);
    },
  );

  test(
    'usage support does not add unsupported stream options to private wire',
    () async {
      final adapter = PrivateFixtureAdapter(chatComplete('safe'));
      final result = await PrivateFixture([adapter]).run();
      expect(result.status, PrivateTextStatus.complete);
      final wire = jsonDecode(adapter.upload!) as Map;
      expect(wire.containsKey('stream_options'), isFalse);
      expect(wire.containsKey('include_usage'), isFalse);
    },
  );

  test(
    'reusing transport does not accumulate counters across requests',
    () async {
      final fixture = PrivateFixture([
        PrivateFixtureAdapter(
          usageComplete(
            LlmProtocol.openai,
            'first',
            usage: {'prompt_tokens': 100, 'completion_tokens': 8},
          ),
        ),
        PrivateFixtureAdapter(
          usageComplete(
            LlmProtocol.openai,
            'second',
            usage: {'completion_tokens': 2},
          ),
        ),
      ]);
      final first = await fixture.run();
      final second = await fixture.run();
      expect(first.usage?.inputTokens, 100);
      expect(usageNumbers(second.usage), [null, 2, null, null, null, null]);
      expect(fixture.created, hasLength(2));
    },
  );
}
