import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/embedding_service.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/state/lorebook_embedding_provider.dart';
import 'package:glaze_flutter/core/state/lorebook_provider.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/state/lorebook_coverage_provider.dart';

const _charId = 'coverage-char';

class _ReadyChat extends ChatNotifier {
  _ReadyChat(super.arg);

  @override
  Future<ChatState> build() async => const ChatState(
    session: ChatSession(
      id: 'coverage-session',
      characterId: _charId,
      sessionIndex: 0,
    ),
  );
}

void main() {
  testWidgets(
    'opening coverage defers embedding config reads until after build',
    (tester) async {
      final readPhases = <SchedulerPhase>[];
      final container = ProviderContainer(
        overrides: [
          chatProvider(_charId).overrideWith(() => _ReadyChat(_charId)),
          embeddingConfigProvider.overrideWith((ref) {
            readPhases.add(SchedulerBinding.instance.schedulerPhase);
            return const EmbeddingConfig(endpoint: '', model: '');
          }),
        ],
      );
      addTearDown(container.dispose);
      container.read(lorebookSettingsProvider.notifier).state =
          const LorebookGlobalSettings(searchType: 'hybrid');
      await container.read(chatProvider(_charId).future);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: _CoverageReader()),
        ),
      );
      expect(readPhases, isEmpty);

      await tester.pump(const Duration(milliseconds: 1));
      expect(readPhases, isNotEmpty);
      expect(readPhases, isNot(contains(SchedulerPhase.persistentCallbacks)));
      expect(tester.takeException(), isNull);
    },
  );
}

class _CoverageReader extends ConsumerWidget {
  const _CoverageReader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(lorebookCoverageProvider(_charId));
    return const SizedBox();
  }
}
