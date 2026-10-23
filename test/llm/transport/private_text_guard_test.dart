import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_transport.dart';

import '_private_text_fixture.dart';

void main() {
  final protocols = [
    (
      LlmProtocol.openai,
      'https://fixture.invalid/v1/chat/completions',
      'fixture-model',
      chatDelta,
    ),
    (
      LlmProtocol.openaiResponses,
      'https://fixture.invalid/v1/responses',
      'fixture-model',
      (String text) =>
          frame({'type': 'response.output_text.delta', 'delta': text}),
    ),
    (
      LlmProtocol.anthropic,
      'https://fixture.invalid/v1/messages',
      'fixture-model',
      (String text) => anthropicStart() + anthropicText(text),
    ),
    (
      LlmProtocol.gemini,
      'https://fixture.invalid/v1beta/models/fixture-model:streamGenerateContent',
      'fixture-model',
      (String text) => geminiText(text),
    ),
  ];
  for (final protocol in protocols) {
    test('partial EOF is never complete: ${protocol.$1}', () async {
      final fixture = PrivateFixture([
        PrivateFixtureAdapter(protocol.$4('partial'), oneByteChunks: true),
      ]);
      final result = await fixture.run(
        protocol: protocol.$1,
        request: privateRequest(endpoint: protocol.$2, model: protocol.$3),
      );
      expect(result.status, PrivateTextStatus.partial);
      expect(result.text, 'partial');
      expect(result.reason, PrivateTextReason.unexpectedEof);
    });
    for (final suffix in [
      'event: error\ndata: {"message":"RAW_PROVIDER_CANARY fixture-credential"}\n\n',
      'data: {"error":{"message":"RAW_PROVIDER_CANARY fixture-credential"}}\n\n',
      'data: {broken JSON RAW_PROVIDER_CANARY}\n\n',
      'data: {"unterminated":',
    ]) {
      test('guarded error/malformed suffix ${protocol.$1}: $suffix', () async {
        final fixture = PrivateFixture([
          PrivateFixtureAdapter(protocol.$4('safe partial') + suffix),
        ]);
        final result = await fixture.run(
          protocol: protocol.$1,
          request: privateRequest(endpoint: protocol.$2, model: protocol.$3),
        );
        expect(result.status, PrivateTextStatus.partial);
        expect(result.text, 'safe partial');
        expect(
          result.reason,
          suffix.contains('error')
              ? PrivateTextReason.providerError
              : PrivateTextReason.malformed,
        );
        expect(result.toString(), isNot(contains('RAW_PROVIDER_CANARY')));
      });
    }
    test(
      'output bound is explicit, not silently complete: ${protocol.$1}',
      () async {
        final fixture = PrivateFixture([
          PrivateFixtureAdapter(protocol.$4('x' * 65537)),
        ]);
        final result = await fixture.run(
          protocol: protocol.$1,
          request: privateRequest(endpoint: protocol.$2, model: protocol.$3),
        );
        expect(result.status, PrivateTextStatus.limited);
        expect(result.reason, PrivateTextReason.outputLimit);
        expect(result.text, isEmpty);
      },
    );
  }

  test('frame-aligned multiline data and CRLF preserve split UTF8', () async {
    final wire =
        'data: {"choices":\r\ndata: [{"index":0,"delta":{"content":"雪🐈"},"finish_reason":null}]}\r\n\r\n${chatFinish()}data: [DONE]\n\n';
    final result = await PrivateFixture([
      PrivateFixtureAdapter(wire, oneByteChunks: true),
    ]).run();
    expect(result.status, PrivateTextStatus.complete);
    expect(result.text, '雪🐈');
  });
  test('valid finish-reason EOF may omit final LF', () async {
    final result = await PrivateFixture([
      PrivateFixtureAdapter(chatDelta('full') + chatFinish().trimRight()),
    ]).run();
    expect(result.status, PrivateTextStatus.complete);
    expect(result.text, 'full');
  });
  test('[DONE] without a finish reason is not a final answer', () async {
    final result = await PrivateFixture([
      PrivateFixtureAdapter('${chatDelta('partial')}data: [DONE]\n\n'),
    ]).run();
    expect(result.status, PrivateTextStatus.partial);
    expect(result.reason, PrivateTextReason.malformed);
  });
  for (final reason in ['length', 'content_filter', 'tool_calls']) {
    test('chat finish classification: $reason', () async {
      final result = await PrivateFixture([
        PrivateFixtureAdapter(
          '${chatDelta('partial')}${chatFinish(reason)}data: [DONE]\n\n',
        ),
      ]).run();
      expect(
        result.status,
        reason == 'length'
            ? PrivateTextStatus.limited
            : PrivateTextStatus.partial,
      );
      expect(result.reason, switch (reason) {
        'length' => PrivateTextReason.providerLimit,
        'content_filter' => PrivateTextReason.providerError,
        _ => PrivateTextReason.unsupported,
      });
    });
  }
  test('Responses incomplete/failed and mismatched completed output', () async {
    for (final terminal in [
      {
        'type': 'response.failed',
        'response': {'error': 'RAW_PROVIDER_CANARY'},
      },
      {
        'type': 'response.incomplete',
        'response': {
          'incomplete_details': {'reason': 'max_output_tokens'},
        },
      },
      {
        'type': 'response.completed',
        'response': {
          'status': 'completed',
          'output': [
            {
              'type': 'message',
              'role': 'assistant',
              'content': [
                {'type': 'output_text', 'text': 'DIFFERENT'},
              ],
            },
          ],
        },
      },
    ]) {
      final body =
          frame({'type': 'response.output_text.delta', 'delta': 'partial'}) +
          frame(terminal);
      final result = await PrivateFixture([PrivateFixtureAdapter(body)]).run(
        protocol: LlmProtocol.openaiResponses,
        request: privateRequest(
          endpoint: 'https://fixture.invalid/v1/responses',
        ),
      );
      expect(
        result.status,
        terminal['type'] == 'response.incomplete'
            ? PrivateTextStatus.limited
            : PrivateTextStatus.partial,
      );
      expect(result.text, 'partial');
    }
  });
  test('Anthropic stop without stop reason is not completion', () async {
    final body =
        anthropicStart() +
        anthropicText('partial') +
        frame({'type': 'message_stop'});
    final result = await PrivateFixture([PrivateFixtureAdapter(body)]).run(
      protocol: LlmProtocol.anthropic,
      request: privateRequest(endpoint: 'https://fixture.invalid/v1/messages'),
    );
    expect(result.status, PrivateTextStatus.partial);
    expect(result.reason, PrivateTextReason.malformed);
  });
  for (final reason in ['MAX_TOKENS', 'SAFETY', 'MALFORMED_FUNCTION_CALL']) {
    test('Gemini terminal classification: $reason', () async {
      final result =
          await PrivateFixture([
            PrivateFixtureAdapter(geminiText('partial', finish: reason)),
          ]).run(
            protocol: LlmProtocol.gemini,
            request: privateRequest(
              endpoint:
                  'https://fixture.invalid/v1beta/models/fixture-model:streamGenerateContent',
            ),
          );
      expect(
        result.status,
        reason == 'MAX_TOKENS'
            ? PrivateTextStatus.limited
            : PrivateTextStatus.partial,
      );
    });
  }
  test('malformed UTF8 and escaped lone surrogate fail closed', () async {
    for (final bytes in [
      [
        ...utf8.encode(chatDelta('partial')),
        ...utf8.encode('data: '),
        0xc3,
        0x28,
        10,
        10,
      ],
      [
        ...utf8.encode(chatDelta('partial')),
        ...utf8.encode(
          'data: {"choices":[{"delta":{"content":"\\ud800"},"finish_reason":null}]}\n\n',
        ),
      ],
      [...utf8.encode(chatDelta('partial')), 0xf0, 0x9f],
    ]) {
      final result = await PrivateFixture([
        PrivateFixtureAdapter('', rawBytes: bytes, oneByteChunks: true),
      ]).run();
      expect(result.status, PrivateTextStatus.partial);
      expect(result.reason, PrivateTextReason.malformed);
      expect(result.text, 'partial');
    }
  });
  test(
    'oversized frame and bounded metadata count are explicit limits',
    () async {
      for (final body in [
        'data: ${'x' * PrivateTextLimits.frameBytes}',
        ':keepalive\n\n' * (PrivateTextLimits.wireBytes ~/ 12 + 1),
      ]) {
        final result = await PrivateFixture([
          PrivateFixtureAdapter(body),
        ]).run();
        expect(result.status, PrivateTextStatus.limited);
        expect(result.reason, PrivateTextReason.wireLimit);
      }
    },
  );
}
