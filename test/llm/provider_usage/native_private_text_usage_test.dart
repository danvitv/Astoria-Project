import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_transport.dart';

import '../../core/native_provider_transport_fixture.dart';
import '_provider_usage_fixture.dart';

Future<PrivateTextOutcome> _runUsage(
  NativeTransportHarness h, {
  PrivateTextAdmission? admit,
}) {
  final auth = h.core.reference(NativeProviderPurpose.astoria);
  final dispatcher = NativeProviderPrivateTextDispatcher(
    credentials: h.core.credentials,
    authIssuer: h.core.auth,
    mutations: h.core.mutations,
    routes: h.core.policy,
    privateTextTransport: PrivateTextTransport(
      adapterFactory: h.adapter,
      currentRedactor: () => h.core.redaction.redactor,
      authorize: (_) async => true,
      admit: admit,
    ),
  );
  return dispatcher.generate(
    savedConnectionAuth: auth,
    request: h.request(purpose: NativeProviderPurpose.astoria, auth: auth),
    protocol: h.protocol,
    approvedRecipient: Uri.parse(h.core.row.endpoint),
    cancelToken: CancelToken(),
    isCurrent: () => true,
  );
}

void main() {
  // The reused harness is entirely synthetic: memory-only CredentialStorage,
  // fake saved rows, capture-free adapter, no plugins/DB/prefs/vault/key access.
  for (final protocol in nativeTransportProtocols) {
    test('$protocol native private wrapping preserves numeric usage', () async {
      final h = NativeTransportHarness(protocol);
      await h.store(purposes: {NativeProviderPurpose.astoria});
      h.response = usageComplete(
        protocol,
        'safe',
        usage: usageFields(
          protocol,
          input: 100,
          output: 8,
          total: 111,
          cached: 60,
          creation: 20,
          reasoning: 3,
        ),
      );
      final result = await _runUsage(h);
      expect(result.status, PrivateTextStatus.complete);
      expect(result.reason, PrivateTextReason.none);
      expect(result.text, 'safe');
      expect(result.dispatch, PrivateTextDispatch.admitted);
      expect(usageNumbers(result.usage), [
        100,
        8,
        protocol == LlmProtocol.anthropic ? null : 111,
        60,
        protocol == LlmProtocol.anthropic ? 20 : null,
        protocol == LlmProtocol.anthropic ? null : 3,
      ]);
      expect(h.wires, hasLength(1));
      expect(h.legacy.requests, isEmpty);
      expect(h.core.row.apiKey, isEmpty);
      expect(h.completions, isEmpty);
      expect(h.updates, isEmpty);
      expect(h.errors, isEmpty);
      expect(h.adapters.single.closed, isTrue);
      expect(result.toString(), isNot(contains(nativeCanary)));
    });

    test('$protocol native partial status is not upgraded by usage', () async {
      final h = NativeTransportHarness(protocol);
      await h.store(purposes: {NativeProviderPurpose.astoria});
      h.response = usagePartial(
        protocol,
        'partial',
        usage: usageFields(protocol, input: 100),
      );
      final result = await _runUsage(h);
      expect(result.status, PrivateTextStatus.partial);
      expect(result.reason, PrivateTextReason.unexpectedEof);
      expect(result.text, 'partial');
      expect(
        result.usage?.inputTokens,
        protocol == LlmProtocol.openaiResponses ? isNull : 100,
      );
      expect(h.wires, hasLength(1));
      expect(h.legacy.requests, isEmpty);
    });
  }

  test(
    'native parser failure retains accepted Gemini numbers, not completion',
    () async {
      final h = NativeTransportHarness(LlmProtocol.gemini);
      await h.store(purposes: {NativeProviderPurpose.astoria});
      h.response = frame(
        usageGeminiEvent('', usage: {'promptTokenCount': 100}, finish: 'STOP'),
      );
      final result = await _runUsage(h);
      expect(result.status, PrivateTextStatus.error);
      expect(result.reason, PrivateTextReason.transport);
      expect(result.text, isEmpty);
      expect(result.usage?.inputTokens, 100);
      expect(h.wires, hasLength(1));
      expect(h.legacy.requests, isEmpty);
    },
  );

  test(
    'native failed admission has no manufactured usage or fallback',
    () async {
      final h = NativeTransportHarness(LlmProtocol.openai);
      await h.store(purposes: {NativeProviderPurpose.astoria});
      h.fetchError = StateError(nativeCanary);
      final result = await _runUsage(
        h,
        admit: (capsule) async {
          capsule.dispatch();
          return true;
        },
      );
      expect(result.dispatch, PrivateTextDispatch.admittedFailed);
      expect(result.reason, PrivateTextReason.admittedFailed);
      expect(result.status, PrivateTextStatus.error);
      expect(result.usage, isNull);
      expect(result.toString(), isNot(contains(nativeCanary)));
      expect(h.wires, hasLength(1));
      expect(h.legacy.requests, isEmpty);
    },
  );
}
