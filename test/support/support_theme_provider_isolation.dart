import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/state/chat_source_mutation_provider.dart';
import 'package:glaze_flutter/core/state/connection_revision_provider.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_dependencies.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_theme_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';

/// Pre-evaluation finite provider allowlist plus blanket native/HTTP/file/socket
/// tripwires. Memory SQLite FFI is allowed, not a universal process/FFI sandbox.
final class ThemeProviderIsolation extends ProviderObserver {
  final attempts = <String>[];
  final controls = <Object>{};
  Never block(String boundary) {
    attempts.add(boundary);
    throw StateError('Outside declared local theme provider fixture.');
  }

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) {
    if (!{
      appDbProvider,
      supportPayloadCipherProvider,
      supportRepoProvider,
      credentialStorageProvider,
      credentialVaultProvider,
      apiConfigRepoProvider,
      connectionRevisionRegistryProvider,
      chatSourceMutationRegistryProvider,
      secretRedactionCoordinatorProvider,
      secretRedactorProvider,
      supportSessionStoreProvider,
      supportPermissionStoreProvider,
      supportConsentSelectionRepoProvider,
      supportNativeRuntimeProvider,
      supportNativeConsentControllerProvider,
      supportNativeViewProvider,
      supportModelDurableWritesProvider,
      supportModelWorkspaceBindingProvider,
      supportWorkspaceProvider,
      supportThemeActionCustodyProvider,
      supportThemeOriginalHandlesProvider,
      supportThemeActionServiceProvider,
      supportThemeUiBindingProvider,
      supportThemePresentationProvider,
      themeProvider,
      themeProvider.notifier,
      ...controls,
    }.contains(context.provider)) {
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
          body,
          createFile: (_) => block('file/default DB'),
          createDirectory: (_) => block('directory/default DB'),
          createLink: (_) => block('link'),
          socketConnect:
              (host, port, {sourceAddress, sourcePort = 0, timeout}) =>
                  block('socket.connect'),
          socketStartConnect: (host, port, {sourceAddress, sourcePort = 0}) =>
              block('socket.startConnect'),
        ),
        createHttpClient: (_) => block('HTTP/model construction'),
      );
    } catch (error, stack) {
      failure = error;
      trace = stack;
    } finally {
      try {
        await messenger.platformMessagesFinished;
        expect(
          attempts,
          isEmpty,
          reason: 'Includes swallowed cleanup attempts.',
        );
      } catch (error, stack) {
        failure ??= error;
        trace ??= stack;
      }
      messenger.allMessagesHandler = previous;
    }
    if (failure != null) Error.throwWithStackTrace(failure, trace!);
  }
}
