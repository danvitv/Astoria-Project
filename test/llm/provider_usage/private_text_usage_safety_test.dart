import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/llm/transport/llm_request_capture.dart';
import 'package:glaze_flutter/core/llm/transport/llm_request_dump.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_transport.dart';

import '_provider_usage_fixture.dart';

const _canary = 'RAW_USAGE_CANARY fixture-credential';

final class _UsageCaptureSink implements LlmRequestCaptureSink {
  final events = <LlmRequestCaptureEvent>[];
  @override
  void record(LlmRequestCaptureEvent event) => events.add(event);
}

Map<String, dynamic> _rejectedToolEvent(String protocol, Object usage) =>
    switch (protocol) {
      LlmProtocol.openaiResponses => {
        ...usageResponsesTerminal('safe', usage: usage),
        'response': {
          'status': 'completed',
          'usage': usage,
          'output': [
            {'type': 'function_call', 'arguments': _canary},
          ],
        },
      },
      LlmProtocol.anthropic => {
        'type': 'content_block_start',
        'index': 1,
        'content_block': {'type': 'tool_use', 'input': _canary},
        'usage': usage,
      },
      LlmProtocol.gemini => {
        'candidates': [
          {
            'content': {
              'parts': [
                {
                  'functionCall': {'args': _canary},
                },
              ],
            },
          },
        ],
        'usageMetadata': usage,
      },
      _ => {
        'choices': [
          {
            'delta': {
              'tool_calls': [_canary],
            },
          },
        ],
        'usage': usage,
      },
    };

