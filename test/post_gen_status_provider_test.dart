import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/chat/state/post_gen_status_provider.dart';

void main() {
  test('a same-session same-task run cannot settle its replacement', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final status = container.read(postGenStatusProvider.notifier);
    final old = status.startRun(sessionId: 's', task: PostGenTask.ledger);
    final newer = status.startRun(sessionId: 's', task: PostGenTask.ledger);

    expect(identical(old.runId, newer.runId), isFalse);
    expect(status.updateRunDetail(old, 'stale progress'), isFalse);
    expect(status.finishRun(old), isFalse);
    expect(status.finishRun(old, isError: true), isFalse);
    expect(status.clearRun(old), isFalse);
    expect(status.state, same(newer));

    expect(status.updateRunDetail(newer, 'retry'), isTrue);
    expect(status.state, isNot(same(newer)));
    expect(status.state.runId, same(newer.runId));
    expect(status.finishRun(newer, detail: 'done'), isTrue);
    expect(status.state.runId, same(newer.runId));
    expect(status.state.isDone, isTrue);
    expect(status.clearRun(newer), isFalse);
  });

  test('collector-only completion retains observation identity and task', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final status = container.read(postGenStatusProvider.notifier);
    final observation = status.startRun(
      sessionId: 's',
      task: PostGenTask.cardEvolutionObservation,
    );

    expect(status.finishRun(observation, detail: 'collectorCompleted'), isTrue);
    expect(status.state.task, PostGenTask.cardEvolutionObservation);
    expect(status.state.runId, same(observation.runId));
    expect(status.state.isDone, isTrue);

    final writer = status.startRun(
      sessionId: 's',
      task: PostGenTask.cardRewriter,
    );
    expect(status.clearRun(observation), isFalse);
    expect(status.finishRun(writer), isTrue);
    expect(status.state.task, PostGenTask.cardRewriter);
    expect(status.state.runId, same(writer.runId));
  });

  test(
    'legacy snapshots remain supported without logical ownership fallback',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final status = container.read(postGenStatusProvider.notifier);
      final old = PostGenStatusState.running(
        sessionId: 's',
        task: PostGenTask.extBlocks,
      );
      status.state = old;
      expect(status.updateRunDetail(old, 'progress'), isTrue);
      expect(status.state.runId, same(old.runId));
      status.state = PostGenStatusState.running(
        sessionId: 's',
        task: PostGenTask.extBlocks,
      );
      expect(status.finishRun(old), isFalse);
    },
  );
}
