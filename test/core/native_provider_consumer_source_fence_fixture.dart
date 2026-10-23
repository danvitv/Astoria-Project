import 'package:dio/dio.dart';
import 'package:glaze_flutter/core/llm/agent_runner.dart';
import 'package:glaze_flutter/core/llm/agent_stream_runner.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/studio_turn_config_snapshot.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport.dart';
import 'package:glaze_flutter/core/models/pipeline_settings.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

import 'native_provider_source_fixture.dart';

export 'native_provider_source_fixture.dart';

/// Records ONLY the already-keyless consumer request, then delegates unchanged
/// to the real native factory over declared FakeStorage/fake final adapters.
/// This tap adds no currentness/admission logic and cannot hide a missing fence.
final class NativeConsumerRequestTap {
  NativeConsumerRequestTap(this.delegate);
  final ChatTransport Function(String) delegate;
  final requests = <ChatTransportRequest>[];
  ChatTransport pick(String protocol) =>
      _ConsumerTappedTransport(this, delegate(protocol));
}

final class _ConsumerTappedTransport implements ChatTransport {
  const _ConsumerTappedTransport(this.tap, this.delegate);
  final NativeConsumerRequestTap tap;
  final ChatTransport delegate;
  @override
  Future<void> stream({
    required ChatTransportRequest request,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
    ChatTransportOnError? onError,
  }) {
    tap.requests.add(request);
    return delegate.stream(
      request: request,
      cancelToken: cancelToken,
      onUpdate: onUpdate,
      onComplete: onComplete,
      onError: onError,
    );
  }

  @override
  Future<List<Map<String, dynamic>>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) => throw StateError('Consumer fixtures must not list models');
}

final class NativeConsumerSourceFenceFixture {
  NativeConsumerSourceFenceFixture(this.consumer, {String protocol = 'openai'})
    : source = NativeSourceConsumerFixture(protocol: protocol) {
    tap = NativeConsumerRequestTap(source.wire.factory.pick);
  }
  final String consumer;
  final NativeSourceConsumerFixture source;
  final token = CancelToken();
  late final NativeConsumerRequestTap tap;
  late final NativePreparedSavedConnection scope;
  final updates = <String>[];
  final completions = <String>[];
  final rawResponses = <(String?, String?)>[];
  final failures = <Object>[];

  Future<void> prepare() async {
    final purpose = consumer == 'agent'
        ? NativeProviderPurpose.studio
        : NativeProviderPurpose.memoryBooks;
    await source.wire.store(purposes: {purpose});
    scope = await source.prepare(purpose: purpose);
    if (consumer == 'aux_once') {
      source.wire.response = nativeTransportJson(source.wire.protocol);
      source.wire.contentType = 'application/json';
    }
  }

  /// No renewed auth/source read here: every consumer receives the exact scope
  /// obtained BEFORE its own original request/metadata/final factory boundaries.
  Future<void> run() async {
    try {
      if (consumer == 'agent') {
        final snapshot = StudioTurnConfigSnapshot(
          config: null,
          preset: null,
          pipelineSettings: const PipelineSettings(),
          apiConfigs: [scope.configuration],
          activeApiConfig: scope.configuration,
          nativeSources: {scope.savedConnectionId: scope},
        );
        final resolved =
            ResolvedAgentConfig.fromApiConfig(
                  scope.configuration,
                  nativeSource: snapshot.nativeSourceFor(
                    scope.savedConnectionId,
                  ),
                )
                .copyWithSampling(topP: 0.5)
                .copyWithReasoning(requestReasoning: false)
                .copyWithReasoningTags(
                  reasoningTagStart: '<think>',
                  reasoningTagEnd: '</think>',
                );
        final result = await AgentStreamRunner(tap.pick).run(
          agent: const StudioAgent(
            id: 'continuity',
            controllerId: 'continuity',
          ),
          messages: const [
            {'role': 'user', 'content': 'Synthetic prompt'},
          ],
          resolved: resolved,
          sessionId: 'original-session',
          isFinalResponse: false,
          cancelToken: token,
          timeoutMs: 60000,
          onIntermediateUpdate: updates.add,
        );
        completions.add(result.text);
        return;
      }
      final config = AuxApiConfig(
        endpoint: scope.configuration.endpoint,
        apiKey: scope.configuration.apiKey,
        model: scope.configuration.model,
        protocol: scope.configuration.protocol,
        useResponsesApi: scope.configuration.useResponsesApi,
        savedConnectionAuth: scope.savedConnectionAuth,
        savedConnectionId: scope.savedConnectionId,
        nativeSource: scope,
      );
      final llm = AuxLlmClient(
        sources: source.sources,
        purpose: NativeProviderPurpose.memoryBooks,
        transportPicker: tap.pick,
      );
      final outcome = consumer == 'aux_once'
          ? await llm.callOnceWithLog(
              config: config,
              prompt: 'Synthetic prompt',
              maxTokens: 100,
              temperature: 0.2,
              timeoutMs: 60000,
              cancelToken: token,
              onRawResponse: (reasoning, raw) =>
                  rawResponses.add((reasoning, raw)),
            )
          : await llm.callStreamWithLog(
              config: config,
              prompt: 'Synthetic prompt',
              maxTokens: 100,
              temperature: 0.2,
              timeoutMs: 60000,
              cancelToken: token,
              onChunk: updates.add,
            );
      if (outcome.isOk) completions.add(outcome.text!);
      if (outcome.lastError != null) failures.add(outcome.lastError!);
    } catch (error) {
      failures.add(error);
    }
  }

  void revoke(String change) {
    switch (change) {
      case 'redactor':
        source.wire.core.redaction.registerSecret(
          'TEST_ONLY_REPLACEMENT_SECRET',
        );
      case 'Stop':
        // Intentionally cancel the PARENT token. Its child propagation is a
        // microtask: request predicate must reject even before that runs.
        token.cancel();
      case 'session':
        source.sessionId = 'replacement-session';
      case 'ABA':
        source.wire.core.ordinaryMutation();
        source.wire.core.ordinaryMutation();
      default:
        throw StateError('Unknown synthetic source change');
    }
  }
}
