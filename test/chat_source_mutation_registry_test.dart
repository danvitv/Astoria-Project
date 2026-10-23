import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/application/chat_source_mutation_registry.dart';
import 'package:glaze_flutter/core/state/chat_source_mutation_provider.dart';

void main() {
  test('begin is synchronous, exact, immutable, and settles once', () {
    final registry = ChatSourceMutationRegistry();
    final events = <ChatSourceMutationChange>[];
    registry.subscribe(events.add);
    final ids = {'a', 'b'};
    final settle = registry.beginMutation(sessionId: 'game', messageIds: ids);
    expect(events.single.phase, ChatSourceMutationPhase.began);
    expect(registry.isPending(sessionId: 'game', messageIds: ['b']), isTrue);
    expect(
      registry.isPending(sessionId: 'game', messageIds: ['other']),
      isFalse,
    );
    expect(registry.isPending(sessionId: 'other', messageIds: ['b']), isFalse);
    ids.clear();
    expect(events.single.messageIds, {'a', 'b'});
    expect(() => events.single.messageIds!.add('c'), throwsUnsupportedError);
    settle();
    settle();
    expect(events.map((event) => event.phase), [
      ChatSourceMutationPhase.began,
      ChatSourceMutationPhase.settled,
    ]);
    expect(registry.isPending(sessionId: 'game', messageIds: ['b']), isFalse);
  });

  test(
    'nested session/message fences retain pending until the last finally',
    () {
      final registry = ChatSourceMutationRegistry();
      final outer = registry.beginMutation(sessionId: 'game');
      final inner = registry.beginMutation(
        sessionId: 'game',
        messageIds: {'a'},
      );
      inner();
      expect(
        registry.isPending(sessionId: 'game', messageIds: ['other']),
        isTrue,
      );
      outer();
      expect(registry.isPending(sessionId: 'game', messageIds: ['a']), isFalse);
    },
  );

  test('pure empty plans are silent and no observer is required', () {
    final registry = ChatSourceMutationRegistry();
    registry.beginMutation(sessionId: '', messageIds: {'a'})();
    registry.beginMutation(sessionId: 'game', messageIds: {''})();
    expect(registry.isPending(sessionId: 'game', messageIds: ['a']), isFalse);
    final settle = registry.beginMutation(sessionId: 'game', messageIds: {'a'});
    final events = <ChatSourceMutationChange>[];
    registry.subscribe(events.add);
    expect(events, isEmpty); // no replay, body read, or startup work
    expect(registry.isPending(sessionId: 'game', messageIds: ['a']), isTrue);
    settle();
    expect(events.single.phase, ChatSourceMutationPhase.settled);
  });

  test('listener errors and unsubscribed snapshot callbacks are isolated', () {
    final registry = ChatSourceMutationRegistry();
    registry.subscribe((_) => throw StateError('observer failure'));
    var staleCalls = 0;
    late void Function() unsubscribe;
    registry.subscribe((_) => unsubscribe());
    unsubscribe = registry.subscribe((_) => staleCalls++);
    final events = <ChatSourceMutationChange>[];
    registry.subscribe(events.add);
    final settle = registry.beginMutation(sessionId: 'game');
    settle();
    unsubscribe();
    expect(staleCalls, 0);
    expect(events.length, 2);
  });

  test(
    'disposal during dispatch suppresses stale callbacks and settlements',
    () {
      final registry = ChatSourceMutationRegistry();
      var staleCalls = 0;
      registry.subscribe((_) => registry.dispose());
      registry.subscribe((_) => staleCalls++);
      final settle = registry.beginMutation(sessionId: 'game');
      settle();
      registry.subscribe((_) => staleCalls++);
      registry.beginMutation(sessionId: 'game')();
      expect(staleCalls, 0);
      expect(registry.isDisposed, isTrue);
      expect(registry.isPending(sessionId: 'game', messageIds: ['a']), isTrue);
    },
  );

  test(
    'primitive provider retires old lifetime without evaluating other providers',
    () {
      final observed = _ObservedProviders();
      final container = ProviderContainer(observers: [observed]);
      final old = container.read(chatSourceMutationRegistryProvider);
      var oldCalls = 0;
      old.subscribe((_) => oldCalls++);
      final settle = old.beginMutation(sessionId: 'game');
      container.invalidate(chatSourceMutationRegistryProvider);
      final replacement = container.read(chatSourceMutationRegistryProvider);
      expect(identical(old, replacement), isFalse);
      expect(old.isDisposed, isTrue);
      settle();
      old.beginMutation(sessionId: 'game')();
      expect(oldCalls, 1);
      expect(
        replacement.isPending(sessionId: 'game', messageIds: ['a']),
        isFalse,
      );
      container.dispose();
      expect(replacement.isDisposed, isTrue);
      expect(
        observed.providers,
        everyElement(chatSourceMutationRegistryProvider),
      );
    },
  );
}

final class _ObservedProviders extends ProviderObserver {
  final providers = <Object>[];

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) {
    providers.add(context.provider);
  }
}
