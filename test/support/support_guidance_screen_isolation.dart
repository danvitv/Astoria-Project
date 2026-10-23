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
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/shared/shell/nav_height_provider.dart';
import 'package:glaze_flutter/shared/shell/shell_header_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_font_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';

/// Finite presentation/local-policy graph. No workspace, policy, Ref or native
/// controller facade. These tripwires are not an OS/FFI sandbox.
final class GuidanceScreenIsolation extends ProviderObserver {
  final attempts = <String>[];
  final controls = <Object>{};

  Never block(String boundary) {
    attempts.add(boundary);
    throw StateError('Outside synthetic session-guidance UI fixture.');
  }

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) {
    if (!{
      appDbProvider,
      supportPayloadCipherProvider,
      supportRepoProvider,
      credentialStorageProvider,
      credentialVaultProvider,
      secretRedactionCoordinatorProvider,
      secretRedactorProvider,
      apiConfigRepoProvider,
      nativeProviderRuntimeProvider,
      connectionRevisionRegistryProvider,
      chatSourceMutationRegistryProvider,
      supportSessionStoreProvider,
      supportPermissionStoreProvider,
      supportConsentSelectionRepoProvider,
      supportNativeRuntimeProvider,
      supportNativeConsentControllerProvider,
      supportNativeViewProvider,
      supportModelDurableWritesProvider,
      supportModelWorkspaceBindingProvider,
      supportWorkspaceProvider,
      supportConnectionsProvider,
      appSettingsProvider,
      themeProvider,
      themeProvider.notifier,
      effectiveBgImageBytesProvider,
      uiFontFamilyProvider,
      chatFontFamilyProvider,
      navHeightProvider,
      shellHeaderProvider,
      ...controls,
    }.contains(context.provider)) {
      block('undeclared provider ${context.provider}');
    }
  }

  Future<T> guarded<T>(Future<T> Function() body) => HttpOverrides.runZoned(
    () => IOOverrides.runZoned(
      body,
      createFile: (_) => block('file/default SQLite'),
      createDirectory: (_) => block('directory'),
      createLink: (_) => block('link'),
      socketConnect: (host, port, {sourceAddress, sourcePort = 0, timeout}) =>
          block('socket.connect'),
      socketStartConnect: (host, port, {sourceAddress, sourcePort = 0}) =>
          block('socket.startConnect'),
    ),
    createHttpClient: (_) => block('default HTTP/model'),
  );

  Future<void> run(WidgetTester tester, Future<void> Function() body) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final previous = messenger.allMessagesHandler;
    messenger.allMessagesHandler = (channel, handler, message) async {
      if (message == null) return block('empty native message');
      if (channel == SystemChannels.textInput.name &&
          tester.testTextInput.isRegistered &&
          handler != null) {
        // Only Flutter's installed test input adapter receives synthetic text.
        return handler(message);
      }
      if (channel == SystemChannels.platform.name) {
        final call = SystemChannels.platform.codec.decodeMethodCall(message);
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
      }
      if (channel == SystemChannels.processText.name) {
        final call = SystemChannels.processText.codec.decodeMethodCall(message);
        if (call.method != 'ProcessText.queryTextActions' ||
            call.arguments != null) {
          return block('process text');
        }
        return SystemChannels.processText.codec.encodeSuccessEnvelope(
          <String, Object?>{},
        );
      }
      if (channel == SystemChannels.accessibility.name) {
        final event = SystemChannels.accessibility.codec.decodeMessage(message);
        if (event is Map<Object?, Object?> && event.length == 3) {
          if (event case {
            'type': 'tap',
            'data': final Map<Object?, Object?> data,
            'nodeId': final int node,
          }) {
            if (data.isEmpty && node >= 0) {
              return SystemChannels.accessibility.codec.encodeMessage(null);
            }
          }
        }
        return block('accessibility');
      }
      if (channel == SystemChannels.navigation.name) {
        final call = SystemChannels.navigation.codec.decodeMethodCall(message);
        final args = call.arguments;
        final accepted = switch (call.method) {
          'selectMultiEntryHistory' ||
          'selectSingleEntryHistory' => args == null,
          // '/' is the standalone CardView MaterialApp's original framework
          // route report. Consume metadata only: never delegate or log its state.
          'routeInformationUpdated' =>
            args is Map<Object?, Object?> &&
                args.length == 3 &&
                args.containsKey('state') &&
                {'/', '/support', '/characters'}.contains(args['uri']) &&
                args['replace'] is bool,
          _ => false,
        };
        if (!accepted) return block('navigation');
        return SystemChannels.navigation.codec.encodeSuccessEnvelope(null);
      }
      return block('native $channel');
    };
    try {
      await guarded(body);
    } finally {
      // The fixture drives the two event queues and drains original jobs BEFORE
      // returning here. Never await an empty fake-zone Future.wait after REAL.
      try {
        expect(messenger.pendingMessageCount, 0);
        expect(
          attempts,
          isEmpty,
          reason: 'Includes swallowed startup/cleanup.',
        );
      } finally {
        messenger.allMessagesHandler = previous;
      }
    }
  }
}
