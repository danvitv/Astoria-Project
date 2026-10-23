import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/studio_turn_config_resolver.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/services/impersonation_service.dart';
import 'package:glaze_flutter/features/chat/services/stream_generation_service.dart';

import 'native_provider_consumer_roleplay_fixture.dart';

const _session = ChatSession(
  id: 'original-session',
  characterId: 'character',
  sessionIndex: 0,
  messages: [
    ChatMessage(
      id: 'assistant',
      role: 'assistant',
      content: 'Original reply',
      timestamp: 1,
    ),
  ],
);

void main() {
  for (final mode in ['normal', 'regen', 'continue']) {
    test(
      'actual StreamGenerationService captures source before config await: $mode',
      () async {
        final isolation = NativeRoleplayIsolation();
        await isolation.run(() async {
          final f = NativeRoleplaySyntheticBackend(_session, isolation);
          try {
            await f.initialize();
            await f.store();
            expect(f.ref.read(nativeProviderRuntimeProvider), same(f.runtime));
            expect(
              f.ref.read(studioTurnConfigResolverProvider).sources,
              same(f.sources),
            );
            final original = f.sources.captureOriginalStamp();
            final service = StreamGenerationService(
              ref: f.ref,
              charId: 'character',
              genId: 1,
              isAborted: () => !f.runCurrent,
            );
            final pending = f.own(
              service.run(
                session: _session,
                saveSession: mode == 'regen' ? _session : null,
                regenTargetId: mode == 'regen' ? 'assistant' : null,
                continueTargetId: mode == 'continue' ? 'assistant' : null,
                currentState: const ChatState(
                  session: _session,
                  isGenerating: true,
                ),
              ),
            );
            await f.waitUntilGateEntered(pending);
            expect(f.token, isNotNull);
            f.runtime.onApiMutationStarted()();
            expect(f.sources.isOriginalCurrent(original, () => true), isFalse);
            f.gate.release();
            final result = await pending;
            expect(result.isGenerating, isFalse);
            expect(result.session, _session);
            expect(isolation.attempts, isEmpty);
            expect(f.wire.wires, isEmpty);
            expect(f.wire.adapters, isEmpty);
            expect(f.wire.legacy.requests, isEmpty);
          } finally {
            await f.close();
          }
        });
      },
    );
  }

  test('actual impersonation captures native stamp before API load', () async {
    final isolation = NativeRoleplayIsolation();
    await isolation.run(() async {
      final f = NativeRoleplaySyntheticBackend(_session, isolation);
      try {
        await f.initialize();
        await f.store();
        expect(f.ref.read(nativeProviderRuntimeProvider), same(f.runtime));
        final service = ImpersonationService(
          ref: f.ref,
          charId: 'character',
          isAborted: () => !f.runCurrent,
        );
        var paints = 0;
        final pending = f.own(
          service.run(
            session: _session,
            impersonationPrompt: 'Synthetic prompt',
            setCancelToken: (_) {},
            onDelta: (_) {
              paints++;
            },
          ),
        );
        await f.waitUntilGateEntered(pending);
        f.runtime.onApiMutationStarted()();
        f.gate.release();
        await expectLater(pending, throwsNative(NativeProviderFailure.stale));
        expect(paints, 0);
        expect(isolation.attempts, isEmpty);
        expect(f.wire.wires, isEmpty);
        expect(f.wire.adapters, isEmpty);
        expect(f.wire.legacy.requests, isEmpty);
      } finally {
        await f.close();
      }
    });
  });
}
