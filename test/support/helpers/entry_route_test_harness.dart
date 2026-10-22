import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:glaze_flutter/core/constants/support_assistant_availability.dart';
import 'package:glaze_flutter/core/db/repositories/support_consent_selection_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/character_folder.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/core/navigation/router.dart';
import 'package:glaze_flutter/core/state/active_selection_provider.dart';
import 'package:glaze_flutter/core/state/character_folder_provider.dart';
import 'package:glaze_flutter/core/state/character_provider.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/dev_mode_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/features/catalog/catalog_provider.dart';
import 'package:glaze_flutter/features/catalog/chub_account_provider.dart';
import 'package:glaze_flutter/features/catalog/third_party_providers_provider.dart';
import 'package:glaze_flutter/features/character_list/filtered_characters_provider.dart';
import 'package:glaze_flutter/features/chat_history/chat_history_provider.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_provider.dart';
import 'package:glaze_flutter/features/extensions/providers/extension_presets_provider.dart';
import 'package:glaze_flutter/features/extensions/providers/extensions_settings_provider.dart';
import 'package:glaze_flutter/features/personas/persona_list_provider.dart';
import 'package:glaze_flutter/features/picks/picks_models.dart';
import 'package:glaze_flutter/features/picks/picks_provider.dart';
import 'package:glaze_flutter/features/presets/preset_list_provider.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/shared/shell/desktop/desktop_layout_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_font_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';

import 'entry_route_fakes.dart';
import 'support_native_fixture.dart';
import 'support_native_widget_fixture.dart' show NativeWidgetTranslations;

