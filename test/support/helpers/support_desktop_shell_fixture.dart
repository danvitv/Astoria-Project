import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_consent_selection_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/state/active_selection_provider.dart';
import 'package:glaze_flutter/core/state/character_provider.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/features/chat_history/chat_history_provider.dart';
import 'package:glaze_flutter/features/personas/persona_list_provider.dart';
import 'package:glaze_flutter/features/presets/preset_list_provider.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_runtime.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_store.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/features/support_assistant/support_assistant_screen.dart';
import 'package:glaze_flutter/shared/shell/desktop/desktop_floating_provider.dart';
import 'package:glaze_flutter/shared/shell/desktop/desktop_glossary_popup.dart';
import 'package:glaze_flutter/shared/shell/desktop/desktop_shell.dart';
import 'package:glaze_flutter/shared/shell/desktop/sidebar_sheet_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_font_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/theme/theme_preset_storage.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';

import 'support_native_widget_fixture.dart' show NativeWidgetTranslations;

/// ShellRoute only supplies GoRouter context; this is NOT the production router.
/// Every route stays in the actual DesktopShell. No App/catalog/bootstrap mounts.
GoRouter testGoRouterShellRoute({String initialLocation = '/support'}) =>
    GoRouter(
      initialLocation: initialLocation,
      routes: [
        ShellRoute(
          builder: (_, _, child) => DesktopShell(child: child),
          routes: [
            GoRoute(
              path: '/support',
              builder: (_, _) => const SupportAssistantScreen(),
            ),
            GoRoute(
              path: '/characters',
              builder: (_, _) => const Material(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Synthetic characters route'),
                      SizedBox(
                        width: 180,
                        child: TextField(
                          key: ValueKey('synthetic_regular_focus'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );

/// Pure-memory UI state. Native permissions are deliberately unavailable: real
/// widgets/controller/view, but no selected session, DB construction or reads.
class SupportDesktopShellFixture {
  SupportDesktopShellFixture({
    bool forceMobile = false,
    SupportSettingsAvailability availability =
        SupportSettingsAvailability.available,
    String? error,
  }) : settings = ShellAppSettings(forceMobile),
       workspace = ShellWorkspace(availability: availability, error: error) {
    permissions = SupportPermissionStore(repo);
    runtime = SupportNativeRuntime(
      permissions: permissions,
      resolveRecipient: (_) async => unexpected('recipient resolution'),
      loadSelectedConnection: (_, _) async => unexpected('selected connection'),
      configurationRevision: () => 1,
      configurationStable: () => true,
    );
    controller = SupportNativeConsentController(
      runtime: runtime,
      readMessages: (_, _, _) async => unexpected('native message metadata'),
    );
    selector = SupportConsentSelectionRepo(
      db: db,
      supportRepo: repo,
      currentRedactor: SecretRedactor.new,
    );
  }

  final ShellAppSettings settings;
  final ShellWorkspace workspace;
  final db = _NeverDatabase();
  final repo = _NeverSupportRepo();
  final unexpectedCalls = <String>[];
  late final SupportPermissionStore permissions;
  late final SupportNativeRuntime runtime;
  late final SupportNativeConsentController controller;
  late final SupportConsentSelectionRepo selector;
  late final SharedPreferences prefs;

  Never unexpected(String operation) {
    unexpectedCalls.add(operation);
    throw StateError('Unexpected shell fixture startup: $operation');
  }

  Future<void> initialize(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    prefs = await SharedPreferences.getInstance();
  }

  Widget app(
    GoRouter router, {
    String language = 'ru',
    double textScale = 1,
  }) => ProviderScope(
    // One flat scope before shell/sidebar/header/native evaluation. The
    // shell's own inner scope overrides ONLY its resizer controllers.
    overrides: [
      sharedPreferencesProvider.overrideWithValue(AsyncData(prefs)),
      appSettingsProvider.overrideWith(() => settings),
      supportWorkspaceProvider.overrideWith(() => workspace),
      supportConnectionsProvider.overrideWithValue(const []),
      supportConnectionMetadataProvider.overrideWith(
        (_) => unexpected('connection list'),
      ),
      supportSessionStoreProvider.overrideWith(
        (_) => unexpected('workspace store'),
      ),
      supportRepoProvider.overrideWithValue(repo),
      appDbProvider.overrideWith((_) => unexpected('database factory')),
      supportPayloadCipherProvider.overrideWith(
        (_) => unexpected('payload cipher'),
      ),
      credentialVaultProvider.overrideWith((_) => unexpected('OS vault')),
      apiConfigRepoProvider.overrideWith((_) => unexpected('API repository')),
      supportPermissionStoreProvider.overrideWithValue(permissions),
      supportNativeRuntimeProvider.overrideWithValue(runtime),
      supportNativeConsentControllerProvider.overrideWithValue(controller),
      supportConsentSelectionRepoProvider.overrideWithValue(selector),
      charactersProvider.overrideWith(_EmptyCharacters.new),
      chatHistoryProvider.overrideWith(_EmptyHistory.new),
      personaListProvider.overrideWith(_EmptyPersonas.new),
      presetListProvider.overrideWith(_EmptyPresets.new),
      activePresetIdProvider.overrideWith((_) => null),
      activePersonaIdProvider.overrideWith((_) => null),
      personaConnectionsProvider.overrideWith(
        (_) => const PersonaConnections(),
      ),
      imageStorageProvider.overrideWith((_) => unexpected('image storage')),
      themeProvider.overrideWith(
        (_) => ThemeNotifier(storage: _MemoryThemeStore()),
      ),
      effectiveBgImageBytesProvider.overrideWithValue(null),
      wallpaperBytesProvider.overrideWith((_) => unexpected('wallpaper')),
      uiFontFamilyProvider.overrideWith((_) async => null),
      chatFontFamilyProvider.overrideWith((_) async => null),
      desktopFloatingStackProvider.overrideWith((_) => []),
      glossaryPopupVisibleProvider.overrideWith((_) => false),
      glossaryPopupTermProvider.overrideWith((_) => 'synthetic-retained-term'),
      rightSidebarPanelProvider.overrideWith((_) => null),
    ],
    child: EasyLocalization(
      supportedLocales: const [Locale('ru'), Locale('en', 'US')],
      startLocale: language == 'ru'
          ? const Locale('ru')
          : const Locale('en', 'US'),
      saveLocale: false,
      path: 'committed-translations',
      assetLoader: const NativeWidgetTranslations(),
      child: Builder(
        builder: (context) => MaterialApp.router(
          locale: context.locale,
          supportedLocales: context.supportedLocales,
          localizationsDelegates: context.localizationDelegates,
          theme: ThemeData.dark(),
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
        ),
      ),
    ),
  );

  void expectNoExternalWork() {
    expect(unexpectedCalls, isEmpty);
    expect(db.calls, isEmpty);
    expect(repo.calls, isEmpty);
    expect(runtime.sessionId, isEmpty);
    expect(runtime.recipientConfirmed, isFalse);
  }

  void dispose() => runtime.dispose();
}

class ShellAppSettings extends AppSettingsNotifier {
  ShellAppSettings(this.forceMobile);
  final bool forceMobile;
  @override
  Future<AppSettings> build() async =>
      AppSettings(forceMobileLayout: forceMobile, batterySaver: true);
  void setForceMobile(bool value) =>
      state = AsyncData(state.requireValue.copyWith(forceMobileLayout: value));
}

class ShellWorkspace extends SupportWorkspaceNotifier {
  ShellWorkspace({required this.availability, this.error});
  final SupportSettingsAvailability availability;
  final String? error;
  int creations = 0, retries = 0;
  @override
  SupportWorkspaceState build() => SupportWorkspaceState(
    sessions: [
      for (final id in ['first', 'second'])
        SupportSessionSummary(
          id: id,
          title: 'Synthetic $id session',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
    ],
    activeSessionId: 'first',
    settingsAvailability: availability,
    isLoading: false,
    error: error,
  );
  @override
  void selectSession(String id) => state = state.copyWith(activeSessionId: id);
  @override
  Future<String?> createNewSession({String? title}) async {
    creations++;
    return 'synthetic-new-$creations';
  }

  @override
  Future<bool> refresh() async {
    retries++;
    return false;
  }

  @override
  Future<bool> sendUserMessage(String text) async => false;
}

class _EmptyCharacters extends CharactersNotifier {
  @override
  Future<List<Character>> build() async => [];
}

class _EmptyHistory extends ChatHistoryNotifier {
  @override
  Future<List<ChatSessionInfo>> build() async => [];
}

class _EmptyPersonas extends PersonaListNotifier {
  @override
  Future<List<Persona>> build() async => [];
}

class _EmptyPresets extends PresetListNotifier {
  @override
  Future<List<Preset>> build() async => [];
}

class _NeverDatabase implements AppDatabase {
  final calls = <Symbol>[];
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation.memberName);
    throw StateError('Unexpected database access');
  }
}

class _NeverSupportRepo implements SupportRepo {
  final calls = <Symbol>[];
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation.memberName);
    throw StateError('Unexpected support repository access');
  }
}

class _MemoryThemeStore implements ThemePresetStore {
  @override
  Future<List<ThemePreset>> loadAll() async => [
    const ThemeSettings().activePreset,
  ];
  @override
  Future<String> loadActiveId() async => 'default';
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected theme write');
}

/// DropTarget.init only installs an incoming channel handler in desktop_drop
/// 0.8.3. No drop events are injected; any outgoing platform work is rejected.
void installShellPlatformTripwires(WidgetTester tester) {
  const channel = MethodChannel('desktop_drop');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    channel,
    (_) async => throw StateError('Unexpected native drop operation'),
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    ),
  );
}
