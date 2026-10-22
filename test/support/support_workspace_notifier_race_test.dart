import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'helpers/workspace_test_harness.dart';

void main() {
  late WorkspaceHarness h;
  setUp(() async {
    h = WorkspaceHarness();
    await h.settle();
  });
  tearDown(() => h.close());

  test(
    'user failure rejects without publication; reply failure publishes durable user with safe error',
    () async {
      h.store.failures.add('user-before');
      expect(await h.notifier.sendUserMessage('draft'), isFalse);
      expect(h.state.activeMessages, isEmpty);
      h.store.failures.clear();
      h.store.failures.add('reply-before');
      expect(await h.notifier.sendUserMessage('durable user'), isTrue);
      expect(h.state.activeMessages.single.body, 'durable user');
      expect(h.state.activeMessages.single.role, SupportMessageRole.user);
      expect(h.state.error, contains('Сообщение сохранено'));
      expect(h.state.error, isNot(contains('synthetic-secret-canary')));
      expect(h.state.isBusy, isFalse);
      await h.notifier.refresh();
      expect(h.state.activeMessages.single.body, 'durable user');
    },
  );

  test('same-turn duplicate send is rejected before queue admission', () async {
    final gate = h.store.gates['user-before'] = WorkspaceGate();
    final first = h.notifier.sendUserMessage('first');
    expect(await h.notifier.sendUserMessage('duplicate'), isFalse);
    await gate.entered.future;
    gate.release.complete();
    expect(await first, isTrue);
    expect(
      h.store.messages['a']!
          .where((m) => m.role == SupportMessageRole.user)
          .length,
      1,
    );
  });

  for (final stage in ['settings', 'user-after']) {
    test('switch at $stage owns selection and prevents old reply', () async {
      final gate = h.store.gates[stage] = WorkspaceGate();
      final send = h.notifier.sendUserMessage('old session');
      await gate.entered.future;
      h.notifier.selectSession('b');
      gate.release.complete();
      expect(await send, stage == 'user-after');
      await h.settle();
      expect(h.state.activeSessionId, 'b');
      expect(h.state.activeMessages, isEmpty);
      expect(h.store.calls, isNot(contains('reply-before')));
      expect(h.store.messages['a']!.length, stage == 'user-after' ? 1 : 0);
      if (stage == 'user-after') {
        expect(h.state.messagesBySession['a']!.single.body, 'old session');
      }
    });

    test(
      'delete at $stage cannot resurrect a session or append a reply',
      () async {
        final gate = h.store.gates[stage] = WorkspaceGate();
        final send = h.notifier.sendUserMessage('deleted session');
        await gate.entered.future;
        final deletion = h.notifier.deleteSession('a');
        gate.release.complete();
        expect(await send, stage == 'user-after');
        expect(await deletion, isTrue);
        expect(h.store.sessions.containsKey('a'), isFalse);
        expect(h.state.messagesBySession.containsKey('a'), isFalse);
        expect(h.store.calls, isNot(contains('reply-before')));
      },
    );
  }

  for (final stage in [
    'load',
    'settings',
    'user-after',
    'reply-after',
    'change-before',
  ]) {
    test(
      'dependency rebuild at $stage retains notifier but isolates captured store and publication',
      () async {
        final gate = h.store.gates[stage] = WorkspaceGate();
        final operation = switch (stage) {
          'load' => h.notifier.refresh(),
          'change-before' => h.notifier.setMode(
            SupportAssistantMode.onboarding,
          ),
          _ => h.notifier.sendUserMessage('old lifecycle'),
        };
        await gate.entered.future;
        final replacement = ControlledWorkspaceStore(h.repo);
        replacement.sessions.clear();
        replacement.messages.clear();
        replacement.availability.clear();
        replacement.addSession('replacement');
        await h.replace(replacement);
        expect(
          h.container.read(supportWorkspaceProvider.notifier),
          same(h.notifier),
        );
        expect(h.state.activeSessionId, 'replacement');
        gate.release.complete();
        expect(await operation, ['user-after', 'reply-after'].contains(stage));
        await h.settle();
        expect(h.state.activeSessionId, 'replacement');
        expect(h.state.activeMessages, isEmpty);
        expect(h.state.error, isNull);
        expect(replacement.calls, ['load']);
        if (stage == 'settings' || stage == 'user-after') {
          expect(h.store.calls, isNot(contains('reply-before')));
        }
        if (stage == 'change-before') {
          expect(h.store.calls, isNot(contains('change-commit')));
        }
        expect(h.state.isBusy, isFalse);
      },
    );
  }

  test(
    'explicit provider invalidation rejects stale settings completion',
    () async {
      final gate = h.store.gates['settings'] = WorkspaceGate();
      final send = h.notifier.sendUserMessage('old build');
      await gate.entered.future;
      h.container.invalidate(supportWorkspaceProvider);
      await h.settle();
      gate.release.complete();
      expect(await send, isFalse);
      await h.settle();
      expect(h.state.activeMessages, isEmpty);
      expect(h.state.isBusy, isFalse);
    },
  );

  test(
    'late failure after switch cannot paint an old reply error into the new selection',
    () async {
      final gate = h.store.gates['reply-before'] = WorkspaceGate();
      h.store.failures.add('reply-before');
      final send = h.notifier.sendUserMessage('durable old user');
      await gate.entered.future;
      h.notifier.selectSession('b');
      gate.release.complete();
      expect(await send, isTrue);
      await h.settle();
      expect(h.state.activeSessionId, 'b');
      expect(h.state.error, isNull);
      expect(h.state.messagesBySession['a']!.single.body, 'durable old user');
    },
  );

  test(
    'create rename preferences and generic send never eagerly load chooser metadata',
    () async {
      var loads = 0;
      await h.close();
      h = WorkspaceHarness(
        metadata: () async {
          loads++;
        },
      );
      await h.settle();
      expect(await h.notifier.createNewSession(), isNotNull);
      expect(
        await h.notifier.renameSession(h.state.activeSessionId, 'renamed'),
        isTrue,
      );
      expect(await h.notifier.setTemperature(0.6), isTrue);
      expect(await h.notifier.sendUserMessage('generic help'), isTrue);
      await h.settle();
      expect(loads, 0);
      expect(h.state.activeMessages.length, 2);
      expect(h.state.error, isNull);
    },
  );

  test(
    'old failing reload after rebuild cannot paint its error or clear a new busy state',
    () async {
      final gate = h.store.gates['load'] = WorkspaceGate();
      h.store.failures.add('load');
      final refresh = h.notifier.refresh();
      await gate.entered.future;
      final replacement = ControlledWorkspaceStore(h.repo);
      final newGate = replacement.gates['load'] = WorkspaceGate();
      await h.replace(replacement);
      expect(h.state.isBusy, isTrue);
      gate.release.complete();
      expect(await refresh, isFalse);
      expect(h.state.isBusy, isTrue);
      expect(h.state.error, isNull);
      newGate.release.complete();
      await h.settle();
      expect(h.state.isBusy, isFalse);
    },
  );

  for (final stage in ['settings', 'user-after', 'reply-after']) {
    test(
      'disposal at $stage settles without stale work or exceptions',
      () async {
        final gate = h.store.gates[stage] = WorkspaceGate();
        final send = h.notifier.sendUserMessage('disposed');
        await gate.entered.future;
        h.dispose();
        gate.release.complete();
        expect(await send, stage != 'settings');
        if (stage != 'reply-after') {
          expect(h.store.calls, isNot(contains('reply-before')));
        }
      },
    );
  }
}
