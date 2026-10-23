import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_transport.dart';

import '_private_text_fixture.dart';

void main() {
  test('authorization denial invokes no adapter factory or HTTP', () async {
    final fixture = PrivateFixture([], authorize: (_) async => false);
    final result = await fixture.run();
    expect(result.reason, PrivateTextReason.denied);
    expect(fixture.created, isEmpty);
    expect(fixture.handoffs, hasLength(1));
  });
  for (final cancel in [true, false]) {
    test('cancel/stale during async authorization: $cancel', () async {
      final entered = Completer<void>();
      final approval = Completer<bool>();
      final token = CancelToken();
      var current = true;
      final fixture = PrivateFixture(
        [],
        authorize: (_) {
          entered.complete();
          return approval.future;
        },
      );
      final pending = fixture.run(cancelToken: token, isCurrent: () => current);
      await entered.future;
      if (cancel) {
        token.cancel();
      } else {
        current = false;
      }
      approval.complete(true);
      final result = await pending;
      expect(result.status, PrivateTextStatus.stopped);
      expect(fixture.created, isEmpty);
    });
  }
  test('factory-side invalidation is checked before inner dispatch', () async {
    final adapter = PrivateFixtureAdapter(chatComplete('must not send'));
    var current = true;
    final transport = PrivateTextTransport(
      adapterFactory: () {
        current = false;
        return adapter;
      },
      currentRedactor: () => SecretRedactor(),
      authorize: (_) async => true,
    );
    final result = await transport.generate(
      protocol: LlmProtocol.openai,
      request: privateRequest(),
      approvedRecipient: Uri.parse(privateRequest().endpoint),
      cancelToken: CancelToken(),
      isCurrent: () => current,
    );
    expect(result.status, PrivateTextStatus.stopped);
    expect(adapter.options, isNull);
    expect(adapter.closed, true);
  });
  final quietProtocols = [
    (
      LlmProtocol.openai,
      'https://fixture.invalid/v1/chat/completions',
      chatDelta('partial'),
    ),
    (
      LlmProtocol.openaiResponses,
      'https://fixture.invalid/v1/responses',
      frame({'type': 'response.output_text.delta', 'delta': 'partial'}),
    ),
    (
      LlmProtocol.anthropic,
      'https://fixture.invalid/v1/messages',
      anthropicStart() + anthropicText('partial'),
    ),
    (
      LlmProtocol.gemini,
      'https://fixture.invalid/v1beta/models/fixture-model:streamGenerateContent',
      geminiText('partial'),
    ),
  ];
  for (final protocol in quietProtocols) {
    test(
      'quiet stream cancellation reaches adapter and subscription: ${protocol.$1}',
      () async {
        final adapter = PrivateFixtureAdapter(protocol.$3, quiet: true);
        final active = Completer<void>();
        final token = CancelToken();
        final pending = PrivateFixture([adapter]).run(
          protocol: protocol.$1,
          request: privateRequest(endpoint: protocol.$2),
          cancelToken: token,
          activity: active.complete,
        );
        await active.future;
        token.cancel();
        final result = await pending.timeout(const Duration(seconds: 3));
        await adapter.cancelObserved.future.timeout(const Duration(seconds: 3));
        await adapter.responseCancelled.future.timeout(
          const Duration(seconds: 3),
        );
        expect(result.status, PrivateTextStatus.stopped);
        expect(result.text, 'partial');
        expect(adapter.closed, true);
      },
    );
  }
  for (final status in [301, 307, 400, 401, 500]) {
    test(
      'HTTP $status: status-only, no rejected body subscription/probe',
      () async {
        final adapter = PrivateFixtureAdapter(
          'RAW_PROVIDER_CANARY fixture-credential',
          status: status,
          quiet: true,
          contentType: 'application/json',
        );
        final fixture = PrivateFixture([adapter]);
        final result = await fixture.run();
        expect(result.status, PrivateTextStatus.error);
        expect(result.reason, PrivateTextReason.httpStatus);
        expect(result.httpStatus, status);
        expect(result.text, isEmpty);
        expect(adapter.responseListens, 0);
        expect(adapter.closed, true);
        expect(fixture.created, hasLength(1));
        expect(fixture.handoffs, hasLength(1));
      },
    );
  }
  test(
    '408 retry reauthorizes after native delay and does not read body',
    () async {
      final first = PrivateFixtureAdapter(
        'RAW_PROVIDER_CANARY',
        status: 408,
        quiet: true,
      );
      final second = PrivateFixtureAdapter(chatComplete('retried'));
      final fixture = PrivateFixture([first, second]);
      final result = await fixture.run();
      expect(result.status, PrivateTextStatus.complete);
      expect(result.text, 'retried');
      expect(fixture.handoffs.map((handoff) => handoff.attempt), [1, 2]);
      expect(first.responseListens, 0);
      expect(first.closed, true);
    },
  );
  test(
    'cancel during 408 retry authorization prevents the second dispatch',
    () async {
      final first = PrivateFixtureAdapter(
        'RAW_PROVIDER_CANARY',
        status: 408,
        quiet: true,
      );
      final entered = Completer<void>();
      final approval = Completer<bool>();
      final token = CancelToken();
      final fixture = PrivateFixture(
        [first],
        authorize: (handoff) {
          if (handoff.attempt == 1) return Future.value(true);
          entered.complete();
          return approval.future;
        },
      );
      final pending = fixture.run(cancelToken: token);
      await entered.future.timeout(const Duration(seconds: 3));
      token.cancel();
      approval.complete(true);
      expect((await pending).status, PrivateTextStatus.stopped);
      expect(fixture.created, hasLength(1));
      expect(first.responseListens, 0);
    },
  );

  test('stale ownership after 408 cannot start a native retry', () async {
    final first = PrivateFixtureAdapter(
      'RAW_PROVIDER_CANARY',
      status: 408,
      quiet: true,
    );
    var current = true;
    final fixture = PrivateFixture([first]);
    final pending = fixture.run(isCurrent: () => current);
    await first.forceClosed.future;
    current = false;
    expect((await pending).status, PrivateTextStatus.stopped);
    expect(fixture.created, hasLength(1));
    expect(fixture.handoffs, hasLength(1));
    expect(first.responseListens, 0);
  });
  test(
    'real deadline cancels a quiet stream, not merely the returned future',
    () async {
      final adapter = PrivateFixtureAdapter(chatDelta('partial'), quiet: true);
      final result = await PrivateFixture([
        adapter,
      ]).run(deadline: const Duration(milliseconds: 100));
      expect(result.reason, PrivateTextReason.deadline);
      expect(result.status, PrivateTextStatus.partial);
      await adapter.cancelObserved.future.timeout(const Duration(seconds: 3));
      await adapter.responseCancelled.future.timeout(
        const Duration(seconds: 3),
      );
    },
  );
  test(
    'unsupported route/model/action/HTTP and one-shot fail before send',
    () async {
      for (final request in [
        privateRequest(endpoint: 'http://fixture.invalid/v1/chat/completions'),
        privateRequest(
          endpoint: 'https://fixture.invalid/v1/chat/completions?key=x',
        ),
        privateRequest(
          endpoint: 'https://fixture.invalid/v1/chat/completions#fragment',
        ),
        privateRequest(
          endpoint: 'https://fixture.invalid/v1/chat/completions',
          stream: false,
        ),
        privateRequest(
          endpoint:
              'https://fixture.invalid/v1beta/models/fixture-model:generateContent',
        ),
        privateRequest(
          endpoint:
              'https://fixture.invalid/v1beta/models/another-model:streamGenerateContent',
        ),
      ]) {
        final fixture = PrivateFixture([]);
        final result = await fixture.run(
          protocol: request.endpoint.contains('/models/')
              ? LlmProtocol.gemini
              : LlmProtocol.openai,
          request: request,
        );
        expect(result.status, PrivateTextStatus.error);
        expect(fixture.created, isEmpty);
        expect(fixture.handoffs, isEmpty);
      }
      final fixture = PrivateFixture([]);
      expect(
        (await fixture.run(protocol: 'unknown')).reason,
        PrivateTextReason.unsupported,
      );
      expect(
        (await fixture.run(
          approved: Uri.parse('https://another.invalid/v1/chat/completions'),
        )).status,
        PrivateTextStatus.error,
      );
    },
  );
}
