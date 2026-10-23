import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/state/connection_revision_provider.dart';
import 'package:glaze_flutter/core/state/chat_source_mutation_provider.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_dependencies.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';

/// Finite explicit native/startup boundaries, not a universal FFI sandbox.
/// No widgets are mounted; visuals/preferences/fonts must not evaluate at all.
final class ModelProviderIsolation extends ProviderObserver {
  final attempts = <String>[];
  final extraAllowed = <Object>{};
  Never block(String boundary) {
    attempts.add(boundary);
    throw StateError('Synthetic provider isolation boundary crossed.');
  }

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) {
    if (!{
      appDbProvider,
      credentialStorageProvider,
      credentialVaultProvider,
      supportPayloadCipherProvider,
      supportRepoProvider,
      apiConfigCredentialAdapterProvider,
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
      supportWorkspaceProvider,
      supportModelDurableWritesProvider,
      supportModelWorkspaceBindingProvider,
      supportModelDatabaseCustodyProvider,
      supportModelPrivateAdapterFactoryProvider,
      supportModelUiBridgeProvider,
      supportModelRunViewProvider,
      ...extraAllowed,
    }.contains(context.provider)) {
      block('unexpected startup provider');
    }
  }

  Future<void> run(Future<void> Function() body) async {
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
    try {
      await HttpOverrides.runZoned(
        body,
        createHttpClient: (_) => block('HttpClient construction'),
      );
    } finally {
      for (final channel in channels) {
        messenger.setMockMessageHandler(channel, null);
      }
      expect(
        attempts,
        isEmpty,
        reason:
            'Attempts remain recorded even when exceptions are swallowed, through cleanup.',
      );
    }
  }
}

/// Deterministic explicit barrier; no sleeps, polling or real network/plugin work.
final class ModelProviderBarrier {
  final entered = Completer<void>();
  final _release = Completer<void>();
  bool get released => _release.isCompleted;
  Future<void> wait() async {
    if (!entered.isCompleted) entered.complete();
    await _release.future;
  }

  void release() {
    if (!_release.isCompleted) _release.complete();
  }
}
