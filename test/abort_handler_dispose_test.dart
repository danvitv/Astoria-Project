import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/chat/abort_handler.dart';
import 'package:glaze_flutter/features/chat/state/post_cleaner_state_provider.dart';

class _CountingCancelToken extends CancelToken {
  int cancelCalls = 0;

  @override
  void cancel([Object? reason]) {
    cancelCalls++;
    super.cancel(reason);
  }
}

final _handlerProvider = Provider<AbortHandler>(
  (ref) => AbortHandler(
    ref: ref,
    charId: 'char-1',
    setState: (_) => fail('Retirement must not publish state'),
    getState: () => fail('Retirement must not read state'),
    mutateSession: (_, _) => fail('Retirement must not mutate a session'),
    loadSession: (_) => fail('Retirement must not load a session'),
  ),
);

void main() {
  test(
    'active owner accepts its tokens and rejects stale generation tokens',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final handler = container.read(_handlerProvider);
      addTearDown(handler.dispose);
      final staleId = handler.nextGenId();
      final currentId = handler.nextGenId();
      final staleToken = CancelToken();
      final generationToken = CancelToken();
      final imageToken = CancelToken();

      handler.setCancelToken(staleToken, genId: staleId);
      handler.setCancelToken(generationToken, genId: currentId);
      handler.imgGenCancelToken = imageToken;

      expect(handler.isCurrentGen(staleId), isFalse);
      expect(handler.isCurrentGen(currentId), isTrue);
      expect(staleToken.isCancelled, isTrue);
      expect(generationToken.isCancelled, isFalse);
      expect(imageToken.isCancelled, isFalse);
      expect(handler.isGeneratingImage, isTrue);
    },
  );

  test('dispose cancels private transports without a live Ref', () {
    final container = ProviderContainer();
    final handler = container.read(_handlerProvider);
    final genId = handler.nextGenId();
    final generationToken = CancelToken();
    final imageToken = CancelToken();
    handler.setCancelToken(generationToken, genId: genId);
    handler.imgGenCancelToken = imageToken;
    container.dispose();

    handler.dispose();

    expect(generationToken.isCancelled, isTrue);
    expect(imageToken.isCancelled, isTrue);
    expect(handler.imgGenCancelToken, isNull);
    expect(handler.isGeneratingImage, isFalse);
    expect(handler.isCurrentGen(genId), isFalse);
  });

  test('retired owner rejects late installs and cannot start a generation', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final handler = container.read(_handlerProvider);
    final oldId = handler.nextGenId();
    handler.dispose();
    final lateId = handler.nextGenId();
    final oldToken = CancelToken();
    final lateToken = CancelToken();
    final imageToken = CancelToken();

    handler.setCancelToken(oldToken, genId: oldId);
    handler.setCancelToken(lateToken, genId: lateId);
    handler.imgGenCancelToken = imageToken;
    handler.imgGenCancelToken = null;

    expect(oldToken.isCancelled, isTrue);
    expect(lateToken.isCancelled, isTrue);
    expect(imageToken.isCancelled, isTrue);
    expect(handler.imgGenCancelToken, isNull);
    expect(handler.isGeneratingImage, isFalse);
    expect(handler.isCurrentGen(oldId), isFalse);
    expect(handler.isCurrentGen(lateId), isFalse);
  });

  test('dispose is idempotent and does not retain cancelled tokens', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final handler = container.read(_handlerProvider);
    final genId = handler.nextGenId();
    final generationToken = _CountingCancelToken();
    final imageToken = _CountingCancelToken();
    final lateImageToken = _CountingCancelToken();
    handler.setCancelToken(generationToken, genId: genId);
    handler.imgGenCancelToken = imageToken;

    handler.dispose();
    handler.dispose();
    handler.imgGenCancelToken = lateImageToken;
    handler.dispose();

    expect(generationToken.cancelCalls, 1);
    expect(imageToken.cancelCalls, 1);
    expect(lateImageToken.cancelCalls, 1);
    expect(handler.isCurrentGen(genId), isFalse);
  });

  test('dispose cancels captured post-gen tokens once without a live Ref', () {
    final container = ProviderContainer();
    final handler = container.read(_handlerProvider);
    final cleanerToken = _CountingCancelToken();
    final reconciliationToken = _CountingCancelToken();
    handler.registerOwnedToken(cleanerToken);
    handler.registerOwnedToken(cleanerToken);
    handler.registerOwnedToken(reconciliationToken);
    container.dispose();

    handler.dispose();
    handler.unregisterOwnedToken(cleanerToken);
    handler.dispose();

    expect(cleanerToken.isCancelled, isTrue);
    expect(reconciliationToken.isCancelled, isTrue);
    expect(cleanerToken.cancelCalls, 1);
    expect(reconciliationToken.cancelCalls, 1);
  });

  test('retired owner cancels late post-gen registrations immediately', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final handler = container.read(_handlerProvider);
    final token = _CountingCancelToken();
    handler.dispose();

    handler.registerOwnedToken(token);
    handler.registerOwnedToken(token);
    handler.dispose();

    expect(token.isCancelled, isTrue);
    expect(token.cancelCalls, 1);
  });

  test('retirement leaves unregistered and unrelated tokens alone', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final handler = container.read(_handlerProvider);
    final releasedToken = _CountingCancelToken();
    final unrelatedToken = _CountingCancelToken();
    container.read(cleanerCancelTokenProvider.notifier).state = unrelatedToken;
    handler.registerOwnedToken(releasedToken);
    handler.unregisterOwnedToken(releasedToken);
    handler.unregisterOwnedToken(unrelatedToken);

    handler.dispose();

    expect(releasedToken.isCancelled, isFalse);
    expect(unrelatedToken.isCancelled, isFalse);
    expect(releasedToken.cancelCalls, 0);
    expect(unrelatedToken.cancelCalls, 0);
    expect(container.read(cleanerCancelTokenProvider), same(unrelatedToken));
  });

  test('Stop after retirement does not read or publish state', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final handler = container.read(_handlerProvider);
    handler.dispose();

    await handler.abortGeneration();
  });
}
