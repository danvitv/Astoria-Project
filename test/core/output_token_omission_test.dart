import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/llm/transport/anthropic_chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/gemini_chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/llm/transport/openai_chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/openai_responses_transport.dart';
import 'package:glaze_flutter/core/llm/transport/openrouter_chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_request.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_transport.dart';

import 'native_provider_transport_fixture.dart';

const _outputKeys = {
  'max_tokens',
  'max_completion_tokens',
  'max_output_tokens',
  'maxOutputTokens',
};

ChatTransportRequest _request(
  String protocol,
  int tokens, {
  String? model,
  String? effort,
  bool customResponses = false,
}) {
  final selectedModel =
      model ??
      switch (protocol) {
        LlmProtocol.anthropic => 'claude-sonnet-4-5',
        LlmProtocol.gemini => 'gemini-3.1-pro',
        _ => 'synthetic-model',
      };
  final responses = protocol == LlmProtocol.openaiResponses || customResponses;
  final endpoint = switch (protocol) {
    LlmProtocol.openrouter => OpenRouterChatTransport.baseUrl,
    LlmProtocol.anthropic => 'https://synthetic.invalid/v1/messages',
    LlmProtocol.gemini =>
      'https://synthetic.invalid/v1beta/models/$selectedModel:streamGenerateContent',
    _ when responses => 'https://synthetic.invalid/v1/responses',
    _ => 'https://synthetic.invalid/v1/chat/completions',
  };
  return ChatTransportRequest(
    endpoint: endpoint,
    apiKey: 'synthetic-output-token-secret',
    model: selectedModel,
    messages: const [
      {'role': 'system', 'content': 'Synthetic system instruction'},
      {'role': 'user', 'content': 'Synthetic current input'},
    ],
    maxTokens: tokens,
    temperature: 0.4,
    topP: 1,
    requestReasoning: effort != null,
    reasoningEffort: effort,
    useResponsesApi: responses,
    sessionIdMode: 'off',
  );
}

Map<String, dynamic> _body(
  String protocol,
  ChatTransportRequest request,
) => switch (protocol) {
  LlmProtocol.anthropic => AnthropicChatTransport.buildRequest(request).body,
  LlmProtocol.gemini => GeminiChatTransport.buildRequest(request).body,
  _ when request.useResponsesApi => OpenAiResponsesTransport.buildBody(request),
  LlmProtocol.openrouter => OpenAiChatTransport.buildBody(
    OpenRouterChatTransport.buildRouterRequest(request),
    protocol: protocol,
  ),
  _ => OpenAiChatTransport.buildBody(request, protocol: protocol),
};

Map<String, dynamic> _outputFields(Object? value) {
  final result = <String, dynamic>{};
  void visit(Object? node) {
    if (node is Map) {
      for (final entry in node.entries) {
        if (_outputKeys.contains(entry.key)) {
          result[entry.key as String] = entry.value;
        }
        visit(entry.value);
      }
    } else if (node is List) {
      for (final child in node) {
        visit(child);
      }
    }
  }

  visit(value);
  return result;
}

ChatTransportRequest _nativeRequest(
  NativeTransportHarness h,
  int tokens, {
  NativeProviderPurpose purpose = NativeProviderPurpose.roleplay,
}) {
  final original = h.request(purpose: purpose);
  return ChatTransportRequest(
    endpoint: original.endpoint,
    apiKey: '',
    model: original.model,
    messages: original.messages,
    savedConnectionId: original.savedConnectionId,
    savedConnectionAuth: original.savedConnectionAuth,
    maxTokens: tokens,
    temperature: original.temperature,
    topP: original.topP,
    useResponsesApi: original.useResponsesApi,
    requestReasoning: true,
    reasoningEffort: 'high',
    sessionIdMode: 'off',
  );
}

