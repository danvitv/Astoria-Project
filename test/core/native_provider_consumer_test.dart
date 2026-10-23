import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/agent_runner.dart';
import 'package:glaze_flutter/core/llm/agent_stream_runner.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/controller_batcher.dart';
import 'package:glaze_flutter/core/llm/studio/agent_config_resolver.dart';
import 'package:glaze_flutter/core/llm/studio_turn_config_snapshot.dart';
import 'package:glaze_flutter/core/models/pipeline_settings.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

import 'native_provider_source_fixture.dart';

const _controller = StudioAgent(id: 'continuity', controllerId: 'continuity');

AuxApiConfig _aux(NativePreparedSavedConnection source) => AuxApiConfig(
  endpoint: source.configuration.endpoint,
  apiKey: source.configuration.apiKey,
  model: source.configuration.model,
  protocol: source.configuration.protocol,
  useResponsesApi: source.configuration.useResponsesApi,
  savedConnectionId: source.savedConnectionId,
  savedConnectionAuth: source.savedConnectionAuth,
  nativeSource: source,
);

AgentConfigResolver _resolver(NativeSourceConsumerFixture f) =>
    AgentConfigResolver(
      loadApiConfigs: f.repo.getAll,
      readActiveApiConfig: () => f.repo.row,
      readPipelineSettings: () => const PipelineSettings(),
      sources: f.sources,
      isCurrent: () => f.runCurrent,
    );

