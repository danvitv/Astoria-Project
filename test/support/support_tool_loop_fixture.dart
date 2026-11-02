import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/connection_revision_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/lorebook_embedding_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_model_tool_ui_ports.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_dependencies.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_workspace_binding.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_data_consent_admission.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_catalog_provider.dart';
import 'package:glaze_flutter/shared/shell/nav_height_provider.dart';
import 'package:glaze_flutter/shared/shell/shell_header_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_font_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/theme/theme_preset_storage.dart';
import 'package:glaze_flutter/shared/theme/theme_selection.dart';

import 'support_provider_model_fixture.dart';
import 'helpers/support_model_provider_fixture_isolation.dart';
import 'app_control/app_control_fixture.dart' show AppControlSettingsNotifier;
import 'app_control/app_control_memory_theme.dart';

export 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
export 'package:glaze_flutter/features/settings/app_settings_provider.dart';

void toolLoopTest(String name, Future<void> Function(ToolLoopFixture) body) {
  test(name, () async {
    final isolation = ModelProviderIsolation();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final previous = messenger.allMessagesHandler;
    messenger.allMessagesHandler = (channel, handler, message) =>
        isolation.block('native $channel');
    try {
      await HttpOverrides.runZoned(
        () => IOOverrides.runZoned(
          () async {
            final fixture = await ToolLoopFixture.create(isolation);
            try {
              await body(fixture);
            } finally {
              await fixture.close();
            }
            await messenger.platformMessagesFinished;
            expect(isolation.attempts, isEmpty);
          },
          createFile: (_) => isolation.block('file/default database'),
          createDirectory: (_) => isolation.block('directory'),
          createLink: (_) => isolation.block('link'),
          socketConnect:
              (host, port, {sourceAddress, sourcePort = 0, timeout}) =>
                  isolation.block('socket.connect'),
          socketStartConnect: (host, port, {sourceAddress, sourcePort = 0}) =>
              isolation.block('socket.startConnect'),
        ),
        createHttpClient: (_) => isolation.block('socket/HTTP'),
      );
    } finally {
      messenger.allMessagesHandler = previous;
    }
  });
}

/// Actual production model bridge AND actual action registry providers. Explicit
/// pregraph native root, memory SQLite/AEAD/vault, prefs/theme store and final HTTP.
/// No production default private provider graph is ever evaluated.
final class ToolLoopFixture {
  ToolLoopFixture(this.native, this.isolation);
  final SupportProviderModelFixture native;
  final ModelProviderIsolation isolation;
  final backing = ToolLoopThemeStore();
  final wire = <Map<String, dynamic>>[];
  final replies = <Map<String, Object?>>[];
  final displayed = <Object>[];
  final adapters = <ToolLoopAdapter>[];
  late final ProviderContainer container;
  late final SharedPreferences prefs;
  late final ThemeNotifier theme;
  late final SupportModelUiBridge bridge;
  SupportModelUiSend? active;
  bool emitterCurrent = true, displayCurrent = true;
  Future<void> Function(int)? atFetch;
  final firstFetch = Completer<void>();
  final secondFetch = Completer<void>();
  String get boundSyntheticSecret => SupportProviderModelFixture.key;

