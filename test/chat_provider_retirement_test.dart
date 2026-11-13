import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/llm/studio_turn_config_snapshot.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/chat_generation_service.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/chat_session_service.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';

class _Run {
  final token = CancelToken();
  final release = Completer<void>();
  late bool Function() isAborted;
}

class _Generation extends ChatGenerationService {
  _Generation(this.ownerRef) : super(ownerRef);
  final Ref ownerRef;
  final entered = [Completer<_Run>(), Completer<_Run>()];
  final runs = <_Run>[];

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
    StudioTurnConfigSnapshot? studioTurnConfig,
  }) async {
    final run = _Run()..isAborted = isAborted;
    runs.add(run);
    ownerRef
        .read(chatProvider(charId).notifier)
        .setCancelToken(run.token, genId: genId);
    entered[runs.length - 1].complete(run);
    await run.release.future;
    return currentState.copyWith(session: session, isGenerating: false);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'explicit invalidation cancels old transport, replacement owns its own Stop',
    () async {
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      late _Generation generation;
      final container = ProviderContainer(
        overrides: [
          appDbProvider.overrideWithValue(db),
          chatGenerationServiceProvider.overrideWith(
            (ref) => generation = _Generation(ref),
          ),
        ],
      );
      container.read(chatGenerationServiceProvider);
      addTearDown(() async {
        for (final run in generation.runs) {
          if (!run.release.isCompleted) run.release.complete();
        }
        container.dispose();
        ChatSessionService.clearCache();
        await db.close();
      });
      await container
          .read(characterRepoProvider)
          .put(const Character(id: 'c', name: 'Card'));
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
      final first = container
          .read(chatProvider('c').notifier)
          .sendMessage('First');
      final old = await generation.entered[0].future;
      expect(old.token.isCancelled, isFalse);

      container.invalidate(chatProvider('c'));
      expect(old.token.isCancelled, isTrue);
      expect(old.isAborted(), isTrue);
      await container.read(chatProvider('c').future);
      final replacement = container.read(chatProvider('c').notifier);
      final second = replacement.sendMessage('Second');
      final current = await generation.entered[1].future;
      expect(current.token.isCancelled, isFalse);
      expect(current.isAborted(), isFalse);

      old.release.complete();
      await first;
      expect(current.token.isCancelled, isFalse);
      expect(
        container.read(chatProvider('c')).requireValue.isGenerating,
        isTrue,
      );
      await replacement.abortGeneration();
      expect(current.token.isCancelled, isTrue);
      current.release.complete();
      await second;
      expect(
        container.read(chatProvider('c')).requireValue.isGenerating,
        isFalse,
      );
    },
  );
}
