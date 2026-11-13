import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/llm/studio_ledger_service.dart';
import 'package:glaze_flutter/core/llm/studio_turn_config_snapshot.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/pipeline_settings.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/state/character_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/memory_agent_providers.dart';
import 'package:glaze_flutter/core/state/persona_resolution.dart';
import 'package:glaze_flutter/features/chat/abort_handler.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/services/stages/ledger_stage.dart';
import 'package:glaze_flutter/features/chat/services/stages/stage_context.dart';
import 'package:glaze_flutter/features/chat/state/post_gen_status_provider.dart';

class _PendingLedger extends Fake implements StudioLedgerService {
  final calls = <Completer<LedgerRunResult>>[];
  final started = [Completer<void>(), Completer<void>()];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #run) {
      final result = Completer<LedgerRunResult>();
      calls.add(result);
      started[calls.length - 1].complete();
      return result.future;
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'older same-task Ledger cancellation cannot clear newer status',
    () async {
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final service = _PendingLedger();
      final container = ProviderContainer(
        overrides: [
          appDbProvider.overrideWithValue(db),
          studioLedgerServiceProvider.overrideWithValue(service),
          characterByIdProvider('c').overrideWith((ref) => null),
          effectivePersonaForChatProvider((
            charId: 'c',
            sessionId: 's',
          )).overrideWith((ref) => null),
        ],
      );
      addTearDown(db.close);
      addTearDown(container.dispose);

      const assistant = ChatMessage(
        id: 'a',
        role: 'assistant',
        content: 'reply',
      );
      const session = ChatSession(
        id: 's',
        characterId: 'c',
        sessionIndex: 0,
        messages: [assistant],
      );
      late AsyncValue<ChatState> state = const AsyncData(
        ChatState(session: session),
      );
      final stageProvider = Provider<LedgerStage>((ref) {
        final abort = AbortHandler(
          ref: ref,
          charId: 'c',
          setState: (next) => state = next,
          getState: () => state,
          mutateSession: (_, _) async => null,
          loadSession: (_) async => null,
        );
        return LedgerStage(
          StageContext(
            ref: ref,
            charId: 'c',
            abortHandler: abort,
            setState: (next) => state = next,
            getState: () => state,
          ),
        );
      });
      final stage = container.read(stageProvider);
      final config = StudioTurnConfigSnapshot(
        config: const StudioConfig(sessionId: 's', enabled: true),
        preset: const StudioPreset(id: 'p'),
        pipelineSettings: const PipelineSettings(),
        apiConfigs: const [],
        activeApiConfig: const ApiConfig(
          id: 'api',
          endpoint: 'https://example.invalid/v1/chat/completions',
          model: 'test',
        ),
      );
      Future<void> run() => stage.run(
        sessionId: 's',
        messages: session.messages,
        genId: 1,
        finalAssistantText: assistant.content,
        targetMessage: assistant,
        isManualRerun: true,
        studioTurnConfig: config,
      );

      final old = run();
      await service.started[0].future;
      final oldStatus = container.read(postGenStatusProvider);
      final newer = run();
      await service.started[1].future;
      final newStatus = container.read(postGenStatusProvider);
      expect(newStatus.isSameRun(oldStatus), isFalse);

      service.calls[0].complete(LedgerRunResult(status: 'aborted'));
      await old;
      expect(container.read(postGenStatusProvider), same(newStatus));
      expect(container.read(postGenStatusProvider).isActive, isTrue);

      service.calls[1].complete(LedgerRunResult(status: 'aborted'));
      await newer;
      expect(
        container.read(postGenStatusProvider).phase,
        PostGenTaskPhase.idle,
      );
    },
  );
}