  static Future<ToolLoopFixture> create(
    ModelProviderIsolation isolation, {
    bool screen = false,
    sqlite.Database? originalNativeConnection,
  }) async {
    final native = await SupportProviderModelFixture.create(
      originalNativeConnection: originalNativeConnection,
    );
    native.service.dispose();
    final f = ToolLoopFixture(native, isolation);
    SharedPreferences.setMockInitialValues({
      'batterySaverMode': screen ? 'on' : 'off',
      'enterToSend': true,
      'showOurPicks': false,
      'hapticFeedback': false,
      'messageVibration': false,
      'lorebookBuildPrompt': 'SYNTHETIC_HIDDEN_PROMPT',
    });
    f.prefs = await SharedPreferences.getInstance();
    f.theme = ThemeNotifier(storage: f.backing);
    isolation.extraAllowed.addAll({
      supportAppActionRegistryProvider,
      appSettingsProvider,
      sharedPreferencesProvider,
      themeProvider,
    });
    if (screen) {
      isolation.extraAllowed.addAll({
        effectiveBgImageBytesProvider,
        uiFontFamilyProvider,
        chatFontFamilyProvider,
        navHeightProvider,
        shellHeaderProvider,
        supportConnectionsProvider,
        supportModelCatalogProvider,
        supportDataConsentAdmissionProvider,
      });
    }
    f.container = ProviderContainer(
      observers: [isolation],
      overrides: [
        appDbProvider.overrideWithValue(native.db),
        apiConfigRepoProvider.overrideWithValue(native.apiRepo),
        nativeProviderRuntimeProvider.overrideWithValue(native.native),
        credentialVaultProvider.overrideWithValue(native.vault),
        supportPayloadCipherProvider.overrideWithValue(native.cipher),
        supportRepoProvider.overrideWithValue(native.repo),
        secretRedactionCoordinatorProvider.overrideWithValue(native.redaction),
        connectionRevisionRegistryProvider.overrideWithValue(native.revisions),
        supportNativeRuntimeProvider.overrideWithValue(native.runtime),
        supportSessionStoreProvider.overrideWithValue(native.workspace),
        appSettingsProvider.overrideWith(
          () => AppControlSettingsNotifier(f.prefs),
        ),
        sharedPreferencesProvider.overrideWith((ref) async => f.prefs),
        themeProvider.overrideWith((ref) => f.theme),
        supportModelPrivateAdapterFactoryProvider.overrideWithValue(f.adapter),
        if (screen) ...[
          // Memory's ORIGINAL widget and native adapter share this exact root.
          // Do not introduce a child scope merely to suppress vector UI startup.
          vectorSearchAvailableProvider.overrideWithValue(false),
          supportConnectionsProvider.overrideWithValue(const []),
          supportModelCatalogProvider.overrideWithValue(null),
          supportConnectionMetadataProvider.overrideWith(
            (ref) => isolation.block('bulk metadata startup'),
          ),
          imageStorageProvider.overrideWith(
            (ref) => isolation.block('image storage'),
          ),
          effectiveBgImageBytesProvider.overrideWithValue(null),
          bgImageBytesProvider.overrideWith(
            (ref) => isolation.block('background resource'),
          ),
          wallpaperBytesProvider.overrideWith(
            (ref) => isolation.block('wallpaper resource'),
          ),
          uiFontFamilyProvider.overrideWith((ref) async => null),
          chatFontFamilyProvider.overrideWith((ref) async => null),
          navHeightProvider.overrideWith((ref) => 0),
          shellHeaderProvider.overrideWith(ShellHeaderRegistry.new),
        ],
      ],
    );
    await f.container.read(appSettingsProvider.future);
    f.container.read(themeProvider);
    await f.theme.flushPersistence();
    await native.repo.putMessage(
      SupportMessage(
        id: 'old-native-user',
        sessionId: native.session,
        role: 'user',
        body: 'ALL_PREVIOUS_USER',
        createdAt: 1,
      ),
    );
    await native.repo.putMessage(
      SupportMessage(
        id: 'old-native-assistant',
        sessionId: native.session,
        role: 'assistant',
        body: 'ALL_PREVIOUS_ASSISTANT',
        createdAt: 2,
      ),
    );
    await native.repo.createSession(
      SupportSession(
        id: 'hidden-session',
        title: 'Hidden',
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    await native.repo.putMessage(
      const SupportMessage(
        id: 'hidden-body',
        sessionId: 'hidden-session',
        role: 'user',
        body: 'SYNTHETIC_EXCLUDED_BODY',
        createdAt: 1,
      ),
    );
    f.container
        .read(supportModelWorkspaceBindingProvider)
        .attach(
          capture: () => SupportModelWorkspaceCapture(
            sessionId: native.session,
            ready: true,
            isCurrent: () => f.displayCurrent,
            publish: f.displayed.add,
          ),
          resumeLocal: () {},
        );
    f.bridge = f.container.read(supportModelUiBridgeProvider);
    if (screen) {
      // Action-loop cases start after the optional read invitation was declined.
      // This is presentation state only: no data grant or action confirmation.
      f.container
          .read(supportDataConsentAdmissionProvider.notifier)
          .markOffered();
      final workspace = f.container.read(supportWorkspaceProvider.notifier);
      await workspace.refresh();
      workspace.selectSession(native.session);
      await workspace.refresh();
      await f.container.pump();
    }
    return f;
  }

  HttpClientAdapter adapter() {
    final adapter = ToolLoopAdapter(this);
    adapters.add(adapter);
    return adapter;
  }

  SupportModelUiSend send({SupportModelToolUiPorts? toolUi}) {
    final emitter = bridge.bindEmitter(
      controller: native.controller,
      uiLifetime: native.uiLifetime,
      isEmitterCurrent: () => emitterCurrent,
      visibleConversation: const [
        SupportModelConversationMessage(
          id: 'old-native-user',
          role: 'user',
          text: 'ALL_PREVIOUS_USER',
        ),
        SupportModelConversationMessage(
          id: 'old-native-assistant',
          role: 'assistant',
          text: 'ALL_PREVIOUS_ASSISTANT',
        ),
      ],
      toolUi: toolUi,
    );
    return active = emitter.send(
      text: 'Change the delegated safe setting.',
      draftRevision: 1,
      isDraftCurrent: () => true,
    );
  }

  Map<String, Object?> call(
    String name,
    Map<String, Object?> arguments, {
    String id = 'call_1',
  }) => {
    'choices': [
      {
        'index': 0,
        'finish_reason': 'tool_calls',
        'message': {
          'role': 'assistant',
          'content': null,
          'tool_calls': [
            {
              'type': 'function',
              'id': id,
              'function': {'name': name, 'arguments': jsonEncode(arguments)},
            },
          ],
        },
      },
    ],
    'usage': {'prompt_tokens': 17, 'completion_tokens': 4, 'total_tokens': 21},
  };

  Map<String, Object?> answer([String text = 'Actual final answer']) => {
    'choices': [
      {
        'index': 0,
        'finish_reason': 'stop',
        'message': {'role': 'assistant', 'content': text},
      },
    ],
    'usage': {'prompt_tokens': 31, 'completion_tokens': 7, 'total_tokens': 38},
  };

  Future<void> close() async {
    native.sql.afterSelect = null;
    native.primitive.beforeDecrypt = null;
    container.dispose();
    await bridge.drained;
    await native.close();
  }
}

final class ToolLoopThemeStore
    implements ThemePresetStore, ThemeSelectionStore, ThemeModeStore {
  final actual = AppControlMemoryTheme();
  List<ThemePreset> get presets => actual.presets;
  String get activeId => actual.activeId;
  int get checkedWrites => actual.checkedWrites;
  set beforeFresh(Future<void> Function()? callback) =>
      actual.beforeFresh = callback;
  bool failAfterWrite = false;
  Future<void> Function()? afterWrite;
  @override
  Future<List<ThemePreset>> loadAll() => actual.loadAll();
  @override
  Future<String> loadActiveId() => actual.loadActiveId();
  @override
  Future<void> saveAll(List<ThemePreset> values) => actual.saveAll(values);
  @override
  Future<void> setActive(String id) => actual.setActive(id);
  @override
  Future<void> addPreset(ThemePreset preset) => actual.addPreset(preset);
  @override
  Future<void> removePreset(String id) => actual.removePreset(id);
  @override
  Future<ThemePreset> importFromFile(String path) =>
      actual.importFromFile(path);
  @override
  Future<ThemeSelectionStoredState> readSelectionFresh() =>
      actual.readSelectionFresh();
  @override
  Future<bool> setActiveChecked(String id) => actual.setActiveChecked(id);
  @override
  Future<bool> saveAllChecked(List<ThemePreset> values) async {
    final accepted = await actual.saveAllChecked(values);
    await afterWrite?.call();
    if (failAfterWrite) {
      throw StateError('Synthetic uncertainty after actual write.');
    }
    return accepted;
  }
}

final class ToolLoopAdapter implements HttpClientAdapter {
  ToolLoopAdapter(this.fixture);
  final ToolLoopFixture fixture;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final part in requestStream) {
        bytes.addAll(part);
      }
    }
    final request = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    fixture.wire.add(request);
    final round = fixture.wire.length;
    if (round == 1 && !fixture.firstFetch.isCompleted) {
      fixture.firstFetch.complete();
    }
    if (round == 2 && !fixture.secondFetch.isCompleted) {
      fixture.secondFetch.complete();
    }
    await fixture.atFetch?.call(round);
    if (round > fixture.replies.length) {
      throw StateError('Undeclared extra paid POST.');
    }
    return ResponseBody.fromString(
      jsonEncode(fixture.replies[round - 1]),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
