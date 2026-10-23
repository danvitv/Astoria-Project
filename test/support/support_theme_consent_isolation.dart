import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';

/// Finite pre-evaluation tripwires, not a universal FFI/process sandbox.
/// The actual consent composition uses constructor injection, no provider reads.
final class ThemeConsentIsolation extends ProviderObserver {
  final attempts = <String>[];

  Never block(String boundary) {
    attempts.add(boundary);
    throw StateError('Synthetic local consent crossed an isolation boundary.');
  }

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) =>
      block('unexpected startup provider');

  Future<void> run(Future<void> Function() body) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channels = [
      'flutter/platform',
      'flutter/platform_views',
      'flutter/assets',
      'plugins.it_nomads.com/flutter_secure_storage',
      'plugins.flutter.io/path_provider',
      'plugins.flutter.io/shared_preferences',
      'plugins.flutter.io/shared_preferences_async',
      'plugins.flutter.io/url_launcher',
      'plugins.flutter.io/google_sign_in',
      'dev.flutter.pigeon.SharedPreferencesApi.getAll',
      'dev.flutter.pigeon.SharedPreferencesApi.setString',
      'com.pichillilorenzo/flutter_headless_inappwebview',
      'com.pichillilorenzo/flutter_inappwebview',
      'com.pichillilorenzo/flutter_inappwebview_environment',
      'com.pichillilorenzo/flutter_inappwebview_cookiemanager',
    ];
    for (final channel in channels) {
      messenger.setMockMessageHandler(
        channel,
        (_) async => block('native $channel'),
      );
    }
    Object? failure;
    StackTrace? trace;
    try {
      await HttpOverrides.runZoned(
        () => IOOverrides.runZoned(
          () async {
            final startup = ProviderContainer(
              observers: [this],
              overrides: [
                appDbProvider.overrideWith((_) => block('default database')),
                apiConfigRepoProvider.overrideWith(
                  (_) => block('API provider'),
                ),
                credentialStorageProvider.overrideWith(
                  (_) => block('default credential storage'),
                ),
                credentialVaultProvider.overrideWith(
                  (_) => block('default vault'),
                ),
                sharedPreferencesProvider.overrideWith(
                  (_) => block('default preferences'),
                ),
              ],
            );
            try {
              await body();
            } finally {
              startup.dispose();
            }
          },
          createFile: (_) => block('file/default database'),
          createDirectory: (_) => block('directory/default database'),
          createLink: (_) => block('filesystem link'),
          socketConnect:
              (host, port, {sourceAddress, sourcePort = 0, timeout}) =>
                  block('socket.connect'),
          socketStartConnect: (host, port, {sourceAddress, sourcePort = 0}) =>
              block('socket.startConnect'),
        ),
        createHttpClient: (_) => block('HttpClient construction'),
      );
    } catch (error, stack) {
      failure = error;
      trace = stack;
    } finally {
      for (final channel in channels) {
        messenger.setMockMessageHandler(channel, null);
      }
    }
    // Preserve the first body/cleanup failure while retaining swallowed attempts.
    if (failure != null) Error.throwWithStackTrace(failure, trace!);
    expect(
      attempts,
      isEmpty,
      reason: 'Tripwires include construction and close.',
    );
  }
}

final class ThemeConsentBarrier {
  final entered = Completer<void>();
  final _release = Completer<void>();

  Future<void> wait() async {
    if (!entered.isCompleted) entered.complete();
    await _release.future;
  }

  void release() {
    if (!_release.isCompleted) _release.complete();
  }
}
