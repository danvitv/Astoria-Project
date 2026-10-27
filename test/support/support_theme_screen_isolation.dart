import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/state/chat_source_mutation_provider.dart';
import 'package:glaze_flutter/core/state/connection_revision_provider.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_dependencies.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_theme_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/shared/shell/nav_height_provider.dart';
import 'package:glaze_flutter/shared/shell/shell_header_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_font_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';

/// Explicit UI graph, not the low-level fixture's visual-free allowlist and not
/// blanket provider permission. Finite guards are NOT an OS/FFI sandbox.
final class ThemeScreenIsolation extends ProviderObserver {
  final attempts = <String>[];
  final controls = <Object>{};
  Never block(String boundary) {
    attempts.add(boundary);
    throw StateError('Outside owned installed-theme screen fixture.');
  }

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) {
    // The original metadata lookup returns null for the overridden legacy API
    // repository. This fixture never owns a native provider recipient.
    if (identical(context.provider, nativeProviderRuntimeProvider) &&
        value != null) {
      block('native provider recipient');
    }
    if (!{
      appDbProvider,
      supportPayloadCipherProvider,
      supportRepoProvider,
      credentialStorageProvider,
      credentialVaultProvider,
      apiConfigRepoProvider,
      nativeProviderRuntimeProvider,
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
      supportModelDatabaseCustodyProvider,
      supportModelUiBridgeProvider,
      supportModelRunViewProvider,
      supportModelPrivateAdapterFactoryProvider,
      supportWorkspaceProvider,
      supportThemeActionCustodyProvider,
      supportThemeOriginalHandlesProvider,
      supportThemeActionServiceProvider,
      supportThemeUiBindingProvider,
      supportThemePresentationProvider,
      themeProvider,
      themeProvider.notifier,
      appSettingsProvider,
      effectiveBgImageBytesProvider,
      uiFontFamilyProvider,
      chatFontFamilyProvider,
      navHeightProvider,
      shellHeaderProvider,
      supportConnectionsProvider,
      ...controls,
    }.contains(context.provider)) {
      block('unexpected UI provider ${context.provider}');
    }
  }

  /// runAsync may leave the widget fake zone. Reinstall the SAME recording
  /// I/O guards in each real issue/init turn, before constructing any owner.
  Future<T> guarded<T>(Future<T> Function() body) => HttpOverrides.runZoned(
    () => IOOverrides.runZoned(
      body,
      createFile: (_) => block('file/default DB'),
      createDirectory: (_) => block('directory/default DB'),
      createLink: (_) => block('link'),
      socketConnect: (host, port, {sourceAddress, sourcePort = 0, timeout}) =>
          block('socket.connect'),
      socketStartConnect: (host, port, {sourceAddress, sourcePort = 0}) =>
          block('socket.startConnect'),
    ),
    createHttpClient: (_) => block('HTTP/model construction'),
  );

  Future<void> run(Future<void> Function() body) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final previous = messenger.allMessagesHandler;
    messenger.allMessagesHandler = (channel, handler, message) async {
      // Inspect before invoking any existing handler. Unknown startup and even
      // swallowed clipboard/resource failures remain recorded THROUGH teardown.
      if (message == null) {
        return block('native $channel');
      }
      if (channel == SystemChannels.navigation.name) {
        final MethodCall call;
        try {
          call = SystemChannels.navigation.codec.decodeMethodCall(message);
        } catch (_) {
          return block('malformed navigation metadata');
        }
        final args = call.arguments;
        // These framework history reports are native-platform no-ops. Neither
        // their state nor their route is forwarded, retained, or logged.
        final accepted = switch (call.method) {
          'selectMultiEntryHistory' => args == null,
          'routeInformationUpdated' =>
            args is Map<Object?, Object?> &&
                args.length == 3 &&
                args.containsKey('state') &&
                {
                  '/support',
                  '/characters',
                  '/menu/themes',
                }.contains(args['uri']) &&
                args['replace'] is bool,
          _ => false,
        };
        if (!accepted) return block('unexpected navigation metadata');
        return SystemChannels.navigation.codec.encodeSuccessEnvelope(null);
      }
      if (channel == SystemChannels.accessibility.name) {
        final Object? event;
        try {
          event = SystemChannels.accessibility.codec.decodeMessage(message);
        } catch (_) {
          return block('malformed accessibility metadata');
        }
        // Feedback.forTap sends only empty data and a semantics-node identity.
        // A BasicMessageChannel reply uses its message codec, not an envelope.
        if (event is Map<Object?, Object?> && event.length == 3) {
          if (event case {
            'type': 'tap',
            'data': final Map<Object?, Object?> data,
            'nodeId': final int nodeId,
          }) {
            if (data.isEmpty && nodeId >= 0) {
              return SystemChannels.accessibility.codec.encodeMessage(null);
            }
          }
        }
        return block('unexpected accessibility metadata');
      }
      if (channel == SystemChannels.processText.name) {
        final MethodCall call;
        try {
          call = SystemChannels.processText.codec.decodeMethodCall(message);
        } catch (_) {
          return block('malformed process-text metadata');
        }
        if (call.method != 'ProcessText.queryTextActions' ||
            call.arguments != null) {
          return block('unexpected process-text metadata');
        }
        // Simulate no external actions for this metadata-only query. Never
        // delegate discovery or text-bearing ProcessText.processTextAction.
        return SystemChannels.processText.codec.encodeSuccessEnvelope(
          <Object?, Object?>{},
        );
      }
      if (channel != SystemChannels.platform.name) {
        return block('native $channel');
      }
      final MethodCall call;
      try {
        call = SystemChannels.platform.codec.decodeMethodCall(message);
      } catch (_) {
        return block('malformed platform metadata');
      }
      final Object? value = switch (call.method) {
        'Clipboard.hasStrings' => <String, bool>{'value': false},
        'LiveText.isLiveTextInputAvailable' => false,
        'HapticFeedback.vibrate' ||
        'SystemSound.play' ||
        'SystemChrome.setSystemUIOverlayStyle' ||
        'SystemChrome.setApplicationSwitcherDescription' => null,
        _ => block('platform ${call.method}'),
      };
      return SystemChannels.platform.codec.encodeSuccessEnvelope(value);
    };
    Object? failure;
    StackTrace? trace;
    try {
      await guarded(body);
    } catch (error, stack) {
      failure = error;
      trace = stack;
    } finally {
      try {
        // Future.wait([]) is already complete in the caller's FAKE zone. After
        // a REAL issue returns, awaiting that empty Future can strand its FAKE
        // continuation with no remaining REAL task to drive another flush.
        // Zero pending messages needs no drain; actual pending calls still do.
        if (messenger.pendingMessageCount != 0) {
          await messenger.platformMessagesFinished;
        }
        expect(messenger.pendingMessageCount, 0);
        expect(attempts, isEmpty, reason: 'Includes swallowed setup/cleanup.');
      } catch (error, stack) {
        failure ??= error;
        trace ??= stack;
      }
      messenger.allMessagesHandler = previous;
    }
    if (failure != null) Error.throwWithStackTrace(failure, trace!);
  }
}