void main() {
  // The first matrix is pure actual serializer and accepted private-plan bodies:
  // no transport, adapter, database, app graph or network is constructed here.
  for (final protocol in LlmProtocol.all) {
    final variants = protocol == LlmProtocol.customChatCompletion
        ? [false, true]
        : [false];
    for (final customResponses in variants) {
      final label = '$protocol${customResponses ? '/responses' : ''}';
      for (final effort in [null, 'low', 'medium', 'high']) {
        test('$label -1 omits every output key with reasoning=$effort', () {
          final input = _request(
            protocol,
            -1,
            effort: effort,
            customResponses: customResponses,
          );
          expect(_outputFields(_body(protocol, input)), isEmpty);
          final plan = PrivateTextRequestPlan(
            protocol,
            input,
            Uri.parse(input.endpoint),
            SecretRedactor(knownSecrets: [input.apiKey]),
          );
          expect(plan.request.maxTokens, -1);
          expect(_outputFields(jsonDecode(plan.bodyJson)), isEmpty);
        });
      }
      for (final tokens in [8192, 131072, 0x7fffffff]) {
        test('$label preserves manual positive $tokens without clamping', () {
          final input = _request(
            protocol,
            tokens,
            customResponses: customResponses,
          );
          final key = protocol == LlmProtocol.gemini
              ? 'maxOutputTokens'
              : input.useResponsesApi
              ? 'max_output_tokens'
              : 'max_tokens';
          expect(_outputFields(_body(protocol, input)), {key: tokens});
          final plan = PrivateTextRequestPlan(
            protocol,
            input,
            Uri.parse(input.endpoint),
            SecretRedactor(knownSecrets: [input.apiKey]),
          );
          expect(plan.request.maxTokens, tokens);
          expect(_outputFields(jsonDecode(plan.bodyJson)), {key: tokens});
        });
      }
      for (final tokens in [0, -2, 0x80000000]) {
        test('$label private validation rejects $tokens, not a fallback', () {
          final input = _request(
            protocol,
            tokens,
            customResponses: customResponses,
          );
          expect(
            () => PrivateTextRequestPlan(
              protocol,
              input,
              Uri.parse(input.endpoint),
              SecretRedactor(knownSecrets: [input.apiKey]),
            ),
            throwsA(isA<PrivateTextFailure>()),
          );
        });
      }
    }
  }

  for (final model in ['claude-sonnet-4-5', 'claude-opus-4-6']) {
    test(
      'Anthropic $model thinking cannot restore an omitted output limit',
      () {
        final body = _body(
          LlmProtocol.anthropic,
          _request(LlmProtocol.anthropic, -1, model: model, effort: 'high'),
        );
        expect(_outputFields(body), isEmpty);
        expect(body['thinking'], isNotNull);
      },
    );
  }

  test(
    'Anthropic legacy positive thinking response budget stays unchanged',
    () {
      final body = _body(
        LlmProtocol.anthropic,
        _request(LlmProtocol.anthropic, 1024, effort: 'low'),
      );
      expect(body['max_tokens'], 2048);
      expect(body['thinking'], {'type': 'enabled', 'budget_tokens': 1024});
    },
  );

  for (final model in ['gemini-2.5-flash', 'gemini-2.5-pro']) {
    test('Gemini $model thinking stays separate from -1 output omission', () {
      final body = _body(
        LlmProtocol.gemini,
        _request(LlmProtocol.gemini, -1, model: model, effort: 'high'),
      );
      expect(_outputFields(body), isEmpty);
      expect((body['generationConfig'] as Map)['thinkingConfig'], isNotNull);
    });
  }

  // Supplemental synthetic native dispatch evidence exercises the private
  // keyed/cache copies and actual upload bytes. This fixture uses only fake
  // storage, fake HTTP adapters and declared canaries, never runtime credentials.
  for (final protocol in nativeTransportProtocols) {
    for (final tokens in [-1, 8192, 131072]) {
      test('$protocol native wire preserves output setting $tokens', () async {
        final h = NativeTransportHarness(protocol);
        await h.store();
        final request = _nativeRequest(h, tokens);
        await h.run(input: request);
        expect(h.errors, isEmpty);
        expect(h.wires, hasLength(1));
        final fields = _outputFields(h.wires.single.body);
        if (tokens == -1) {
          expect(fields, isEmpty);
        } else {
          expect(fields, hasLength(1));
          expect(fields.values.single, tokens);
        }
        expect(request.maxTokens, tokens);
        expect(request.apiKey, isEmpty);
        expect(h.legacy.requests, isEmpty);
      });
    }

    for (final tokens in [-1, 131072]) {
      test('$protocol accepted native private text keeps $tokens', () async {
        final h = NativeTransportHarness(protocol);
        await h.store(purposes: {NativeProviderPurpose.astoria});
        final request = _nativeRequest(
          h,
          tokens,
          purpose: NativeProviderPurpose.astoria,
        );
        final dispatcher = NativeProviderPrivateTextDispatcher(
          credentials: h.core.credentials,
          authIssuer: h.core.auth,
          mutations: h.core.mutations,
          routes: h.core.policy,
          privateTextTransport: PrivateTextTransport(
            adapterFactory: h.adapter,
            currentRedactor: () => h.core.redaction.redactor,
            authorize: (_) async => true,
          ),
        );
        final result = await dispatcher.generate(
          savedConnectionAuth: request.savedConnectionAuth!,
          request: request,
          protocol: protocol,
          approvedRecipient: Uri.parse(request.endpoint),
          cancelToken: CancelToken(),
          isCurrent: () => true,
        );
        expect(result.status, PrivateTextStatus.complete);
        expect(result.dispatch, PrivateTextDispatch.admitted);
        expect(h.wires, hasLength(1));
        final fields = _outputFields(h.wires.single.body);
        if (tokens == -1) {
          expect(fields, isEmpty);
        } else {
          expect(fields, hasLength(1));
          expect(fields.values.single, tokens);
        }
        expect(request.apiKey, isEmpty);
        expect(h.legacy.requests, isEmpty);
      });
    }

    for (final tokens in [0, -2, 0x80000000]) {
      test(
        '$protocol native plan refuses invalid $tokens before upload',
        () async {
          final h = NativeTransportHarness(protocol);
          await h.store();
          await h.run(input: _nativeRequest(h, tokens));
          expect(h.errors, isNotEmpty);
          expect(h.wires, isEmpty);
          expect(h.legacy.requests, isEmpty);
        },
      );
    }
  }
}
