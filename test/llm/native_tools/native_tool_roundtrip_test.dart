import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'native_tool_fixture.dart';

void main() {
  for (final protocol in nativeTransportProtocols) {
    test(
      '$protocol native definitions -> typed calls -> correlated replay -> final/actual usage',
      () async {
        final h = ToolHarness(protocol);
        await h.store();
        h.reply(h.response());
        final session = h.session();
        final first = await session.start();
        expect(first.status, NativeToolStatus.calls);
        expect(first.dispatch, NativeToolDispatch.admitted);
        expect(first.calls.single.id, 'call_1');
        expect(first.calls.single.name, 'set_theme');
        expect(first.calls.single.arguments, {'value': 'dark'});
        expect(first.actualUsage?.inputTokens, 11);
        expect(first.actualUsage?.cachedInputTokens, 3);
        h.reply(h.response(tool: false));
        final last = await session.continueWith([
          NativeToolResult(
            callId: first.calls.single.id,
            name: first.calls.single.name,
            content: {'applied': 'dark', 'maxTokens': 1024},
          ),
        ]);
        expect(last.status, NativeToolStatus.complete);
        expect(last.text, 'Theme is dark.');
        expect(last.calls, isEmpty);
        expect(last.actualUsage?.outputTokens, 5);
        expect(
          last.actualUsage?.totalTokens,
          protocol == 'anthropic' ? null : 16,
        );
        expect(h.native.wires, hasLength(2));
        expect(h.native.core.row.apiKey, isEmpty);
        expect(h.native.legacy.requests, isEmpty);
        expect(h.native.adapters.every((adapter) => adapter.closed), isTrue);
        final initial = h.native.wires.first.body;
        final body = h.native.wires.last.body;
        switch (protocol) {
          case 'openai_responses':
            expect(initial['tools'][0]['type'], 'function');
            expect(initial['tools'][0]['name'], 'set_theme');
            expect(body['store'], isFalse);
            final input = body['input'] as List;
            expect(input[1]['id'], 'fc_1');
            expect(input[1]['call_id'], 'call_1');
            expect(input[2]['type'], 'function_call_output');
            expect(input[2]['call_id'], 'call_1');
            expect(jsonDecode(input[2]['output'] as String), {
              'applied': 'dark',
              'maxTokens': 1024,
            });
          case 'anthropic':
            expect(initial['tools'][0]['input_schema']['type'], 'object');
            final messages = body['messages'] as List;
            expect(messages[1]['content'][0]['signature'], 'native_signature');
            expect(messages[1]['content'][1]['id'], 'call_1');
            expect(messages[2]['content'][0]['tool_use_id'], 'call_1');
            expect(jsonDecode(messages[2]['content'][0]['content'] as String), {
              'applied': 'dark',
              'maxTokens': 1024,
            });
          case 'gemini':
            expect(
              initial['tools'][0]['functionDeclarations'][0]['name'],
              'set_theme',
            );
            final contents = body['contents'] as List;
            expect(
              contents[1]['parts'][0]['thoughtSignature'],
              'native_thought_signature',
            );
            expect(contents[1]['parts'][0]['functionCall']['id'], 'call_1');
            expect(contents[2]['parts'][0]['functionResponse'], {
              'id': 'call_1',
              'name': 'set_theme',
              'response': {'applied': 'dark', 'maxTokens': 1024},
            });
            expect(h.native.wires.last.uri, h.recipient);
            expect(h.native.wires.last.uri.hasQuery, isFalse);
            expect(h.native.wires.last.headers['x-goog-api-key'], nativeCanary);
          default:
            expect(initial['tools'][0]['function']['name'], 'set_theme');
            final messages = body['messages'] as List;
            expect(messages[1]['tool_calls'][0]['id'], 'call_1');
            expect(messages[2]['role'], 'tool');
            expect(messages[2]['tool_call_id'], 'call_1');
            expect(jsonDecode(messages[2]['content'] as String), {
              'applied': 'dark',
              'maxTokens': 1024,
            });
        }
        expect(jsonEncode(body), isNot(contains(nativeCanary)));
        expect(last.toString(), isNot(contains(nativeCanary)));
      },
    );
  }

  test(
    'Gemini missing native id uses private round/index correlation without inventing wire id',
    () async {
      final h = ToolHarness('gemini');
      await h.store();
      final response = h.response();
      final candidates = response['candidates'] as List;
      (candidates[0]['content']['parts'][0]['functionCall'] as Map).remove(
        'id',
      );
      h.reply(response);
      final session = h.session();
      final first = await session.start();
      expect(first.calls.single.id, 'gemini_1_0');
      h.reply(h.response(tool: false));
      await session.continueWith([
        NativeToolResult(callId: 'gemini_1_0', name: 'set_theme', content: {}),
      ]);
      final contents = h.native.wires.last.body['contents'] as List;
      expect(
        contents[2]['parts'][0]['functionResponse'].containsKey('id'),
        isFalse,
      );
    },
  );

  test(
    'custom Responses saved route selects native Responses replay',
    () async {
      final row = nativeTransportRow('custom_chat_completion').copyWith(
        endpoint: 'https://synthetic.example/v1/responses',
        useResponsesApi: true,
      );
      final native = NativeTransportHarness('custom_chat_completion', row: row);
      await native.store(purposes: {NativeProviderPurpose.astoria});
      final responses = ToolHarness('openai_responses');
      native.contentType = 'application/json';
      native.response = jsonEncode(responses.response());
      final transport = NativeToolTransport(
        credentials: native.core.credentials,
        authIssuer: native.core.auth,
        mutations: native.core.mutations,
        routes: native.core.policy,
        currentRedactor: () => native.core.redaction.redactor,
        adapterFactory: native.adapter,
      );
      final session = transport.open(
        request: NativeToolRequest(
          config: row,
          savedConnectionAuth: native.core.reference(
            NativeProviderPurpose.astoria,
          ),
          approvedRecipient: Uri.parse(row.endpoint),
          tools: responses.tools,
          messages: [
            NativeToolMessage(role: NativeToolRole.user, text: 'Theme'),
          ],
        ),
        cancelToken: CancelToken(),
        isCurrent: () => true,
        beforeWire: (capsule) async {
          capsule.dispatch();
          return true;
        },
      );
      final first = await session.start();
      expect(first.status, NativeToolStatus.calls);
      native.response = jsonEncode(responses.response(tool: false));
      final finalTurn = await session.continueWith([
        NativeToolResult(
          callId: 'call_1',
          name: 'set_theme',
          content: {'applied': 'dark'},
        ),
      ]);
      expect(finalTurn.status, NativeToolStatus.complete);
      expect(native.wires.last.body['input'][2]['call_id'], 'call_1');
    },
  );
}