/// Actual buildRouter + shell, with ONE flat, fully prepared container. No App,
/// inherited production container, nested test scope, real credentials or files.
/// Native memory ports are the settled fixture; catalog/theme constructors are
/// replaced rather than subclassed. Offstage branches get the same overrides.
class EntryRouteTestHarness {
  EntryRouteTestHarness({
    required SharedPreferences prefs,
    bool? available,
    bool showOurPicks = false,
    List<Character> characters = const [],
    List<CharacterFolder> folders = const [],
    EntryDataState initialState = EntryDataState.data,
    EntryDataState charactersState = EntryDataState.data,
    String location = '/characters',
  }) {
    final supportAllowed = available ?? supportAssistantWorkspaceEnabled;
    workspace = EntryWorkspace(() {
      if (!supportAllowed) block('disabled support workspace startup');
      supportStarts++;
    });
    characterOwner = EntryCharacters(characters, charactersState);
    router = buildRouter(
      GlobalKey<NavigatorState>(),
      isForceMobile: () => forceMobile,
      // Null exercises the ordinary production default, not a fake false gate.
      isSupportAssistantAvailable: available == null ? null : () => available,
    );
    router.go(location);
    container = ProviderContainer(
      overrides: [
        routerProvider.overrideWithValue(router),
        forceMobileLayoutProvider.overrideWith((_) => forceMobile),
        appSettingsProvider.overrideWith(() => EntrySettings(showOurPicks)),
        sharedPreferencesProvider.overrideWith((_) async => prefs),
        charactersProvider.overrideWith(() => characterOwner),
        infiniteCharactersProvider.overrideWith2(
          (key) => EntryInfinite(key, characters, initialState),
        ),
        // Only fixture rows are queryable. Query wiring, not filtering algorithm
        // correctness, is the claim here; no token/DB/image work is delegated.
        filteredCharactersProvider.overrideWith((ref, query) {
          queries.add(query);
          return characters
              .where(
                (c) =>
                    !c.hidden &&
                    query.folderId == null &&
                    (query.search.isEmpty ||
                        c.name.toLowerCase().contains(
                          query.search.toLowerCase(),
                        )) &&
                    (!query.favOnly || c.fav) &&
                    query.tags.every(c.tags.contains) &&
                    (!query.hasTokenFilter ||
                        (c.tokenCount >= query.minTokens &&
                            c.tokenCount <= query.maxTokens)),
              )
              .toList();
        }),
        characterFoldersProvider.overrideWith((_) => Stream.value(folders)),
        folderMembershipsProvider.overrideWith(
          (_) => Stream.value(FolderMemberships.empty),
        ),
        variantGroupStatsProvider.overrideWith((_) => Stream.value(const {})),
        characterVariantsProvider.overrideWith(
          (_, _) => Stream.value(characters),
        ),
        characterSessionCountsProvider.overrideWith(
          (_) => Stream.value(const {}),
        ),
        chatHistoryProvider.overrideWith(EntryHistory.new),
        personaListProvider.overrideWith(EntryPersonas.new),
        presetListProvider.overrideWith(EntryPresets.new),
        activePersonaIdProvider.overrideWith((_) => null),
        activePresetIdProvider.overrideWith((_) => null),
        personaConnectionsProvider.overrideWith(
          (_) => const PersonaConnections(),
        ),
        devModeProvider.overrideWith(EntryDevDisabled.new),
        catalogProvider.overrideWith((_) => EntryCatalog(block)),
        catalogVisibleProvider.overrideWithValue(false),
        enabledCatalogProvidersProvider.overrideWithValue(const []),
        catalogMasterEnabledProvider.overrideWith(EntryCatalogDisabled.new),
        thirdPartyProvidersProvider.overrideWith(EntryThirdPartiesDisabled.new),
        chubAccountProvider.overrideWith(EntryAnonymousChub.new),
        picksIndexProvider.overrideWith((_) => const PicksIndex()),
        themeProvider.overrideWith((_) => EntryTheme(block)),
        effectiveBgImageBytesProvider.overrideWithValue(null),
        bgImageBytesProvider.overrideWith(
          (_) => block('background image files'),
        ),
        wallpaperBytesProvider.overrideWith((_) => block('native wallpaper')),
        uiFontFamilyProvider.overrideWith((_) async => null),
        chatFontFamilyProvider.overrideWith((_) async => null),
        // Real memory-only native ports, installed before any screen evaluates.
        appDbProvider.overrideWithValue(native.database.db),
        supportRepoProvider.overrideWith((_) {
          if (!supportAllowed) block('disabled support repository startup');
          return native.database.repoB;
        }),
        supportPayloadCipherProvider.overrideWith((_) {
          if (!supportAllowed) block('disabled support cipher startup');
          return native.database.cipher;
        }),
        secretRedactorProvider.overrideWith(
          () => EntryRedactor(native.redactor),
        ),
        apiConfigRepoProvider.overrideWithValue(native.api),
        supportPermissionStoreProvider.overrideWith((_) {
          if (!supportAllowed) block('disabled support permissions startup');
          return native.database.a;
        }),
        supportConsentSelectionRepoProvider.overrideWith((_) {
          if (!supportAllowed) block('disabled support selector startup');
          return SupportConsentSelectionRepo(
            db: native.database.db,
            supportRepo: native.database.repoB,
            currentRedactor: () => native.redactor,
          );
        }),
        supportNativeRuntimeProvider.overrideWith((_) {
          if (!supportAllowed) block('disabled native runtime startup');
          return native.runtime;
        }),
        supportNativeConsentControllerProvider.overrideWith((_) {
          if (!supportAllowed) block('disabled native controller startup');
          return native.controller;
        }),
        supportWorkspaceProvider.overrideWith(() => workspace),
        supportConnectionsProvider.overrideWith((_) {
          if (!supportAllowed) block('disabled support connections startup');
          return const [];
        }),
        supportConnectionMetadataProvider.overrideWith(
          (_) => block('bulk support connection metadata'),
        ),
        supportSessionStoreProvider.overrideWith(
          (_) => block('supportSessionStoreProvider'),
        ),
        // Deny known swallowed constructor/background paths, as in launcher tests.
        characterRepoProvider.overrideWith(
          (_) => block('characterRepoProvider'),
        ),
        characterFolderRepoProvider.overrideWith(
          (_) => block('characterFolderRepoProvider'),
        ),
        chatRepoProvider.overrideWith((_) => block('chatRepoProvider')),
        personaRepoProvider.overrideWith((_) => block('personaRepoProvider')),
        presetRepoProvider.overrideWith((_) => block('presetRepoProvider')),
        lorebookRepoProvider.overrideWith((_) => block('lorebookRepoProvider')),
        imageStorageProvider.overrideWith((_) => block('imageStorageProvider')),
        migrationServiceProvider.overrideWith(
          (_) => block('migrationServiceProvider'),
        ),
        credentialStorageProvider.overrideWith(
          (_) => block('credentialStorageProvider'),
        ),
        credentialVaultProvider.overrideWith(
          (_) => block('credentialVaultProvider'),
        ),
        extensionPresetsProvider.overrideWith(
          (_) => block('extensionPresetsProvider'),
        ),
        extensionsSettingsProvider.overrideWith(
          (_) => block('extensionsSettingsProvider'),
        ),
        extensionPresetsRepoProvider.overrideWith(
          (_) => block('extensionPresetsRepoProvider'),
        ),
        syncServiceProvider.overrideWith((_) => block('syncServiceProvider')),
        llmRequestCaptureInstallationProvider.overrideWith(
          (_) => block('request capture startup'),
        ),
      ],
    );
  }

