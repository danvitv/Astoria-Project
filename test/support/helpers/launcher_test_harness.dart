import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/character_folder.dart';
import 'package:glaze_flutter/core/state/character_folder_provider.dart';
import 'package:glaze_flutter/core/state/character_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/features/catalog/catalog_provider.dart';
import 'package:glaze_flutter/features/catalog/chub_account_provider.dart';
import 'package:glaze_flutter/features/catalog/third_party_providers_provider.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_provider.dart';
import 'package:glaze_flutter/features/extensions/providers/extension_presets_provider.dart';
import 'package:glaze_flutter/features/extensions/providers/extensions_settings_provider.dart';
import 'package:glaze_flutter/features/picks/picks_models.dart';
import 'package:glaze_flutter/features/picks/picks_provider.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';

/// Presentation-only scope. Never mounts App, the production router or shell.
///
/// The catalog listener exists even on My Characters: replacing only its HTTP
/// fetcher is too late, because its constructor already restores state/searches.
/// The synthetic notifier below bypasses that entire CF/headless startup path.
class LauncherTestHarness {
  final unexpectedAccess = <String>[];
  late final ProviderContainer container;

  LauncherTestHarness({
    bool showOurPicks = false,
    List<Character> characters = const [],
    List<CharacterFolder> folders = const [],
  }) {
    container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(() => _Settings(showOurPicks)),
        charactersProvider.overrideWith(() => _Characters(characters)),
        // Override the whole family, not just the initial sort/hidden key.
        infiniteCharactersProvider.overrideWith2(
          (key) => _Infinite(key, characters),
        ),
        characterFoldersProvider.overrideWith((_) => Stream.value(folders)),
        folderMembershipsProvider.overrideWith(
          (_) => Stream.value(FolderMemberships.empty),
        ),
        // CharacterCard watches this DB stream for the nonempty search case.
        variantGroupStatsProvider.overrideWith((_) => Stream.value(const {})),
        characterVariantsProvider.overrideWith(
          (_, _) => Stream.value(characters),
        ),
        characterSessionCountsProvider.overrideWith(
          (_) => Stream.value(const {}),
        ),
        // Keep actual in-memory filtering: typed search must select real fixtures.
        // No override for filteredCharactersProvider is needed; all its inputs
        // are synthetic and it performs no I/O.
        catalogProvider.overrideWith((_) => _Catalog(block)),
        catalogVisibleProvider.overrideWithValue(false),
        enabledCatalogProvidersProvider.overrideWithValue(const []),
        catalogMasterEnabledProvider.overrideWith(_CatalogDisabled.new),
        thirdPartyProvidersProvider.overrideWith(_ThirdPartiesDisabled.new),
        chubAccountProvider.overrideWith(_AnonymousChub.new),
        picksIndexProvider.overrideWith((_) => const PicksIndex()),
        themeProvider.overrideWith((_) => _Theme(block)),
        sharedPreferencesProvider.overrideWith(
          (_) => SharedPreferences.getInstance(),
        ),
        // These are tripwires, not real/in-memory DBs or permissive mocks.
        // They record even an exception swallowed by a background callback.
        appDbProvider.overrideWith((_) => block('appDbProvider')),
        characterRepoProvider.overrideWith(
          (_) => block('characterRepoProvider'),
        ),
        characterFolderRepoProvider.overrideWith(
          (_) => block('characterFolderRepoProvider'),
        ),
        chatRepoProvider.overrideWith((_) => block('chatRepoProvider')),
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
      ],
    );
  }

  Never block(String boundary) {
    unexpectedAccess.add(boundary);
    throw StateError('Offline launcher test reached $boundary');
  }

  Widget scope({Widget? home, GoRouter? routerConfig}) =>
      UncontrolledProviderScope(
        container: container,
        child: EasyLocalization(
          supportedLocales: const [Locale('en')],
          startLocale: const Locale('en'),
          saveLocale: false,
          path: 'synthetic',
          assetLoader: const _SyntheticTranslations(),
          child: Builder(
            // Install delegates on the app itself: an outer Localizations is
            // shadowed by MaterialApp and only initializes global translations.
            builder: (context) => routerConfig == null
                ? MaterialApp(
                    home: home,
                    locale: context.locale,
                    supportedLocales: context.supportedLocales,
                    localizationsDelegates: context.localizationDelegates,
                  )
                : MaterialApp.router(
                    routerConfig: routerConfig,
                    locale: context.locale,
                    supportedLocales: context.supportedLocales,
                    localizationsDelegates: context.localizationDelegates,
                  ),
          ),
        ),
      );

  Future<void> runOffline(Future<void> Function() body) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // No native WebView is registered by this fixture. Reject attempts on the
    // headless/session/cookie channels as well, before any native delegation.
    const channels = [
      'com.pichillilorenzo/flutter_headless_inappwebview',
      'com.pichillilorenzo/flutter_inappwebview',
      'com.pichillilorenzo/flutter_inappwebview_cookiemanager',
      'com.pichillilorenzo/flutter_inappwebview_environment',
    ];
    for (final channel in channels) {
      messenger.setMockMessageHandler(channel, (_) => block('native $channel'));
    }
    try {
      // A zone override takes precedence over flutter_test's permissive HTTP
      // mock. No HttpClient/socket can be created through this HTTP boundary.
      await HttpOverrides.runZoned(
        body,
        createHttpClient: (_) => block('HttpClient creation'),
      );
    } finally {
      for (final channel in channels) {
        messenger.setMockMessageHandler(channel, null);
      }
      container.dispose();
      expect(
        unexpectedAccess,
        isEmpty,
        reason: 'No swallowed startup/I/O attempts',
      );
    }
  }
}

