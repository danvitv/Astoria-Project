import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Finite graph allowlist plus HTTP/default-Dio, native-channel and filesystem
/// tripwires installed BEFORE construction, retained THROUGH pending cleanup.
/// This is not a universal process/FFI/isolate sandbox.
final class NativeRoleplayIsolation extends ProviderObserver {
  final attempts = <String>[];
  final allowed = <Object>{};

  Never block(String boundary) {
    attempts.add(boundary);
    throw StateError('Outside declared synthetic roleplay fixture: $boundary');
  }

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) {
    if (!allowed.contains(context.provider)) {
      block('unexpected provider startup');
    }
  }

  Future<void> run(Future<void> Function() body) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final previous = messenger.allMessagesHandler;
    messenger.allMessagesHandler = (channel, handler, message) =>
        block('native $channel');
    Object? failure;
    StackTrace? trace;
    try {
      await HttpOverrides.runZoned(
        () => IOOverrides.runZoned(
          () async {
            try {
              await body();
            } catch (error, stack) {
              failure = error;
              trace = stack;
            } finally {
              try {
                await messenger.platformMessagesFinished;
                expect(
                  attempts,
                  isEmpty,
                  reason: 'Includes swallowed cleanup attempts',
                );
              } catch (error, stack) {
                failure ??= error;
                trace ??= stack;
              }
            }
          },
          createFile: (_) => block('file/default DB'),
          createDirectory: (_) => block('directory/default DB/isolate startup'),
          createLink: (_) => block('link'),
          socketConnect:
              (host, port, {sourceAddress, sourcePort = 0, timeout}) =>
                  block('socket.connect'),
          socketStartConnect: (host, port, {sourceAddress, sourcePort = 0}) =>
              block('socket.startConnect'),
        ),
        createHttpClient: (_) => block('default Dio/HTTP client'),
      );
    } finally {
      messenger.allMessagesHandler = previous;
    }
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  }
}
