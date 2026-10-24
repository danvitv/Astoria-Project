import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/llm/transport/native_tool_types.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_app_action.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_app_action_connections.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/support_app_action_registry.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/support_app_connections_adapter.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/support_app_metadata_policy.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/support_app_navigation_adapter.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/support_app_preferences_adapter.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/support_app_theme_adapter.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_control_memory_native.dart';
import 'app_control_memory_theme.dart';

export 'package:glaze_flutter/features/support_assistant/models/support_app_action.dart';
export 'package:glaze_flutter/features/support_assistant/models/support_app_action_connections.dart';
export 'package:glaze_flutter/core/llm/transport/native_tool_types.dart';

void appControlTest(
  String name,
  Future<void> Function(AppControlFixture) body,
) {
  test(name, () async {
    final attempts = <String>[];
    Never block(String what) {
      attempts.add(what);
      throw StateError('Outside synthetic app-control fixture.');
    }

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final previous = messenger.allMessagesHandler;
    messenger.allMessagesHandler = (channel, handler, message) =>
        block('native $channel');
    try {
      await HttpOverrides.runZoned(
        () => IOOverrides.runZoned(
          () async {
            final fixture = AppControlFixture();
            try {
              await fixture.initialize();
              await body(fixture);
            } finally {
              fixture.container.dispose();
              await fixture.db.close();
              await messenger.platformMessagesFinished;
              expect(attempts, isEmpty);
            }
          },
          createFile: (_) => block('file/default database'),
          createDirectory: (_) => block('directory'),
          createLink: (_) => block('link'),
        ),
        createHttpClient: (_) => block('HTTP'),
      );
    } finally {
      messenger.allMessagesHandler = previous;
    }
  });
}

/// Real owning notifier methods + real Drift memory repository. Only backing
/// stores/native admission are synthetic; no app/default graph/key/vault reads.
final class AppControlFixture {
  final db = AppControlMemoryDatabase(NativeDatabase.memory());
  final mutations = AppControlMemoryMutationPort();
  final backing = AppControlMemoryTheme();
  final confirmation = AppControlConfirmation();
  final navigation = AppControlNavigation();
  final cancelToken = CancelToken();
  var redactor = SecretRedactor(
    knownSecrets: const ['SYNTHETIC_SECRET_CANARY'],
  );
  late SharedPreferences prefs;
  late ProviderContainer container;
  late ThemeNotifier theme;
  late ApiConfigRepo api;
  late AppControlNativeMetadata native;
  late SupportAppActionRegistry registry;
  bool runCurrent = true, rootCurrent = true;
  Future<void> Function()? beforeSettingsRead;
  Future<void> Function()? beforeSettingsPersistence;
  Future<void> Function()? beforeSettingsBuild;
  Future<bool> Function()? readPowerSaveMode;

