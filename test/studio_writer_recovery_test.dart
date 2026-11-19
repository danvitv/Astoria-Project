import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/llm/agent_runner.dart';
import 'package:glaze_flutter/core/llm/generation_context_inputs.dart';
import 'package:glaze_flutter/core/llm/generation_phase.dart';
import 'package:glaze_flutter/core/llm/memory_selector.dart';
import 'package:glaze_flutter/core/llm/prompt_payload_builder.dart';
import 'package:glaze_flutter/core/llm/prompt_worker.dart';
import 'package:glaze_flutter/core/llm/studio/agent_config_resolver.dart';
import 'package:glaze_flutter/core/llm/studio/studio_context_preparer.dart';
import 'package:glaze_flutter/core/llm/studio/studio_writer_checkpoint.dart';
import 'package:glaze_flutter/core/llm/studio_stage_brief.dart';
import 'package:glaze_flutter/core/llm/studio_turn_config_snapshot.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/pipeline_settings.dart';
import 'package:glaze_flutter/core/models/studio_agent_settings.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/memory_agent_providers.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/providers/prompt_build_providers.dart';
import 'package:glaze_flutter/features/chat/services/stream_generation_service.dart';
import 'package:glaze_flutter/features/chat/services/studio_writer_pending.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _audit = '<audit>The brass key is still in her pocket.</audit>';
const _seed = '<thinking>\nThe brass key is still in her pocket.\n</thinking>';
const _thinkNative = 'Check the scene facts before writing the audit.';
const _writerNative = 'Open with an action.';
const _prose = 'She took the brass key from her pocket.';
const _writerFailure = 'Synthetic writer transport failure';
const _guidance = 'Keep the reply short.';
const _character = Character(id: 'character', name: 'Mara');
const _session = ChatSession(
  id: 'studio-test-session',
  characterId: 'character',
  sessionIndex: 0,
  messages: [
    ChatMessage(id: 'prompt', role: 'user', content: 'Open the gate.'),
  ],
);
const _config = StudioConfig(sessionId: 'studio-test-session', enabled: true);
const _thinkApi = ApiConfig(
  id: 'think-api',
  endpoint: 'https://example.invalid',
  model: 'think-model',
  requestReasoning: true,
);
const _writerApi = ApiConfig(
  id: 'writer-api',
  endpoint: 'https://example.invalid',
  model: 'writer-model',
  requestReasoning: true,
);
const _repairedWriterApi = ApiConfig(
  id: 'replacement-writer-api',
  endpoint: 'https://replacement.example.invalid',
  model: 'replacement-writer-model',
  requestReasoning: true,
);
const _postApi = ApiConfig(
  id: 'post-api',
  endpoint: 'https://example.invalid',
  model: 'post-model',
);
const _think = StudioAgent(
  id: 'think',
  specId: 'think',
  name: 'Think',
  reasoningMode: 'think-replacement',
);
const _writer = StudioAgent(
  id: 'writer',
  specId: 'final',
  name: 'Main Writer',
  order: 1,
);
const _thinkPrompt = StudioPresetBlock(
  id: 'think-prompt',
  injectionPoint: 'specificAgent',
  targetAgentId: 'think',
  content: 'Audit the current scene before writing.',
);
const _preset = StudioPreset(
  id: 'recovery-preset',
  cheapApiConfigId: 'think-api',
  expensiveApiConfigId: 'writer-api',
  cleanerApiConfigId: 'post-api',
  agentEnabled: {'post_clean': false},
  blocks: [
    StudioPresetBlock(
      id: 'history',
      type: StudioBlockType.history,
      section: 'final',
      injectionPoint: 'final',
    ),
    _thinkPrompt,
  ],
  agents: [
    _think,
    _writer,
    // A Studio post tracker is distinct from the downstream Post Clean stage.
    StudioAgent(id: 'review', order: 2, phase: 'post_processing'),
  ],
);
final _refProvider = Provider<Ref>((ref) => ref);

