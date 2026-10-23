import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'native_provider_transport_fixture.dart';

String _frame(Map<String, dynamic> event) => 'data: ${jsonEncode(event)}\n\n';
Map<String, dynamic> _chat(String value, {bool reasoning = false}) => {
  'choices': [
    {
      'index': 0,
      'delta': {(reasoning ? 'reasoning_content' : 'content'): value},
    },
  ],
};
String _finish() =>
    '${_frame({
      'choices': [
        {'index': 0, 'delta': <String, dynamic>{}, 'finish_reason': 'stop'},
      ],
    })}'
    'data: [DONE]\n\n';

void main() {
  test(
    'Gemini thought-prefix/text-suffix same-frame echo is fenced before either lane',
    () async {
      final h = NativeTransportHarness('gemini');
      await h.store();
      h.response = nativeTransportSse(
        'gemini',
        text: '${nativeCanary.substring(12)} ',
        reasoning: nativeCanary.substring(0, 12),
      );
      await h.run();
      final joined = h.updates
          .map((piece) => '${piece.$1}${piece.$2 ?? ''}')
          .join();
      expect(joined, contains('[REDACTED]'));
      expect(joined, isNot(contains(nativeCanary.substring(0, 12))));
      expect(h.completions.single.$3, isNot(contains(nativeCanary)));
    },
  );
  for (final channel in ['text', 'reasoning', 'cross-lane']) {
    test(
      'unresolved active-key prefix is held BEFORE $channel callbacks',
      () async {
        final h = NativeTransportHarness('openai');
        await h.store();
        final prefix = nativeCanary.substring(0, 12);
        final tail = nativeCanary.substring(12);
        final entered = Completer<void>();
        final release = Completer<void>();
        Stream<Uint8List> chunks() async* {
          yield Uint8List.fromList(
            utf8.encode(
              _frame(_chat(prefix, reasoning: channel == 'reasoning')),
            ),
          );
          // Next pull means the FIRST frame has already traversed parser/gate.
          entered.complete();
          await release.future;
          yield Uint8List.fromList(
            utf8.encode(
              _frame(_chat('$tail after ', reasoning: channel != 'text')) +
                  _finish(),
            ),
          );
        }

        h.responseStream = chunks();
        final run = h.run(
          update: (text, reasoning) {
            expect(text, isNot(contains(nativeCanary)));
            expect(reasoning ?? '', isNot(contains(nativeCanary)));
            expect(text, isNot(contains(prefix)));
            expect(reasoning ?? '', isNot(contains(prefix)));
          },
        );
        await entered.future;
        expect(
          h.updates,
          isEmpty,
          reason: 'Unresolved prefix has not been published',
        );
        release.complete();
        await run;
        expect(h.errors, isEmpty);
        expect(h.completions, hasLength(1));
        final combined = h.updates
            .map((delta) => '${delta.$1}${delta.$2 ?? ''}')
            .join();
        expect(combined, isNot(contains(nativeCanary)));
        expect(combined, contains('[REDACTED]'));
        expect(h.completions.single.$3, isNot(contains(nativeCanary)));
      },
    );
  }

  for (final form in [
    Uri.encodeComponent(nativeCanary),
    base64Encode(utf8.encode(nativeCanary)),
  ]) {
    test(
      'fragmented encoded active credential is sanitized before publication',
      () async {
        final h = NativeTransportHarness('openai');
        await h.store();
        final split = form.length ~/ 2;
        h.response =
            _frame(_chat(form.substring(0, split))) +
            _frame(_chat('${form.substring(split)} ')) +
            _finish();
        await h.run();
        final joined = h.updates.map((delta) => delta.$1).join();
        expect(joined, '[REDACTED] ');
        expect(h.errors, isEmpty);
        expect(h.completions.single.$3, isNot(contains(form)));
      },
    );
  }

  for (final protocol in nativeTransportProtocols) {
    test(
      '$protocol text/reasoning echo never enters completion or canonical raw JSON',
      () async {
        final h = NativeTransportHarness(protocol);
        await h.store();
        h.response = nativeTransportSse(
          protocol,
          text: 'before $nativeCanary after ',
          reasoning: '$nativeCanary ',
        );
        await h.run();
        expect(h.errors, isEmpty);
        final complete = h.completions.single;
        expect(complete.$1, contains('[REDACTED]'));
        expect(complete.$2, contains('[REDACTED]'));
        expect(complete.$1, isNot(contains(nativeCanary)));
        expect(complete.$2, isNot(contains(nativeCanary)));
        expect(complete.$3, isNot(contains(nativeCanary)));
        expect(complete.$3, isNot(contains('x-ignored-raw-canary')));
        expect(
          h.updates.map((delta) => delta.$1).join(),
          isNot(contains(nativeCanary)),
        );
        expect(
          h.updates.map((delta) => delta.$2 ?? '').join(),
          isNot(contains(nativeCanary)),
        );
      },
    );
  }

  test(
    'schema key echo is removed BEFORE terminal completion/raw projection',
    () async {
      final h = NativeTransportHarness('openai');
      await h.store();
      h.response = nativeTransportSse(
        'openai',
        text: jsonEncode({'prefix': '', 'content': nativeCanary}),
      );
      await h.run(input: h.request(schema: const {'type': 'object'}));
      expect(h.updates, isEmpty);
      expect(h.errors, isEmpty);
      expect(h.completions.single.$1, '[REDACTED]');
      expect(h.completions.single.$3, isNot(contains(nativeCanary)));
    },
  );

  for (final payload in [
    _frame({
      'error': {'message': nativeCanary},
    }),
    'event: error\ndata: {"message":"$nativeCanary"}\n\n',
    _frame({
      'choices': [
        {
          'index': 0,
          'delta': {'refusal': nativeCanary},
        },
      ],
    }),
    _frame({
      'choices': [
        {
          'index': 0,
          'delta': {
            'tool_calls': [
              {'name': nativeCanary},
            ],
          },
        },
      ],
    }),
    'data: not-json-$nativeCanary\n\n',
  ]) {
    test('provider/error/refusal/tool trees are fixed-code only', () async {
      final h = NativeTransportHarness('openai');
      await h.store();
      h.response = payload;
      await h.run();
      expect(h.completions, isEmpty);
      expect(h.updates, isEmpty);
      expect(h.errors.single, isA<NativeProviderTransportException>());
      expect(h.errors.single.toString(), isNot(contains(nativeCanary)));
      expect(h.wires, hasLength(1));
    });
  }

  for (final payload in ['', _frame(_chat('partial ')), 'data: {"choices":']) {
    test('partial/empty/truncated EOF is never invented completion', () async {
      final h = NativeTransportHarness('openai');
      await h.store();
      h.response = payload;
      await h.run();
      expect(h.completions, isEmpty);
      expect(h.errors, hasLength(1));
      expect(h.wires, hasLength(1));
    });
  }

  test(
    'real provider output-limit finish is not presented as complete',
    () async {
      final h = NativeTransportHarness('openai');
      await h.store();
      h.response =
          '${_frame(_chat('partial '))}'
          '${_frame({
            'choices': [
              {'index': 0, 'delta': <String, dynamic>{}, 'finish_reason': 'length'},
            ],
          })}'
          'data: [DONE]\n\n';
      await h.run();
      expect(h.completions, isEmpty);
      expect(
        h.errors.single,
        isA<NativeProviderTransportException>().having(
          (failure) => failure.reason,
          'limit classification',
          NativeProviderTransportReason.providerLimit,
        ),
      );
    },
  );

  final hostile = <String, List<int>>{
    'invalid UTF8': [100, 97, 116, 97, 58, 32, 255, 10, 10],
    'oversized frame': utf8.encode(
      'data: ${'x' * (NativeProviderTransportLimits.frameBytes + 1)}',
    ),
    'excessive depth': utf8.encode(
      'data: {"nested":${'[' * 33}0${']' * 33}}\n\n',
    ),
    'frame count': utf8.encode(
      _frame({'choices': <Object?>[], 'usage': <String, dynamic>{}}) *
          (NativeProviderTransportLimits.frames + 1),
    ),
    'unknown framing field': utf8.encode('arbitrary: $nativeCanary\n\n'),
  };
  for (final entry in hostile.entries) {
    test('hostile ${entry.key} remains bounded and fixed-safe', () async {
      final h = NativeTransportHarness('openai');
      await h.store();
      h.responseStream = Stream.value(Uint8List.fromList(entry.value));
      await h.run();
      expect(h.completions, isEmpty);
      expect(h.errors, hasLength(1));
      expect(h.errors.single.toString(), isNot(contains(nativeCanary)));
      expect(h.adapters.single.closed, isTrue);
    });
  }

  test(
    'tool requests, function history and cyclic schemas cannot reach an adapter',
    () async {
      final h = NativeTransportHarness('openai');
      await h.store();
      await h.run(input: h.request(tools: const []));
      await h.run(
        input: h.request(
          messages: const [
            {'role': 'tool', 'content': 'result'},
          ],
        ),
      );
      final schema = <String, dynamic>{};
      schema['cycle'] = schema;
      await h.run(input: h.request(schema: schema));
      expect(h.wires, isEmpty);
      expect(h.adapters, isEmpty);
      expect(h.errors, hasLength(3));
    },
  );

  test(
    'one-byte UTF8 framing preserves real Unicode text and reasoning',
    () async {
      final h = NativeTransportHarness('openai');
      await h.store();
      final bytes = utf8.encode(
        nativeTransportSse(
          'openai',
          text: 'Привет 🔐 ',
          reasoning: 'Думаю 🐈 ',
        ),
      );
      h.responseStream = Stream.fromIterable(
        bytes.map((byte) => Uint8List.fromList([byte])),
      );
      await h.run();
      expect(h.errors, isEmpty);
      expect(h.completions.single.$1, 'Привет 🔐 ');
      expect(h.completions.single.$2, 'Думаю 🐈 ');
    },
  );
}