// The grid's plural() needs an initialized locale. No real assets, App theme
// factory or localization preferences are needed for this presentation fixture.
class _SyntheticTranslations extends AssetLoader {
  const _SyntheticTranslations();

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async => {
    'support_assistant_entry': 'Astoria Assistant',
    'count_characters': {
      'zero': 'characters',
      'one': 'character',
      'other': 'characters',
    },
    for (final key in [
      'btn_add',
      'header_characters',
      'search_characters',
      'no_characters',
      'folder_favorites',
      'sort_name',
      'sort_date',
      'title_error',
    ])
      key: key,
  };
}

class _Settings extends AppSettingsNotifier {
  final bool showPicks;
  _Settings(this.showPicks);

  @override
  Future<AppSettings> build() async => AppSettings(showOurPicks: showPicks);
}

class _Characters extends CharactersNotifier {
  final List<Character> fixtures;
  _Characters(this.fixtures);

  @override
  Future<List<Character>> build() async => fixtures;

  @override
  Future<int> backfillMissingAvatarThumbnails() async => 0;
}

class _Infinite extends InfiniteCharactersNotifier {
  final List<Character> fixtures;
  _Infinite(super.arg, this.fixtures);

  @override
  Future<InfiniteCharactersState> build() async => InfiniteCharactersState(
    items: fixtures,
    totalCount: fixtures.length,
    loadedLimit: fixtures.length,
  );
}

// Implement rather than extend these production notifiers: their constructors
// start asynchronous catalog/theme restoration before an override can intervene.
class _Catalog extends StateNotifier<CatalogState> implements CatalogNotifier {
  final Never Function(String) block;
  _Catalog(this.block) : super(const CatalogState(hasMore: false));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      block('catalog command ${invocation.memberName}');
}

class _Theme extends StateNotifier<ThemeSettings> implements ThemeNotifier {
  final Never Function(String) block;
  _Theme(this.block)
    : super(
        const ThemeSettings(
          activePreset: ThemePreset(
            id: 'synthetic',
            name: 'Synthetic',
            elementBlur: 0,
            noiseOpacity: 0,
          ),
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      block('theme command ${invocation.memberName}');
}

class _CatalogDisabled extends CatalogEnabledNotifier {
  @override
  bool build() => false;
}

class _ThirdPartiesDisabled extends ThirdPartyProvidersNotifier {
  @override
  Set<ThirdPartyProvider> build() => ThirdPartyProvider.values.toSet();
}

class _AnonymousChub extends ChubAccountNotifier {
  @override
  ChubAccount build() => const ChubAccount();
}