  final native = NativeFixture(); // Unseeded; no selected API/model/history.
  final unexpectedAccess = <String>[];
  final queries = <CharacterQuery>[];
  late final EntryWorkspace workspace;
  late final EntryCharacters characterOwner;
  late final GoRouter router;
  late final ProviderContainer container;
  int supportStarts = 0;
  bool forceMobile = false;

  Never block(String boundary) {
    unexpectedAccess.add(boundary);
    throw StateError('Offline actual-route fixture reached $boundary');
  }

  Widget scope({
    Widget? home,
    Locale locale = const Locale('ru'),
    bool localized = true,
  }) {
    const locales = [Locale('ru'), Locale('en'), Locale('en', 'US')];
    Widget buildApp(BuildContext context) {
      final appLocale = localized ? context.locale : locale;
      final delegates = localized ? context.localizationDelegates : null;
      Widget verifyHost(BuildContext context, Widget? child) {
        if (localized) {
          expect(Localizations.localeOf(context), locale);
          expect(trExists('support_assistant_entry', context: context), isTrue);
        }
        return child!;
      }

      // MaterialApp owns the nearest Localizations. An outer Localizations
      // wrapper is shadowed unless these delegates are installed on the app,
      // exactly as in production. Exercise public context translation before
      // descendants build; never rely on easy_localization's global instance.
      return home == null
          ? MaterialApp.router(
              routerConfig: router,
              locale: appLocale,
              supportedLocales: locales,
              localizationsDelegates: delegates,
              builder: verifyHost,
            )
          : MaterialApp(
              home: home,
              locale: appLocale,
              supportedLocales: locales,
              localizationsDelegates: delegates,
              builder: verifyHost,
            );
    }

    Widget host = Builder(builder: buildApp);
    if (localized) {
      host = EasyLocalization(
        supportedLocales: locales,
        startLocale: locale,
        saveLocale: false,
        path: 'committed-translations',
        assetLoader: const NativeWidgetTranslations(),
        child: host,
      );
    }
    return UncontrolledProviderScope(container: container, child: host);
  }

  Future<void> runOffline(
    WidgetTester tester,
    Future<void> Function() body,
  ) async {
    expect(
      dotenv.isInitialized,
      isFalse,
      reason: 'No environment initialization',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channels = [
      'com.pichillilorenzo/flutter_headless_inappwebview',
      'com.pichillilorenzo/flutter_inappwebview',
      'com.pichillilorenzo/flutter_inappwebview_cookiemanager',
      'com.pichillilorenzo/flutter_inappwebview_environment',
      'plugins.flutter.io/path_provider',
      'plugins.it_nomads.com/flutter_secure_storage',
      'plugins.flutter.io/google_sign_in',
    ];
    for (final channel in channels) {
      messenger.setMockMessageHandler(channel, (_) => block('native $channel'));
    }
    try {
      await HttpOverrides.runZoned(
        body,
        createHttpClient: (_) => block('HttpClient creation'),
      );
    } finally {
      // Keep tripwires active through unmount, deferred disposal and DB close.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      router.dispose();
      container.dispose();
      await tester.runAsync(native.close);
      for (final channel in channels) {
        messenger.setMockMessageHandler(channel, null);
      }
      expect(
        native.api.bulkReads,
        0,
        reason: 'No all-model/connection enumeration',
      );
      expect(native.api.ids, isEmpty, reason: 'No selected connection load');
      expect(native.selectedLoads, 0);
      expect(
        dotenv.isInitialized,
        isFalse,
        reason: 'No environment was loaded',
      );
      expect(
        unexpectedAccess,
        isEmpty,
        reason: 'No swallowed startup/I/O attempts',
      );
      expect(tester.takeException(), isNull);
    }
  }
}