  Future<void> initialize() async {
    SharedPreferences.setMockInitialValues({
      'batterySaverMode': 'off',
      'lorebookBuildPrompt': 'SYNTHETIC_PRIVATE_PROMPT',
    });
    prefs = await SharedPreferences.getInstance();
    theme = ThemeNotifier(storage: backing);
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWith((ref) async => prefs),
        appSettingsProvider.overrideWith(
          () => AppControlSettingsNotifier(
            prefs,
            readPreferences: () async {
              await beforeSettingsPersistence?.call();
              return prefs;
            },
            readPowerSaveMode: () async =>
                await readPowerSaveMode?.call() ?? false,
            beforeBuild: () async => await beforeSettingsBuild?.call(),
          ),
        ),
        themeProvider.overrideWith((ref) => theme),
      ],
    );
    await container.read(appSettingsProvider.future);
    container.read(themeProvider); // Own/dispose the actual notifier.
    await theme.flushPersistence();
    api = ApiConfigRepo(
      db,
      keylessMutations: mutations,
      onMutationStarted: mutations.onMutationStarted,
    );
    native = AppControlNativeMetadata(mutations);
    registry = SupportAppActionRegistry(
      isOriginalOwnerCurrent: () => rootCurrent,
      metadata: SupportAppRedactedMetadataPolicy(
        currentRedactor: () => redactor,
      ),
      adapters: [
        SupportAppPreferencesAdapter(
          notifier: container.read(appSettingsProvider.notifier),
          readReady: () async {
            await beforeSettingsRead?.call();
            return container.read(appSettingsProvider.future);
          },
          currentSettings: () => container.read(appSettingsProvider).value,
        ),
        SupportAppThemeAdapter(theme: theme),
        SupportAppConnectionsAdapter(repo: api, native: native),
        SupportAppNavigationAdapter(),
      ],
    );
  }

  SupportAppActionContext context({
    bool withConfirmation = true,
    bool withNavigation = true,
    bool allowChanges = true,
  }) => SupportAppActionContext(
    runId: 'synthetic-run',
    sessionId: 'synthetic-session',
    cancelToken: cancelToken,
    isCurrent: () => runCurrent,
    allowReversibleChanges: allowChanges,
    confirmation: withConfirmation ? confirmation : null,
    navigation: withNavigation ? navigation : null,
  );

  Future<NativeToolResult> call(
    String name, [
    Map<String, Object?> arguments = const {},
    SupportAppActionContext? original,
  ]) => registry.execute(
    NativeToolCall(id: 'synthetic-call', name: name, arguments: arguments),
    original ?? context(),
  );

  Future<String> createConnection() async {
    final result = await call('astoria_connection_create', {
      'template': 'openaiChat',
      'name': 'SYNTHETIC_CONNECTION',
      'model': 'synthetic-model',
      'maxTokens': 512,
      'contextSize': 4096,
    });
    expect(result.content['code'], 'completed');
    return (result.content['data']! as Map)['connectionId']! as String;
  }
}

final class AppControlSettingsNotifier extends AppSettingsNotifier {
  AppControlSettingsNotifier(
    this.prefs, {
    super.readPreferences,
    super.readPowerSaveMode,
    this.beforeBuild,
  });
  final SharedPreferences prefs;
  final Future<void> Function()? beforeBuild;
  @override
  Future<AppSettings> build() async {
    await beforeBuild?.call();
    return AppSettingsPreferences.read(prefs);
  }
}

final class AppControlMemoryDatabase extends AppDatabase {
  AppControlMemoryDatabase(super.executor) : super.forTesting();
  @override
  MigrationStrategy get migration =>
      MigrationStrategy(onCreate: (m) => m.createAll());
}

final class AppControlConfirmation implements SupportAppConfirmationPort {
  bool accept = true, uiCurrent = true;
  SupportAppConfirmationRequest? last;
  SupportAppConfirmationRequest? replaceWith;
  Future<void> Function(SupportAppConfirmationRequest)? beforeDecision;
  @override
  Future<SupportAppConfirmationLease?> confirm(
    SupportAppConfirmationRequest request,
  ) async {
    last = request;
    await beforeDecision?.call(request);
    if (!accept) return null;
    return SupportAppConfirmationLease(
      request: replaceWith ?? request,
      isOriginalUiCurrent: () => uiCurrent,
    );
  }
}

final class AppControlNavigation implements SupportAppNavigationPort {
  final opened = <SupportAppDestination>[];
  @override
  Future<bool> open(
    SupportAppDestination destination,
    SupportAppActionContext context,
  ) async {
    if (!context.current) return false;
    opened.add(destination);
    return true;
  }
}

final class AppControlNativeMetadata implements SupportAppConnectionNativePort {
  AppControlNativeMetadata(this.mutations);
  final AppControlMemoryMutationPort mutations;
  @override
  Future<SupportAppCredentialMetadata?> readCredentialMetadata(
    String id,
    SupportAppActionContext context,
  ) async => context.current
      ? const SupportAppCredentialMetadata(configured: false, characterCount: 0)
      : null;
  @override
  Object? observeRevision() => mutations.revisionFor('synthetic-metadata');
  @override
  bool isRevisionCurrent(Object revision) => observeRevision() == revision;
  @override
  String? standardEndpoint(
    SupportAppConnectionTemplate template,
    String model,
  ) => 'https://synthetic-provider.invalid/v1/chat/completions';
}
