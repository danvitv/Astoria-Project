import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Finite file/socket/channel tripwires cover construction through cleanup.
/// Not a claim to intercept all FFI or processes; no live provider is constructed.
final class SessionMemoryIsolation {
  final attempts = <String>[];
  Never block(String boundary) {
    attempts.add(boundary);
    throw StateError('Outside the synthetic session-memory fixture.');
  }

  Future<void> run(Future<void> Function() body) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final previous = messenger.allMessagesHandler;
    messenger.allMessagesHandler = (channel, handler, message) =>
        block('channel $channel');
    try {
      await HttpOverrides.runZoned(
        () => IOOverrides.runZoned(
          body,
          createFile: (_) => block('file/default DB'),
          createDirectory: (_) => block('directory'),
          createLink: (_) => block('link'),
          socketConnect:
              (host, port, {sourceAddress, sourcePort = 0, timeout}) =>
                  block('socket.connect'),
          socketStartConnect: (host, port, {sourceAddress, sourcePort = 0}) =>
              block('socket.startConnect'),
        ),
        createHttpClient: (_) => block('HTTP'),
      );
      await messenger.platformMessagesFinished;
      expect(attempts, isEmpty);
    } finally {
      messenger.allMessagesHandler = previous;
    }
  }
}

final class SessionMemoryBarrier {
  final entered = Completer<void>();
  final release = Completer<void>();
  Future<void> wait() async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
  }

  /// The action must reach this exact gate. Propagate its original early error
  /// instead of timing out on entry; a successful early completion also fails.
  Future<void> waitForEntry<T>(Future<T> operation) => Future.any<void>([
    entered.future,
    operation.then<void>((_) {
      if (!entered.isCompleted) {
        throw StateError(
          'Synthetic action completed before the required gate.',
        );
      }
    }),
  ]);
}
