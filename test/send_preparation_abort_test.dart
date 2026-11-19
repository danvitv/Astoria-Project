import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/lorebook_use_manifest_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_snapshot_repo.dart';
import 'package:glaze_flutter/core/llm/studio_turn_config_snapshot.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/tracker_snapshot.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/memory_settings_provider.dart';
import 'package:glaze_flutter/features/chat/chat_generation_service.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/chat_session_service.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/settings/api_list_provider.dart';

class _Gate {
  final entered = Completer<void>();
  final release = Completer<void>();
  bool armed = false;
  int skip = 0;

  Future<void> wait() async {
    if (!armed) return;
    if (skip > 0) {
      skip--;
      return;
    }
    armed = false;
    entered.complete();
    await release.future;
  }
}

class _DelayedSnapshots extends TrackerSnapshotRepo {
  _DelayedSnapshots(super.db, this.gate);
  final _Gate gate;

  @override
  Future<TrackerSnapshot?> getByAnchor({
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
  }) async {
    await gate.wait();
    return super.getByAnchor(
      sessionId: sessionId,
      messageId: messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
    );
  }
}

class _DelayedCharacter extends CharacterRepo {
  _DelayedCharacter(super.db, this.gate);
  final _Gate gate;

  @override
  Future<Character?> getById(String id) async {
    await gate.wait();
    return super.getById(id);
  }
}

class _DelayedAppend extends ChatRepo {
  _DelayedAppend(super.db, this.gate);
  final _Gate gate;

  @override
  Future<ChatSession?> appendUserMessageAndAcceptCurrentVariation({
    required String sessionId,
    required ChatMessage message,
    required LorebookUseGenerationIdentity expectedPrecedingAssistant,
    required int updatedAt,
  }) async {
    await gate.wait();
    return super.appendUserMessageAndAcceptCurrentVariation(
      sessionId: sessionId,
      message: message,
      expectedPrecedingAssistant: expectedPrecedingAssistant,
      updatedAt: updatedAt,
    );
  }
}