void main() {
  for (final route in usageRoutes) {
    final protocol = route.decoderProtocol;
    final label = '${route.protocol} responses=${route.responses}';
    test(
      '$label malformed numeric fields remain unknown and fixed-safe',
      () async {
        final previousPrint = debugPrint;
        final previousSink = LlmRequestCapture.sink;
        final previousDump = LlmRequestDump.enabled;
        final logs = <String?>[];
        final sink = _UsageCaptureSink();
        debugPrint = (message, {wrapWidth}) => logs.add(message);
        LlmRequestCapture.sink = sink;
        LlmRequestDump.enabled = false;
        addTearDown(() {
          debugPrint = previousPrint;
          LlmRequestCapture.sink = previousSink;
          LlmRequestDump.enabled = previousDump;
        });
        for (final bad in <Object>[
          -1,
          0x80000000,
          1.0,
          1.5,
          '100',
          _canary,
          true,
          [_canary],
          {'message': _canary},
        ]) {
          final reported = usageFields(
            protocol,
            input: bad,
            output: 8,
            total: bad,
            cached: bad,
            creation: bad,
            reasoning: bad,
          );
          final result = await route.run(
            usageComplete(protocol, 'safe', usage: reported),
          );
          expect(result.status, PrivateTextStatus.complete);
          expect(result.reason, PrivateTextReason.none);
          expect(result.text, 'safe');
          expect(usageNumbers(result.usage), [null, 8, null, null, null, null]);
          expect(result.toString(), isNot(contains(_canary)));
          expect(result.usage.toString(), isNot(contains(_canary)));
        }
        expect(logs.join(), isNot(contains(_canary)));
        expect(logs.join(), isNot(contains('fixture-credential')));
        expect(sink.events, isEmpty);
      },
    );

    test(
      '$label wrong usage object shapes neither fail prose nor leak',
      () async {
        for (final usage in <Object>[
          _canary,
          [_canary],
          100,
          true,
          <String, dynamic>{},
        ]) {
          final result = await route.run(
            usageComplete(protocol, 'safe', usage: usage),
          );
          expect(result.status, PrivateTextStatus.complete);
          expect(result.text, 'safe');
          expect(result.usage, isNull);
          expect(result.toString(), isNot(contains(_canary)));
        }
      },
    );

    test('$label numeric metadata cannot admit tool traffic', () async {
      final body =
          usagePartial(
            protocol,
            'safe',
            usage: usageFields(protocol, input: 100),
          ) +
          frame(
            _rejectedToolEvent(protocol, usageFields(protocol, input: 999)),
          );
      final result = await route.run(body);
      expect(result.status, PrivateTextStatus.partial);
      expect(result.reason, PrivateTextReason.unsupported);
      expect(result.text, 'safe');
      expect(
        result.usage?.inputTokens,
        protocol == LlmProtocol.openaiResponses ? isNull : 100,
      );
      expect(result.toString(), isNot(contains(_canary)));
    });

    test(
      '$label output limit is unchanged even with numeric metadata',
      () async {
        final result = await route.run(
          usageComplete(
            protocol,
            'x' * (PrivateTextLimits.responseCharacters + 1),
            usage: usageFields(protocol, input: 100),
          ),
        );
        expect(result.status, PrivateTextStatus.limited);
        expect(result.reason, PrivateTextReason.outputLimit);
        expect(result.text, isEmpty);
        // Anthropic already accepted its message_start before text overflow.
        expect(
          result.usage?.inputTokens,
          protocol == LlmProtocol.anthropic ? 100 : isNull,
        );
      },
    );
  }

  test(
    'invalid Responses completed body cannot supply numeric authority',
    () async {
      final terminal = usageResponsesTerminal(
        'DIFFERENT',
        usage: {'input_tokens': 999},
      );
      final result = await usageRoutes[3].run(
        usagePartial(LlmProtocol.openaiResponses, 'safe') + frame(terminal),
      );
      expect(result.status, PrivateTextStatus.partial);
      expect(result.reason, PrivateTextReason.malformed);
      expect(result.text, 'safe');
      expect(result.usage, isNull);
    },
  );

  test(
    'provider-error terminal does not overwrite earlier numeric evidence',
    () async {
      final rejected = usageChatEvent('', usage: {'prompt_tokens': 999});
      (rejected['choices'] as List).first['finish_reason'] = 'content_filter';
      final result = await usageRoutes.first.run(
        usagePartial(
              LlmProtocol.openai,
              'safe',
              usage: {'prompt_tokens': 100},
            ) +
            frame(rejected),
      );
      expect(result.status, PrivateTextStatus.partial);
      expect(result.reason, PrivateTextReason.providerError);
      expect(result.usage?.inputTokens, 100);
    },
  );

  test('numeric-only Chat metadata does not fabricate completion', () async {
    final result = await usageRoutes.first.run(
      frame({
        'choices': <Object?>[],
        'usage': {'prompt_tokens': 100},
      }),
    );
    expect(result.status, PrivateTextStatus.error);
    expect(result.reason, PrivateTextReason.unexpectedEof);
    expect(result.text, isEmpty);
    expect(result.usage?.inputTokens, 100);
  });

  test('unknown event type still fails before usage capture', () async {
    final result = await usageRoutes[3].run(
      frame({
        'type': 'unknown_provider_type',
        'usage': {'input_tokens': 999},
        'raw': _canary,
      }),
    );
    expect(result.status, PrivateTextStatus.error);
    expect(result.reason, PrivateTextReason.unsupported);
    expect(result.usage, isNull);
  });

  test(
    'usage cannot bypass frame, whole-wire, nesting or object budgets',
    () async {
      final route = usageRoutes.first;
      Object nested = 'safe';
      for (var index = 0; index < 33; index++) {
        nested = {'nested': nested};
      }
      for (final usage in [
        {'raw': 'x' * PrivateTextLimits.frameBytes},
        {'raw': 'x' * PrivateTextLimits.wireBytes},
        {'raw': nested},
        {'raw': List.filled(8193, 0)},
      ]) {
        final result = await route.run(
          usageComplete(LlmProtocol.openai, 'safe', usage: usage),
        );
        expect(result.status, PrivateTextStatus.limited);
        expect(result.reason, PrivateTextReason.wireLimit);
        expect(result.text, isEmpty);
        expect(result.usage, isNull);
      }
    },
  );
}
