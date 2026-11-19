import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/llm/studio_turn_config_snapshot.dart';
import 'package:glaze_flutter/core/llm/studio/studio_writer_checkpoint.dart';
import 'package:glaze_flutter/core/llm/studio_stage_brief.dart';
import 'package:glaze_flutter/core/llm/generation_phase.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/pipeline_settings.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/studio_turn_config_resolver.dart';
import 'package:glaze_flutter/features/chat/chat_generation_service.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/chat_session_service.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/services/studio_writer_pending.dart';
import 'package:glaze_flutter/features/chat/state/generation_phase_provider.dart';

const _guidance = 'Use the saved instruction';

void _expectSameSession(ChatSession? actual, ChatSession expected) {
  expect(jsonEncode(actual), jsonEncode(expected));
}

const _target = ChatMessage(
  id: 'assistant',
  role: 'assistant',
  content: 'Selected final',
  reasoning: '<thinking>Completed Think phase</thinking>',
  timestamp: 2,
  swipes: ['Sibling final', 'Selected final'],
  swipeId: 1,
  guidanceText: _guidance,
  guidanceType: 'SWIPE',
  swipesMeta: [
    {'guidanceText': 'Sibling instruction', 'guidanceType': 'SWIPE'},
    {'guidanceText': _guidance, 'guidanceType': 'SWIPE'},
  ],
);
const _session = ChatSession(
  id: 's1',
  characterId: 'c1',
  sessionIndex: 0,
  sessionVars: {'accepted': 'original'},
  messages: [
    ChatMessage(id: 'user', role: 'user', content: 'Hello', timestamp: 1),
    _target,
  ],
);
const _wait = Duration(seconds: 10);

class _WriterRequest {
  const _WriterRequest({
    required this.prompt,
    required this.saved,
    required this.optimistic,
    required this.finalOnly,
    required this.targetId,
    required this.guidance,
    required this.guidanceType,
    required this.isAborted,
    required this.publish,
  });

  final ChatSession prompt;
  final ChatSession? saved;
  final ChatState optimistic;
  final bool finalOnly;
  final String? targetId;
  final String? guidance;
  final String guidanceType;
  final bool Function() isAborted;
  final void Function(ChatState) publish;
}

class _ControlledWriterService extends ChatGenerationService {
  _ControlledWriterService(super.ref);

  final entered = Completer<_WriterRequest>();
  final result = Completer<ChatState>();
  int calls = 0;

  @override
  Future<ChatState> generate({
    required ChatSession session,
    ChatSession? saveSession,
    required String charId,
    required int genId,
    required ChatState currentState,
    required void Function(ChatState) onStateUpdate,
    required bool Function() isAborted,
    List<String>? previousSwipes,
    int previousSwipeId = 0,
    String? previousReasoning,
    String? previousGenTime,
    int? previousTokens,
    List<Map<String, dynamic>>? previousSwipesMeta,
    String? guidanceText,
    String guidanceType = 'GENERATION',
    String? regenTargetId,
    String? continueTargetId,
    bool studioFinalOnly = false,
    StudioTurnConfigSnapshot? studioTurnConfig,
  }) async {
    calls++;
    entered.complete(
      _WriterRequest(
        prompt: session,
        saved: saveSession,
        optimistic: currentState,
        finalOnly: studioFinalOnly,
        targetId: regenTargetId,
        guidance: guidanceText,
        guidanceType: guidanceType,
        isAborted: isAborted,
        publish: onStateUpdate,
      ),
    );
    return result.future;
  }
}

