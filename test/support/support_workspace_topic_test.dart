import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'helpers/workspace_test_harness.dart';

void main() {
  test(
    'newer topic during empty-store creation reuses the committed session and suppresses old reply',
    () async {
      final h = WorkspaceHarness();
      addTearDown(h.close);
      h.store.sessions.clear();
      h.store.messages.clear();
      h.store.availability.clear();
      await h.settle();
      final gate = h.store.gates['create'] = WorkspaceGate();
      h.notifier.applyInitialTopic('theme');
      await gate.entered.future;
      h.notifier.applyInitialTopic('memory');
      gate.release.complete();
      await h.settle();
      expect(h.store.calls.where((call) => call == 'create').length, 1);
      expect(h.state.sessions.length, 1);
      expect(h.state.lastHandledTopic, 'memory_books_setup');
      expect(
        h.state.activeMessages.single.cards
            .whereType<SetupActionCard>()
            .single
            .topicId,
        'memory_books_setup',
      );
    },
  );

  test(
    'unknown route topic produces local help without retaining arbitrary route text',
    () async {
      final h = WorkspaceHarness();
      addTearDown(h.close);
      await h.settle();
      h.notifier.applyInitialTopic('synthetic-secret-canary');
      await h.settle();
      expect(h.state.lastHandledTopic, 'help');
      expect(
        h.state.activeMessages.single.body,
        isNot(contains('synthetic-secret-canary')),
      );
      expect(
        h.state.activeMessages.single.cards.single,
        isA<QuickActionChipsCard>(),
      );
    },
  );

  test(
    'initial load failure keeps topic pending and settings unavailable until successful refresh',
    () async {
      final h = WorkspaceHarness();
      addTearDown(h.close);
      h.store.failures.add('load');
      h.notifier.applyInitialTopic('theme');
      await h.settle();
      expect(
        h.state.settingsAvailability,
        SupportSettingsAvailability.unavailable,
      );
      expect(h.state.lastHandledTopic, isNull);
      expect(h.store.calls, ['load']);
      h.store.failures.clear();
      expect(await h.notifier.refresh(), isTrue);
      await h.settle();
      expect(h.state.lastHandledTopic, 'theme_setup');
      expect(h.state.activeMessages.length, 1);
    },
  );

  test(
    'topic survives initial loading, creates session for empty store, and is handled once after durable reply',
    () async {
      final h = WorkspaceHarness();
      addTearDown(h.close);
      h.store.sessions.clear();
      h.store.messages.clear();
      h.store.availability.clear();
      final load = h.store.gates['load'] = WorkspaceGate();
      final reply = h.store.gates['reply-before'] = WorkspaceGate();
      h.notifier.applyInitialTopic('theme');
      await load.entered.future;
      expect(h.state.lastHandledTopic, isNull);
      load.release.complete();
      await reply.entered.future;
      expect(h.store.sessions.length, 1);
      expect(h.state.lastHandledTopic, isNull);
      reply.release.complete();
      await h.settle();
      expect(h.state.lastHandledTopic, 'theme_setup');
      expect(h.state.activeMessages.single.role, SupportMessageRole.assistant);
      h.notifier.applyInitialTopic(' theme ');
      await h.settle();
      expect(h.state.activeMessages.length, 1);
    },
  );

  test(
    'topic arriving while send is busy runs after durable user/reply',
    () async {
      final h = WorkspaceHarness();
      addTearDown(h.close);
      await h.settle();
      final gate = h.store.gates['user-before'] = WorkspaceGate();
      final send = h.notifier.sendUserMessage('hello');
      await gate.entered.future;
      h.notifier.applyInitialTopic('memory');
      expect(h.state.lastHandledTopic, isNull);
      gate.release.complete();
      expect(await send, isTrue);
      await h.settle();
      expect(h.state.lastHandledTopic, 'memory_books_setup');
      expect(h.state.activeMessages.length, 3);
    },
  );

  test(
    'failed topic stays pending without retry loop and explicit same-topic retry succeeds',
    () async {
      final h = WorkspaceHarness();
      addTearDown(h.close);
      await h.settle();
      h.store.failures.add('reply-before');
      h.notifier.applyInitialTopic('provider');
      await h.settle();
      expect(h.state.lastHandledTopic, isNull);
      expect(h.state.error, isNotNull);
      expect(h.store.calls.where((c) => c == 'reply-before').length, 1);
      h.store.failures.clear();
      h.notifier.applyInitialTopic('api');
      await h.settle();
      expect(h.state.lastHandledTopic, 'provider_setup');
      expect(h.state.activeMessages.length, 1);
    },
  );

  test('newer topic supersedes a pending older settings read', () async {
    final h = WorkspaceHarness();
    addTearDown(h.close);
    await h.settle();
    final gate = h.store.gates['settings'] = WorkspaceGate();
    h.notifier.applyInitialTopic('theme');
    await gate.entered.future;
    h.notifier.applyInitialTopic('memory');
    gate.release.complete();
    await h.settle();
    expect(h.state.lastHandledTopic, 'memory_books_setup');
    expect(h.state.activeMessages.length, 1);
    expect(
      h.state.activeMessages.single.cards
          .whereType<SetupActionCard>()
          .single
          .topicId,
      'memory_books_setup',
    );
  });

  test('stale topic after switch retries for the current selection', () async {
    final h = WorkspaceHarness();
    addTearDown(h.close);
    await h.settle();
    final gate = h.store.gates['settings'] = WorkspaceGate();
    h.notifier.applyInitialTopic('theme');
    await gate.entered.future;
    h.notifier.selectSession('b');
    gate.release.complete();
    await h.settle();
    expect(h.state.lastHandledTopic, 'theme_setup');
    expect(h.state.activeSessionId, 'b');
    expect(h.store.messages['a'], isEmpty);
    expect(h.state.activeMessages.length, 1);
  });

  test(
    'pending topic survives dependency rebuild while old work cannot consume it',
    () async {
      final h = WorkspaceHarness();
      addTearDown(h.close);
      await h.settle();
      final gate = h.store.gates['settings'] = WorkspaceGate();
      h.notifier.applyInitialTopic('theme');
      await gate.entered.future;
      final replacement = ControlledWorkspaceStore(h.repo);
      await h.replace(replacement);
      expect(h.state.lastHandledTopic, 'theme_setup');
      gate.release.complete();
      await h.settle();
      expect(h.store.messages['a'], isEmpty);
      expect(h.state.activeMessages.length, 1);
    },
  );

  test(
    'unavailable settings do not consume pending topic; confirmed recovery resumes it',
    () async {
      final h = WorkspaceHarness();
      addTearDown(h.close);
      h.store.availability['a'] = SupportSettingsAvailability.corrupt;
      await h.settle();
      h.notifier.applyInitialTopic('theme');
      await h.settle();
      expect(h.state.lastHandledTopic, isNull);
      expect(await h.notifier.sendUserMessage('blocked'), isFalse);
      expect(
        await h.notifier.setMode(SupportAssistantMode.diagnostics),
        isFalse,
      );
      expect(
        await h.notifier.recoverSettings(sessionId: 'a', confirmed: false),
        isFalse,
      );
      expect(
        await h.notifier.recoverSettings(sessionId: 'a', confirmed: true),
        isTrue,
      );
      await h.settle();
      expect(h.state.lastHandledTopic, 'theme_setup');
    },
  );

  test(
    'newer topic after older reply commit owns handling; the already durable older row is retained',
    () async {
      final h = WorkspaceHarness();
      addTearDown(h.close);
      await h.settle();
      final gate = h.store.gates['reply-after'] = WorkspaceGate();
      h.notifier.applyInitialTopic('theme');
      await gate.entered.future;
      expect(h.state.lastHandledTopic, isNull);
      h.notifier.applyInitialTopic('memory');
      gate.release.complete();
      await h.settle();
      expect(h.state.lastHandledTopic, 'memory_books_setup');
      expect(h.state.activeMessages.length, 2);
      expect(
        h.state.activeMessages.last.cards
            .whereType<SetupActionCard>()
            .single
            .topicId,
        'memory_books_setup',
      );
    },
  );

  test(
    'failed confirmed recovery retains blocked settings and safe error',
    () async {
      final h = WorkspaceHarness();
      addTearDown(h.close);
      h.store.availability['a'] = SupportSettingsAvailability.corrupt;
      await h.settle();
      h.store.failures.add('recover');
      expect(
        await h.notifier.recoverSettings(sessionId: 'a', confirmed: true),
        isFalse,
      );
      expect(h.state.settingsAvailability, SupportSettingsAvailability.corrupt);
      expect(h.state.error, isNotNull);
      expect(h.state.error, isNot(contains('synthetic-secret-canary')));
      expect(await h.notifier.sendUserMessage('blocked'), isFalse);
    },
  );
}