StudioTurnConfigSnapshot _turn([StudioPreset preset = _preset]) =>
    StudioTurnConfigSnapshot(
      config: _config,
      preset: preset,
      pipelineSettings: const PipelineSettings(
        studioAgent: StudioAgentSettings(
          studioControllerRequestReasoningOverride: false,
          studioFinalRequestReasoningOverride: false,
        ),
      ),
      apiConfigs: const [_thinkApi, _writerApi, _repairedWriterApi, _postApi],
      activeApiConfig: _writerApi,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'writer failure saves Think and retry only dispatches the writer',
    () async {
      final worker = await PromptWorker.ensureInitialized();
      addTearDown(worker.dispose);
      final transport = _RecoveryTransport();
      final f = _Fixture(transport);
      final repo = f.container.read(chatRepoProvider);
      await repo.put(_session);

      String? pendingWhenWriterDispatched;
      transport.beforeFirstWriter = () async {
        final durable = await repo.getById(_session.id);
        pendingWhenWriterDispatched =
            durable?.sessionVars[StudioWriterCheckpoint.pendingSessionKey];
      };

      final turn = _turn();
      expect(turn.pipelineSettings.cleaner.postCleanerEnabled, isFalse);
      final failed = await f.generate(turn: turn, guidanceText: _guidance);
      expect(transport.models, [_thinkApi.model, _writerApi.model]);
      expect(
        jsonEncode(transport.requests.first.messages),
        contains(_thinkPrompt.content),
      );
      expect(failed.session!.messages.length, _session.messages.length + 1);
      final error = failed.session!.messages.last;
      expect(error.isError, isTrue);
      expect(error.content, contains(_writerFailure));
      expect(error.reasoning, allOf(contains(_seed), contains(_thinkNative)));
      expect(error.studioOutputs.single['content'], _audit);
      expect(error.guidanceText, _guidance);

      final saved = (await repo.commitGenerationResult(
        baseSession: _session,
        generatedSession: failed.session!,
        regenTargetId: null,
        sessionVarKeysToRemove: {
          StudioWriterCheckpoint.pendingSessionKey: (raw) =>
              StudioWriterPending.owns(raw, 'test-writer-1'),
        },
      ))!;
      final savedError = saved.messages.last;
      final checkpoint = StudioWriterCheckpoint.forMessage(savedError)!;
      expect(checkpoint.phaseInputs, isNotEmpty);
      expect(checkpoint.briefs.single.isThinkReplacement, isTrue);
      expect(checkpoint.briefs.single.brief, _audit);
      expect(checkpoint.briefs.single.nativeReasoning, _thinkNative);
      expect(pendingWhenWriterDispatched, isNotNull);
      expect(
        jsonDecode(pendingWhenWriterDispatched!)['checkpoint'],
        checkpoint.toJson(),
      );

      final staleSource = await f.generate(
        turn: turn,
        retryFrom: saved,
        guidanceText: 'Changed guidance',
      );
      expect(staleSource.error, isNotNull);
      expect(staleSource.session, saved);

      final staleTopology = await f.generate(
        turn: _turn(_preset.copyWith(agents: [_writer])),
        retryFrom: saved,
        guidanceText: savedError.guidanceText,
      );
      expect(staleTopology.error, isNotNull);
      expect(staleTopology.session, saved);

      final staleThinkPrompt = await f.generate(
        turn: _turn(
          _preset.copyWith(
            blocks: [
              _preset.blocks.first,
              _thinkPrompt.copyWith(
                content: 'Audit only the character dialogue.',
              ),
            ],
          ),
        ),
        retryFrom: saved,
        guidanceText: savedError.guidanceText,
      );
      expect(staleThinkPrompt.error, isNotNull);
      expect(staleThinkPrompt.session, saved);
      expect(transport.models, [_thinkApi.model, _writerApi.model]);

      final retried = await f.generate(
        turn: _turn(
          _preset.copyWith(expensiveApiConfigId: _repairedWriterApi.id),
        ),
        retryFrom: saved,
        guidanceText: savedError.guidanceText,
      );
      expect(retried.error, isNull);
      expect(transport.models, [
        _thinkApi.model,
        _writerApi.model,
        _repairedWriterApi.model,
      ]);
      expect(transport.requests.last.endpoint, _repairedWriterApi.endpoint);
      for (final request in transport.requests.skip(1)) {
        final seed = request.messages[request.messages.length - 2];
        expect(seed, {'role': 'assistant', 'content': _seed});
        expect(request.messages.last['role'], 'user');
        expect(
          jsonEncode(request.messages),
          allOf(contains('Open the gate.'), isNot(contains(_thinkNative))),
        );
      }
      expect(transport.requests.last.messages, transport.requests[1].messages);

      final recovered = (await repo.commitGenerationResult(
        baseSession: saved,
        generatedSession: retried.session!,
        regenTargetId: savedError.id,
      ))!;
      final reply = recovered.messages.last;
      expect(recovered.messages.length, saved.messages.length);
      expect(reply.id, savedError.id);
      expect(reply.isError, isFalse);
      expect(reply.content, _prose);
      expect(reply.swipeId, savedError.swipeId);
      expect(reply.swipes, [_prose]);
      expect(reply.agentSwipes.single.content, _prose);
      expect(reply.studioOutputs.single['content'], _audit);
      expect(
        StudioWriterCheckpoint.forMessage(reply)?.toJson(),
        checkpoint.toJson(),
      );
      expect(
        reply.reasoning,
        allOf(contains(_seed), contains(_thinkNative), contains(_writerNative)),
      );
    },
  );

  test(
    'cancel while awaiting the completed pregen callback never starts writer',
    () async {
      final transport = _RecoveryTransport();
      final f = _Fixture(transport);
      final service = f.container.read(memoryStudioServiceProvider);
      final inputs = _inputs(_session);
      final context = const StudioContextPreparer().prepare(
        inputs: inputs,
        visibleMessageIds: {'prompt'},
      );
      final token = CancelToken();
      final entered = Completer<List<StudioStageBrief>>();
      final release = Completer<void>();
      var writerStarted = false;
      final run = service.runTrackerCycle(
        config: _config,
        inputs: inputs,
        trackerContext: context,
        finalContext: context,
        apiConfig: _writerApi,
        sessionId: _session.id,
        turnConfig: _turn(),
        cancelToken: token,
        onFinalStart: () => writerStarted = true,
        onPregenCompleted: (_, briefs) async {
          entered.complete(briefs);
          await release.future;
        },
      );
      try {
        final briefs = await Future.any<List<StudioStageBrief>>([
          entered.future,
          run.then<List<StudioStageBrief>>(
            (result) =>
                throw StateError('Cycle exited before pregen: ${result.error}'),
          ),
        ]);
        expect(briefs.single.brief, _audit);
        expect(briefs.single.nativeReasoning, _thinkNative);
        expect(writerStarted, isFalse);
        token.cancel('Cancelled during pregen handoff');
      } finally {
        if (!token.isCancelled) token.cancel();
        release.complete();
      }
      expect((await run).status, 'aborted');
      expect(writerStarted, isFalse);
      expect(transport.models, [_thinkApi.model]);
    },
  );

  test('full regeneration retry reproduces its context projection', () async {
    final worker = await PromptWorker.ensureInitialized();
    addTearDown(worker.dispose);
    final transport = _RecoveryTransport();
    final f = _Fixture(transport);
    const replaced = ChatMessage(
      id: 'replaced',
      role: 'assistant',
      content: 'Old response.',
    );
    final base = _session.copyWith(messages: [..._session.messages, replaced]);
    await f.container.read(chatRepoProvider).put(base);

    final failed = await f.generateFullRegen(
      turn: _turn(),
      base: base,
      guidanceText: _guidance,
    );
    final checkpoint = StudioWriterCheckpoint.forMessage(
      failed.session!.messages.last,
    )!;
    expect(checkpoint.excludeSnapshotMessageId, replaced.id);

    final retried = await f.generate(
      turn: _turn(
        _preset.copyWith(expensiveApiConfigId: _repairedWriterApi.id),
      ),
      retryFrom: failed.session,
      guidanceText: _guidance,
    );
    expect(retried.error, isNull);
    expect(f.builder.excludeSnapshotMessageIds, [replaced.id, replaced.id]);
    expect(transport.models, [
      _thinkApi.model,
      _writerApi.model,
      _repairedWriterApi.model,
    ]);
  });
}

