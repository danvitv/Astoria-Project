import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_adapter.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_request.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_transport.dart';

import '_private_text_fixture.dart';

void main() {
  final tampering = <String, void Function(RequestOptions)>{
    'route': (options) =>
        options.path = 'https://another.invalid/v1/chat/completions',
    'method': (options) => options.method = 'GET',
    'auth': (options) => options.headers['Authorization'] = 'Bearer changed',
    'extra auth': (options) => options.headers['x-api-key'] = 'changed',
    'redirect': (options) => options.followRedirects = true,
    'body': (options) =>
        options.data['messages'][1]['content'] = 'UNAPPROVED_CHANGE',
    'stream type': (options) => options.responseType = ResponseType.json,
    'rejected body capture': (options) =>
        options.receiveDataWhenStatusError = true,
    'cancel owner': (options) => options.cancelToken = CancelToken(),
  };
  for (final entry in tampering.entries) {
    test(
      'final handoff rejects ${entry.key} changed DURING authorization',
      () async {
        final request = privateRequest();
        final plan = PrivateTextRequestPlan(
          LlmProtocol.openai,
          request,
          Uri.parse(request.endpoint),
          SecretRedactor(),
        );
        final token = CancelToken();
        final entered = Completer<void>();
        final approval = Completer<bool>();
        var factories = 0;
        final adapter = PrivateTextAdapter(
          factory: () {
            factories++;
            return PrivateFixtureAdapter(chatComplete('must not send'));
          },
          authorize: (_) {
            entered.complete();
            return approval.future;
          },
          plan: plan,
          cancelToken: token,
          isCurrent: () => true,
          currentRedactor: () => SecretRedactor(),
        );
        final options = RequestOptions(
          path: plan.wireUri.toString(),
          method: 'POST',
          headers: {
            ...plan.headers,
            'content-length': '${utf8.encode(plan.bodyJson).length}',
          },
          data: jsonDecode(plan.bodyJson),
          cancelToken: token,
          followRedirects: false,
          maxRedirects: 0,
          responseType: ResponseType.stream,
          receiveDataWhenStatusError: false,
        );
        final pending = adapter.fetch(options, null, token.whenCancel);
        final asserted = expectLater(
          pending,
          throwsA(
            isA<PrivateTextFailure>().having(
              (failure) => failure.reason,
              'reason',
              PrivateTextReason.invalidRequest,
            ),
          ),
        );
        await entered.future;
        entry.value(options);
        approval.complete(true);
        await asserted;
        expect(factories, 0);
        adapter.close(force: true);
      },
    );
  }

  test(
    'native preparation freezes exact text before delayed authorization',
    () async {
      final messages = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'EXACT_APPROVED_TEXT'},
      ];
      final entered = Completer<void>();
      final approval = Completer<bool>();
      final adapter = PrivateFixtureAdapter(chatComplete('safe'));
      final fixture = PrivateFixture(
        [adapter],
        authorize: (_) {
          entered.complete();
          return approval.future;
        },
      );
      final pending = fixture.run(request: privateRequest(messages: messages));
      await entered.future;
      messages.single['content'] = 'LATER_MUTATION';
      approval.complete(true);
      expect((await pending).status, PrivateTextStatus.complete);
      expect(adapter.upload, contains('EXACT_APPROVED_TEXT'));
      expect(adapter.upload, isNot(contains('LATER_MUTATION')));
    },
  );

  test(
    'non-text/unknown message fields and oversized exact input never send',
    () async {
      for (final messages in <List<Map<String, dynamic>>>[
        [
          {'role': 'user', 'content': 'x' * 8193},
        ],
        [
          {'role': 'system', 'content': 'x' * 65536},
          {'role': 'user', 'content': 'more'},
        ],
        [
          {
            'role': 'user',
            'content': [
              {'type': 'image_url', 'image_url': 'UNSELECTED_ATTACHMENT'},
            ],
          },
        ],
        [
          {
            'role': 'user',
            'content': 'text',
            'reasoning': 'UNSELECTED_REASONING',
          },
        ],
        [
          {'role': 'tool', 'content': 'tool output'},
        ],
        [
          {'role': 'user', 'content': 'fixture-credential'},
        ],
      ]) {
        final fixture = PrivateFixture([]);
        expect(
          (await fixture.run(
            request: privateRequest(messages: messages),
          )).status,
          PrivateTextStatus.error,
        );
        expect(fixture.created, isEmpty);
        expect(fixture.handoffs, isEmpty);
      }
    },
  );
  test('pre-cancelled/current-false calls never even authorize', () async {
    final fixture = PrivateFixture([]);
    final token = CancelToken()..cancel();
    expect(
      (await fixture.run(cancelToken: token)).status,
      PrivateTextStatus.stopped,
    );
    expect(
      (await fixture.run(isCurrent: () => false)).status,
      PrivateTextStatus.stopped,
    );
    expect(fixture.created, isEmpty);
    expect(fixture.handoffs, isEmpty);
  });

  test(
    'new current secret policy after authorization refuses exact input',
    () async {
      var redactor = SecretRedactor();
      final adapter = PrivateFixtureAdapter(chatComplete('must not send'));
      final fixture = PrivateFixture(
        [adapter],
        redactor: () => redactor,
        authorize: (_) async {
          redactor = SecretRedactor(knownSecrets: ['CURRENT_TEXT_CANARY']);
          return true;
        },
      );
      final result = await fixture.run();
      expect(result.status, PrivateTextStatus.error);
      expect(result.reason, PrivateTextReason.invalidRequest);
      expect(adapter.options, isNull);
      expect(adapter.closed, true);
    },
  );
}