class _ParkedGeneration extends ChatGenerationService {
  _ParkedGeneration(super.ref);
  final entered = Completer<void>();
  final release = Completer<void>();
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
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return ChatState(
      session: session.copyWith(
        messages: [
          ...session.messages,
          const ChatMessage(id: 'reply', role: 'assistant', content: 'Reply'),
        ],
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final action in ['send', 'regenerate', 'continue', 'stop-preflight']) {
    test(
      'context preflight $action preserves durable transcript and draft',
      () async {
        SharedPreferences.setMockInitialValues({});
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        final gate = _Gate();
        late _ParkedGeneration generation;
        final container = ProviderContainer(
          overrides: [
            appDbProvider.overrideWithValue(db),
            // This fixture exercises chat preflight, not OS credential storage.
            apiConfigRepoProvider.overrideWithValue(ApiConfigRepo(db)),
            characterRepoProvider.overrideWithValue(
              _DelayedCharacter(db, gate),
            ),
            chatGenerationServiceProvider.overrideWith(
              (ref) => generation = _ParkedGeneration(ref),
            ),
          ],
        );
        container.read(chatGenerationServiceProvider);
        addTearDown(() async {
          if (!gate.release.isCompleted) gate.release.complete();
          if (!generation.release.isCompleted) generation.release.complete();
          container.dispose();
          ChatSessionService.clearCache();
          await db.close();
        });
        await container
            .read(characterRepoProvider)
            .put(const Character(id: 'c', name: 'Alice'));
        await container
            .read(apiConfigRepoProvider)
            .put(
              const ApiConfig(
                id: 'api',
                endpoint: 'https://example.test/v1',
                apiKey: 'fake',
                model: 'test',
                contextSize: 16,
                maxTokens: 16,
              ),
            );
        await container.read(apiListProvider.future);
        const session = ChatSession(
          id: 's',
          characterId: 'c',
          sessionIndex: 0,
          draft: 'unsent draft',
          messages: [ChatMessage(id: 'a', role: 'assistant', content: 'Hi')],
        );
        await container.read(chatRepoProvider).put(session);
        await container.read(chatProvider('c').future);
        final notifier = container.read(chatProvider('c').notifier);
        if (action == 'stop-preflight') {
          gate.armed = true;
          final pending = notifier.trySendMessage('new message');
          await gate.entered.future;
          await notifier.abortGeneration();
          gate.release.complete();
          expect(await pending, isFalse);
        } else if (action == 'send') {
          expect(
            await notifier.trySendMessage(
              'new message',
              imageDataUrls: ['attachment'],
            ),
            isFalse,
          );
        } else if (action == 'regenerate') {
          await notifier.regenerateLastAssistant();
        } else {
          await notifier.continueMessage();
        }
        expect(generation.calls, 0);
        final durable = await container.read(chatRepoProvider).getById('s');
        expect(durable!.messages, session.messages);
        expect(durable.draft, 'unsent draft');
        expect(
          container.read(chatProvider('c')).requireValue.messages,
          session.messages,
        );
      },
    );
  }

  for (final checkpoint in ['append', 'snapshot', 'character']) {
    test('Stop during $checkpoint cannot restart the generation', () async {
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final gate = _Gate();
      late _ParkedGeneration generation;
      final container = ProviderContainer(
        overrides: [
          appDbProvider.overrideWithValue(db),
          if (checkpoint == 'append')
            chatRepoProvider.overrideWithValue(_DelayedAppend(db, gate)),
          if (checkpoint == 'snapshot')
            trackerSnapshotRepoProvider.overrideWithValue(
              _DelayedSnapshots(db, gate),
            ),
          if (checkpoint == 'character')
            characterRepoProvider.overrideWithValue(
              _DelayedCharacter(db, gate),
            ),
          chatGenerationServiceProvider.overrideWith((ref) {
            return generation = _ParkedGeneration(ref);
          }),
        ],
      );
      // Instantiate the stub before asserting zero calls on an aborted path.
      container.read(chatGenerationServiceProvider);
      addTearDown(() async {
        if (!gate.release.isCompleted) gate.release.complete();
        if (!generation.release.isCompleted) generation.release.complete();
        container.dispose();
        ChatSessionService.clearCache();
        await db.close();
      });
      await container
          .read(characterRepoProvider)
          .put(const Character(id: 'c', name: 'Alice'));
      await container
          .read(chatRepoProvider)
          .put(
            const ChatSession(
              id: 's',
              characterId: 'c',
              sessionIndex: 0,
              messages: [
                ChatMessage(id: 'a', role: 'assistant', content: 'Hi'),
              ],
            ),
          );
      await container.read(chatProvider('c').future);
      await container
          .read(trackerSnapshotRepoProvider)
          .upsert(const TrackerSnapshot(sessionId: 's', messageId: 'a'));
      await container
          .read(memoryGlobalSettingsProvider.notifier)
          .save(const MemoryGlobalSettings(enabled: false));
      final notifier = container.read(chatProvider('c').notifier);
      gate.armed = true;
      // afterUser has its own character lookup before send setup's lookup.
      if (checkpoint == 'character') gate.skip = 1;
      final send = notifier.sendMessage('First');
      addTearDown(() async {
        if (!gate.release.isCompleted) gate.release.complete();
        if (!generation.release.isCompleted) generation.release.complete();
        await send;
      });
      await gate.entered.future;
      await notifier.abortGeneration();
      final stopped = container.read(chatProvider('c')).requireValue;
      expect(stopped.isGenerating, isFalse);
      expect(stopped.isSendPending, isFalse);
      if (checkpoint == 'snapshot') {
        // A new legitimate run can own the slot before the old setup returns.
        final second = notifier.sendMessage('Second');
        await generation.entered.future;
        gate.release.complete();
        await send;
        expect(generation.calls, 1);
        expect(
          (await container
                  .read(trackerSnapshotRepoProvider)
                  .getByAnchor(
                    sessionId: 's',
                    messageId: 'a',
                    swipeId: 0,
                    agentSwipeId: 0,
                  ))!
              .committed,
          isTrue,
        );
        expect(
          container.read(chatProvider('c')).requireValue.isGenerating,
          isTrue,
        );
        expect(
          container.read(chatProvider('c')).requireValue.messages.last.content,
          'Second',
        );
        await notifier.sendMessage('Must stay blocked');
        expect(generation.calls, 1);
        generation.release.complete();
        await second;
        final durable = await container.read(chatRepoProvider).getById('s');
        expect(durable!.messages.map((m) => m.content), [
          'Hi',
          'First',
          'Second',
          'Reply',
        ]);
        return;
      }
      gate.release.complete();
      generation.release.complete();
      await send;

      expect(generation.calls, 0);
      expect(
        (await container
                .read(trackerSnapshotRepoProvider)
                .getByAnchor(
                  sessionId: 's',
                  messageId: 'a',
                  swipeId: 0,
                  agentSwipeId: 0,
                ))!
            .committed,
        isTrue,
      );
      final durable = await container.read(chatRepoProvider).getById('s');
      expect(durable!.messages.map((m) => m.content), ['Hi', 'First']);
      expect(container.read(chatProvider('c')).requireValue.session, durable);

      // A legitimate new run still starts; the cancelled setup has no claim.
      await notifier.sendMessage('Second');
      expect(generation.calls, 1);
    });
  }
}