class _Fixture {
  _Fixture(_RecoveryTransport transport) {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        nativeProviderRuntimeProvider.overrideWithValue(null),
        chatProvider(_character.id).overrideWith(_Chat.new),
        promptPayloadBuilderProvider.overrideWithValue(builder),
        agentRunnerProvider.overrideWithValue(
          AgentRunner(
            configResolver: AgentConfigResolver(
              loadApiConfigs: () async => throw StateError('Use turn snapshot'),
              readActiveApiConfig: () => _writerApi,
              readPipelineSettings: () => const PipelineSettings(),
            ),
            readPipelineSettings: () => const PipelineSettings(),
            transportPicker: (_) => transport,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
  }

  late final ProviderContainer container;
  final builder = _InputsBuilder();
  int _nextGen = 0;

  Future<ChatState> generate({
    required StudioTurnConfigSnapshot turn,
    ChatSession? retryFrom,
    String? guidanceText,
  }) {
    return StreamGenerationService(
      ref: container.read(_refProvider),
      charId: _character.id,
      genId: ++_nextGen,
      isAborted: () => false,
      transportPicker: (_) => throw StateError('Use Studio transport'),
    ).run(
      session: retryFrom == null
          ? _session
          : retryFrom.copyWith(
              messages: retryFrom.messages.sublist(
                0,
                retryFrom.messages.length - 1,
              ),
            ),
      saveSession: retryFrom,
      regenTargetId: retryFrom?.messages.last.id,
      studioFinalOnly: retryFrom != null,
      guidanceText: guidanceText,
      currentState: ChatState(
        session: retryFrom ?? _session,
        isGenerating: true,
      ),
      studioTurnConfig: turn,
    );
  }

  Future<ChatState> generateFullRegen({
    required StudioTurnConfigSnapshot turn,
    required ChatSession base,
    String? guidanceText,
  }) {
    final target = base.messages.last;
    return StreamGenerationService(
      ref: container.read(_refProvider),
      charId: _character.id,
      genId: ++_nextGen,
      isAborted: () => false,
      transportPicker: (_) => throw StateError('Use Studio transport'),
    ).run(
      session: base.copyWith(
        messages: base.messages.take(base.messages.length - 1).toList(),
      ),
      saveSession: base,
      regenTargetId: target.id,
      guidanceText: guidanceText,
      currentState: ChatState(session: base, isGenerating: true),
      studioTurnConfig: turn,
    );
  }
}

class _Chat extends ChatNotifier {
  _Chat() : super(_character.id);

  @override
  Future<ChatState> build() async => const ChatState(session: _session);

  @override
  void setCancelToken(CancelToken token, {required int genId}) {}

  @override
  String? studioWriterPendingOwnerFor(int genId) => 'test-writer-$genId';
}

GenerationContextInputs _inputs(ChatSession session, {String? guidanceText}) =>
    GenerationContextInputs(
      character: _character,
      history: session.messages,
      sessionId: session.id,
      apiConfig: _writerApi,
      sessionVars: session.sessionVars,
      guidanceText: guidanceText,
    );

class _InputsBuilder implements PromptPayloadBuilder {
  final excludeSnapshotMessageIds = <String?>[];

  @override
  Future<GenerationContextInputs> collectGenerationContext({
    required String charId,
    required ChatSession? session,
    ApiConfig? apiConfigOverride,
    String? guidanceText,
    String? continueInstruction,
    bool skipVectorSearch = false,
    bool includeEffectiveCanon = false,
    bool readOnlyEffectiveCanon = false,
    String? excludeSnapshotMessageId,
    bool allowRemoteRetrieval = true,
    bool Function()? shouldAbort,
    CancelToken? cancelToken,
    void Function(GenerationPhase)? onPhase,
  }) async {
    excludeSnapshotMessageIds.add(excludeSnapshotMessageId);
    return _inputs(session!, guidanceText: guidanceText);
  }

  @override
  Future<void> ensureMemoryEntriesCurrent({
    required String sessionId,
    required MemorySelection? selection,
    required Iterable<TriggeredEntry> triggered,
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecoveryTransport implements ChatTransport {
  final requests = <ChatTransportRequest>[];
  Iterable<String> get models => requests.map((request) => request.model);
  Future<void> Function()? beforeFirstWriter;

  @override
  Future<void> stream({
    required ChatTransportRequest request,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
    ChatTransportOnError? onError,
  }) async {
    requests.add(request);
    if (request.model == _thinkApi.model) {
      onComplete?.call(_audit, _thinkNative);
    } else if (request.model == _writerApi.model) {
      await beforeFirstWriter?.call();
      onError?.call(StateError(_writerFailure));
    } else if (request.model == _repairedWriterApi.model) {
      onComplete?.call(_prose, _writerNative);
    } else {
      onError?.call(StateError('Unexpected model: ${request.model}'));
    }
  }

  @override
  Future<List<Map<String, dynamic>>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) async => throw StateError('Not used by generation');
}