void main() {
  for (final protocol in nativeTransportProtocols.where(
    (p) => p != 'custom_chat_completion',
  )) {
    test(
      'actual AgentStreamRunner keyless copies reach native fake wire: $protocol',
      () async {
        final f = NativeSourceConsumerFixture(protocol: protocol);
        await f.wire.store(purposes: {NativeProviderPurpose.studio});
        final source = await f.prepare(purpose: NativeProviderPurpose.studio);
        final resolved =
            ResolvedAgentConfig.fromApiConfig(
                  source.configuration,
                  nativeSource: source,
                )
                .copyWithSampling(topP: 0.5)
                .copyWithReasoning(requestReasoning: true)
                .copyWithReasoningTags(
                  reasoningTagStart: '<think>',
                  reasoningTagEnd: '</think>',
                );
        expect(
          identical(resolved.savedConnectionAuth, source.savedConnectionAuth),
          isTrue,
        );
        expect(identical(resolved.nativeSource, source), isTrue);
        expect(resolved.apiKey, isEmpty);
        final request = AgentStreamRunner.buildRequest(
          agent: _controller,
          messages: const [
            {'role': 'user', 'content': 'Synthetic prompt'},
          ],
          resolved: resolved,
          sessionId: 'session',
          isFinalResponse: false,
        );
        expect(
          identical(request.savedConnectionAuth, source.savedConnectionAuth),
          isTrue,
        );
        expect(request.savedConnectionId, source.savedConnectionId);
        expect(request.nativeSourceIsCurrent, isNotNull);
        expect(
          request.withMessages(request.messages).savedConnectionAuth,
          same(source.savedConnectionAuth),
        );
        expect(
          request.withMessages(request.messages).nativeSourceIsCurrent,
          same(request.nativeSourceIsCurrent),
        );
        final result = await AgentStreamRunner(f.wire.factory.pick).run(
          agent: _controller,
          messages: request.messages,
          resolved: resolved,
          sessionId: 'session',
          isFinalResponse: false,
          cancelToken: CancelToken(),
          timeoutMs: 60000,
        );
        expect(result.text, contains('Visible text'));
        expect(f.wire.wires.length, 1);
        expect(
          f.wire.wires.single.body.toString(),
          isNot(contains(nativeCanary)),
        );
        expect(
          f.wire.wires.single.headers.values.join(),
          contains(nativeCanary),
        );
        expect(f.wire.legacy.requests, isEmpty);
      },
    );

    test(
      'actual Memory-purpose Aux client reaches only native wire: $protocol',
      () async {
        final f = NativeSourceConsumerFixture(protocol: protocol);
        await f.wire.store(purposes: {NativeProviderPurpose.memoryBooks});
        final source = await f.prepare(
          purpose: NativeProviderPurpose.memoryBooks,
        );
        f.wire.response = nativeTransportJson(protocol);
        f.wire.contentType = 'application/json';
        final llm = AuxLlmClient(
          sources: f.sources,
          purpose: NativeProviderPurpose.memoryBooks,
          transportPicker: f.wire.factory.pick,
        );
        final result = await llm.callOnce(
          config: _aux(source),
          prompt: 'Synthetic prompt',
          maxTokens: 1024,
          temperature: 0.2,
          timeoutMs: 60000,
          cancelToken: CancelToken(),
        );
        expect(result, contains('Visible text'));
        expect(f.wire.wires.length, 1);
        expect(
          f.wire.wires.single.headers.values.join(),
          contains(nativeCanary),
        );
        expect(f.promptConfig!.apiKey, isEmpty);
        expect(f.wire.legacy.requests, isEmpty);
      },
    );
  }

  test(
    'actual agent resolver captures stamp before held saved config load',
    () async {
      final f = NativeSourceConsumerFixture();
      await f.wire.store(purposes: {NativeProviderPurpose.studio});
      final gate = NativeSourceHeldGate();
      f.repo.beforeRead = gate.hold;
      final pending = _resolver(
        f,
      ).resolveAgentConfig(_controller, f.repo.row, 'session');
      pending.ignore();
      await gate.entered.future;
      f.wire.core.ordinaryMutation();
      gate.release();
      await expectLater(pending, throwsNative(NativeProviderFailure.stale));
      expect(f.wire.wires, isEmpty);
    },
  );

  test(
    'native controller/final/cleaner/Ledger overrides are refused, never ignored',
    () async {
      final f = NativeSourceConsumerFixture(protocol: 'gemini');
      await f.wire.store(purposes: {NativeProviderPurpose.studio});
      final source = await f.prepare(purpose: NativeProviderPurpose.studio);
      final globals = const PipelineSettings();
      final pipeline = globals.copyWith(
        studioAgent: globals.studioAgent.copyWith(
          studioFinalModelOverride: 'unbound-final',
          studioControllerModelOverride: 'unbound-controller',
        ),
        cleaner: globals.cleaner.copyWith(postCleanerModel: 'unbound-cleaner'),
        ledger: globals.ledger.copyWith(studioLedgerModel: 'unbound-ledger'),
      );
      final snapshot = StudioTurnConfigSnapshot(
        config: null,
        preset: null,
        pipelineSettings: pipeline,
        apiConfigs: [source.configuration],
        activeApiConfig: source.configuration,
        nativeSources: {source.savedConnectionId: source},
      );
      final resolver = _resolver(f);
      await expectLater(
        resolver.resolveAgentConfig(
          _controller,
          source.configuration,
          'session',
          turnConfig: snapshot,
        ),
        throwsNative(NativeProviderFailure.denied),
      );
      await expectLater(
        resolver.resolveAgentConfig(
          _controller,
          source.configuration,
          'session',
          isFinalResponse: true,
          turnConfig: snapshot,
        ),
        throwsNative(NativeProviderFailure.denied),
      );
      expect(
        () => snapshot.resolveCleanerConfig(errorLabel: 'cleaner'),
        throwsNative(NativeProviderFailure.denied),
      );
      expect(
        () => snapshot.resolveLedgerConfig(errorLabel: 'ledger'),
        throwsNative(NativeProviderFailure.denied),
      );
      expect(f.wire.wires, isEmpty);
    },
  );

  test(
    'snapshot cleaner/Ledger and sampling preserve exact native source',
    () async {
      final f = NativeSourceConsumerFixture();
      await f.wire.store(purposes: {NativeProviderPurpose.studio});
      final source = await f.prepare(purpose: NativeProviderPurpose.studio);
      final snapshot = StudioTurnConfigSnapshot(
        config: null,
        preset: null,
        pipelineSettings: const PipelineSettings(),
        apiConfigs: [source.configuration],
        activeApiConfig: source.configuration,
        nativeSources: {source.savedConnectionId: source},
      );
      final cleaner = snapshot.resolveCleanerConfig(errorLabel: 'cleaner');
      final ledger = snapshot.resolveLedgerConfig(errorLabel: 'ledger');
      expect(cleaner.savedConnectionAuth, same(source.savedConnectionAuth));
      expect(ledger.savedConnectionAuth, same(source.savedConnectionAuth));
      expect(cleaner.apiKey, isEmpty);
      expect(ledger.apiKey, isEmpty);
      f.wire.core.ordinaryMutation();
      expect(
        snapshot.requireNativeSourcesCurrent,
        throwsNative(NativeProviderFailure.stale),
      );
    },
  );

  test(
    'actual batch grouping never combines distinct native source scopes',
    () async {
      final f = NativeSourceConsumerFixture();
      await f.wire.store(purposes: {NativeProviderPurpose.studio});
      final first = await f.prepare(purpose: NativeProviderPurpose.studio);
      final second = await f.prepare(purpose: NativeProviderPurpose.studio);
      final runner = _ScopedRunner(_resolver(f), {
        'a': ResolvedAgentConfig.fromApiConfig(
          first.configuration,
          nativeSource: first,
        ),
        'b': ResolvedAgentConfig.fromApiConfig(
          second.configuration,
          nativeSource: second,
        ),
      });
      final groups = await ControllerBatcher(runner).groupAgents(
        agents: const [
          StudioAgent(id: 'a'),
          StudioAgent(id: 'b'),
        ],
        apiConfig: first.configuration,
        sessionId: 'session',
      );
      expect(groups.batchGroups.length, 2);
      expect(
        groups.batchGroups.map((group) => group.resolved.nativeSource),
        containsAll([first, second]),
      );
      expect(f.wire.wires, isEmpty);
    },
  );

  test('unrelated Aux domain cannot borrow a Studio native auth', () async {
    final f = NativeSourceConsumerFixture();
    await f.wire.store(purposes: {NativeProviderPurpose.studio});
    final source = await f.prepare(purpose: NativeProviderPurpose.studio);
    final llm = AuxLlmClient(
      sources: f.sources,
      transportPicker: f.wire.factory.pick,
    );
    await expectLater(
      llm.callOnce(
        config: _aux(source),
        prompt: 'Synthetic prompt',
        maxTokens: 100,
        temperature: 0.2,
        timeoutMs: 60000,
      ),
      throwsNative(NativeProviderFailure.denied),
    );
    expect(f.wire.wires, isEmpty);
  });

  test(
    'native Aux is single-attempt even on a provider retry status',
    () async {
      final f = NativeSourceConsumerFixture();
      await f.wire.store(purposes: {NativeProviderPurpose.memoryBooks});
      final source = await f.prepare(
        purpose: NativeProviderPurpose.memoryBooks,
      );
      f.wire.status = 503;
      final llm = AuxLlmClient(
        sources: f.sources,
        purpose: NativeProviderPurpose.memoryBooks,
        transportPicker: f.wire.factory.pick,
      );
      final result = await llm.callOnceWithLog(
        config: _aux(source),
        prompt: 'Synthetic prompt',
        maxTokens: 100,
        temperature: 0.2,
        timeoutMs: 60000,
      );
      expect(result.isOk, isFalse);
      expect(result.attempts.length, 1);
      expect(f.wire.wires.length, 1);
    },
  );

  test(
    'actual Aux missing native auth cannot use a legacy row key fallback',
    () async {
      final f = NativeSourceConsumerFixture();
      await f.wire.store(purposes: {NativeProviderPurpose.memoryBooks});
      final llm = AuxLlmClient(
        sources: f.sources,
        purpose: NativeProviderPurpose.memoryBooks,
        transportPicker: f.wire.factory.pick,
      );
      await expectLater(
        llm.callOnce(
          config: AuxApiConfig(
            savedConnectionId: f.repo.row.id,
            endpoint: f.repo.row.endpoint,
            model: f.repo.row.model,
            protocol: f.repo.row.protocol,
            apiKey: 'SYNTHETIC_LEGACY_FALLBACK',
          ),
          prompt: 'Synthetic prompt',
          maxTokens: 100,
          temperature: 0.2,
          timeoutMs: 60000,
        ),
        throwsNative(NativeProviderFailure.denied),
      );
      expect(f.wire.wires, isEmpty);
      expect(f.wire.legacy.requests, isEmpty);
    },
  );

  test('actual legacy Aux preserves original key and model override', () async {
    final f = NativeSourceConsumerFixture(
      row: const ApiConfig(
        id: 'legacy',
        apiKey: 'SYNTHETIC_LEGACY_KEY',
        model: 'original',
        endpoint: 'https://legacy.invalid/v1/chat/completions',
      ),
    );
    final source = await f.prepare(purpose: NativeProviderPurpose.memoryBooks);
    final resolved = ResolvedAgentConfig.fromApiConfig(
      source.configuration,
      nativeSource: source,
      modelOverride: 'legacy-user-override',
    );
    expect(resolved.model, 'legacy-user-override');
    expect(resolved.apiKey, 'SYNTHETIC_LEGACY_KEY');
    final llm = AuxLlmClient(
      sources: f.sources,
      purpose: NativeProviderPurpose.memoryBooks,
      transportPicker: f.wire.factory.pick,
    );
    final result = await llm.callOnce(
      config: _aux(source),
      prompt: 'Synthetic prompt',
      maxTokens: 100,
      temperature: 0.2,
      timeoutMs: 60000,
    );
    expect(result, 'legacy');
    expect(f.wire.legacy.requests.single.apiKey, 'SYNTHETIC_LEGACY_KEY');
    expect(f.wire.legacy.requests.single.nativeSourceIsCurrent, isNull);
    expect(f.wire.wires, isEmpty);
  });
}

final class _ScopedRunner extends AgentRunner {
  _ScopedRunner(AgentConfigResolver resolver, this.configs)
    : super(
        configResolver: resolver,
        readPipelineSettings: () => const PipelineSettings(),
        transportPicker: (_) => throw StateError('Grouping must not dispatch'),
      );
  final Map<String, ResolvedAgentConfig> configs;
  @override
  Future<ResolvedAgentConfig> resolveAgentConfig(
    StudioAgent agent,
    ApiConfig current,
    String sessionId, {
    bool isFinalResponse = false,
    String? apiConfigId,
    StudioTurnConfigSnapshot? turnConfig,
  }) async => configs[agent.id]!;
}