// Intentionally bypass the pure writer's abort guard: the notifier/pipeline
// must reject a late transport result even when the fake does not cooperate.
ChatState _unwantedResult({String? error}) => ChatState(
  session: _session.copyWith(
    sessionVars: const {'accepted': 'must not persist'},
    messages: [
      _session.messages.first,
      _target.copyWith(
        content: 'Late replacement',
        swipes: ['Late replacement'],
      ),
    ],
  ),
  regenTargetId: _target.id,
  error: error,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late ProviderContainer container;
  late _ControlledWriterService service;

  Future<ChatNotifier> setUpChat({
    Future<void> Function()? loadApiConfigs,
  }) async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    // A real resolver with one runnable writer avoids ordinary prompt-budget
    // assembly. No provider, cleaner route, or network configuration is needed.
    final resolver = StudioTurnConfigResolver(
      readPipelineSettings: () => const PipelineSettings(),
      readStudioFeatureEnabled: () => true,
      loadApiConfigs: loadApiConfigs ?? () async {},
      readApiConfigs: () => const [],
      readActiveApiConfig: () => null,
      loadActivePresetId: () async => 'test',
      loadPreset: (_) async => const StudioPreset(
        id: 'test',
        agents: [StudioAgent(id: 'writer', controllerId: 'final')],
      ),
      loadDefaultPreset: () async => null,
    );
    container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        studioTurnConfigResolverProvider.overrideWithValue(resolver),
        chatGenerationServiceProvider.overrideWith(
          _ControlledWriterService.new,
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      ChatSessionService.clearCache();
      await db.close();
    });
    await container
        .read(characterRepoProvider)
        .put(const Character(id: 'c1', name: 'Alice'));
    await container.read(chatRepoProvider).put(_session);
    await container.read(chatProvider('c1').future);
    service =
        container.read(chatGenerationServiceProvider)
            as _ControlledWriterService;
    return container.read(chatProvider('c1').notifier);
  }

  test('Writer-only error keeps the outer and durable target intact', () async {
    final notifier = await setUpChat();
    final before = (await container.read(chatRepoProvider).getById('s1'))!;
    final run = notifier.regenerateLastAssistant(
      studioFinalOnly: true,
      expectedMessageId: _target.id,
      guidanceText: 'Do not replace the saved guidance',
    );
    final request = await service.entered.future.timeout(_wait);
    expect(request.finalOnly, isTrue);
    expect(request.targetId, _target.id);
    expect(request.prompt.messages, [before.messages.first]);
    _expectSameSession(request.saved, before);
    expect(request.saved!.messages.last.swipeId, _target.swipeId);
    expect(request.saved!.messages.last.swipes, _target.swipes);
    expect(request.guidance, _guidance);
    expect(request.guidanceType, 'SWIPE');

    final optimistic = container.read(chatProvider('c1')).requireValue;
    expect(optimistic, request.optimistic);
    expect(optimistic.isGenerating, isTrue);
    expect(optimistic.regenTargetId, _target.id);
    expect(optimistic.messages.map((m) => m.id), ['user', _target.id]);
    expect(optimistic.messages.last.swipes, _target.swipes);
    expect(optimistic.messages.last.swipeId, _target.swipeId);
    expect(optimistic.messages.last.swipesMeta, hasLength(2));
    expect(optimistic.messages.last.swipesMeta.first, _target.swipesMeta.first);
    expect(optimistic.messages.last.swipesMeta.last['guidanceText'], _guidance);
    expect(
      optimistic.messages.last.swipesMeta.last['agentSwipes'],
      hasLength(1),
    );
    expect(optimistic.messages.last.guidanceText, _guidance);
    expect(optimistic.messages.last.reasoning, _target.reasoning);
    expect(optimistic.messages.last.isTyping, isTrue);
    expect(
      container.read(generationPhaseProvider('c1')),
      GenerationPhase.writer,
    );
    _expectSameSession(
      await container.read(chatRepoProvider).getById('s1'),
      before,
    );

    service.result.complete(
      _unwantedResult(error: 'Controlled Writer failure'),
    );
    await run.timeout(_wait);
    final settled = container.read(chatProvider('c1')).requireValue;
    _expectSameSession(settled.session, before);
    expect(settled.isGenerating, isFalse);
    expect(settled.regenTargetId, isNull);
    expect(settled.error, 'Controlled Writer failure');
    _expectSameSession(
      await container.read(chatRepoProvider).getById('s1'),
      before,
    );
  });

  test('Stop rejects late Writer text and a late state callback', () async {
    final notifier = await setUpChat();
    final before = (await container.read(chatRepoProvider).getById('s1'))!;
    final run = notifier.regenerateLastAssistant(
      studioFinalOnly: true,
      expectedMessageId: _target.id,
    );
    final request = await service.entered.future.timeout(_wait);
    container.read(streamingStateProvider('c1').notifier).state =
        const StreamingState(text: 'Partial Writer replacement');
    await notifier.abortGeneration().timeout(_wait);
    expect(request.isAborted(), isTrue);
    _expectSameSession(
      container.read(chatProvider('c1')).requireValue.session,
      before,
    );
    _expectSameSession(
      await container.read(chatRepoProvider).getById('s1'),
      before,
    );

    request.publish(_unwantedResult());
    service.result.complete(_unwantedResult());
    await run.timeout(_wait);
    final settled = container.read(chatProvider('c1')).requireValue;
    _expectSameSession(settled.session, before);
    expect(settled.isGenerating, isFalse);
    expect(settled.regenTargetId, isNull);
    _expectSameSession(
      await container.read(chatRepoProvider).getById('s1'),
      before,
    );
  });

  test('a mismatched expected message never starts the Writer', () async {
    final notifier = await setUpChat();
    final before = container.read(chatProvider('c1')).requireValue;
    await notifier
        .regenerateLastAssistant(
          studioFinalOnly: true,
          expectedMessageId: 'not-the-target',
        )
        .timeout(_wait);
    expect(service.calls, 0);
    final after = container.read(chatProvider('c1')).requireValue;
    _expectSameSession(after.session, before.session!);
    expect(after.isGenerating, before.isGenerating);
    _expectSameSession(
      await container.read(chatRepoProvider).getById('s1'),
      before.session!,
    );
  });

  test(
    'switching outer during budget preflight retires the requested target',
    () async {
      final preflightEntered = Completer<void>();
      final releasePreflight = Completer<void>();
      final notifier = await setUpChat(
        loadApiConfigs: () async {
          if (!preflightEntered.isCompleted) preflightEntered.complete();
          await releasePreflight.future;
        },
      );
      final run = notifier.regenerateLastAssistant(
        studioFinalOnly: true,
        expectedMessageId: _target.id,
      );
      await preflightEntered.future.timeout(_wait);
      // Still idle in preflight: use the real notifier's variation selection.
      await notifier.setSwipe(1, 0).timeout(_wait);
      final switched = container.read(chatProvider('c1')).requireValue;
      expect(switched.messages.last.id, _target.id);
      expect(switched.messages.last.swipeId, 0);
      expect(switched.messages.last.content, 'Sibling final');
      releasePreflight.complete();
      await run.timeout(_wait);

      expect(service.calls, 0);
      final settled = container.read(chatProvider('c1')).requireValue;
      expect(settled.messages.last.swipeId, 0);
      expect(settled.messages.last.content, 'Sibling final');
      expect(settled.isGenerating, isFalse);
      final durable = await container.read(chatRepoProvider).getById('s1');
      expect(durable?.messages.last.swipeId, 0);
      expect(durable?.messages.last.swipes, _target.swipes);
    },
  );

  test(
    'session selection recovers a pending phase absent from cache',
    () async {
      final notifier = await setUpChat();
      final repo = container.read(chatRepoProvider);
      const other = ChatSession(
        id: 's2',
        characterId: 'c1',
        sessionIndex: 1,
        messages: [ChatMessage(id: 'other', role: 'user', content: 'Other')],
      );
      await repo.put(other);
      final checkpoint = StudioWriterCheckpoint(
        presetId: 'test',
        source: StudioWriterCheckpoint.sourceFor(_session, null),
        phaseInputs: 'phase',
        briefs: const [
          StudioStageBrief(
            agentId: 'think',
            agentName: 'Think',
            brief: '<audit>Saved phase</audit>',
            isThinkReplacement: true,
          ),
        ],
      );
      final pending = StudioWriterPending.capture(
        ownerId: 'orphan',
        baseSession: _session,
        targetId: null,
        guidanceText: null,
        guidanceType: 'GENERATION',
        checkpoint: checkpoint,
      )!;
      await repo.mutateSession(
        sessionId: _session.id,
        mutate: (latest) => latest.copyWith(
          sessionVars: {
            ...latest.sessionVars,
            StudioWriterCheckpoint.pendingSessionKey: pending.encode(),
          },
        ),
      );
      // The notifier still holds the pre-persistence cache snapshot.
      expect(
        container
            .read(chatProvider('c1'))
            .requireValue
            .session
            ?.sessionVars
            .containsKey(StudioWriterCheckpoint.pendingSessionKey),
        isFalse,
      );

      await notifier.switchSession(1);
      await notifier.switchSession(0);

      final selected = container.read(chatProvider('c1')).requireValue.session!;
      expect(selected.id, _session.id);
      expect(
        selected.sessionVars.containsKey(
          StudioWriterCheckpoint.pendingSessionKey,
        ),
        isFalse,
      );
      expect(selected.messages.last.isError, isTrue);
      expect(
        StudioWriterCheckpoint.forMessage(selected.messages.last),
        isNotNull,
      );
      final durable = await repo.getById(_session.id);
      expect(durable?.messages.last.isError, isTrue);
    },
  );
}
