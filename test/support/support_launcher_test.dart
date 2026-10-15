import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/character_folder.dart';
import 'package:glaze_flutter/core/state/character_folder_provider.dart';
import 'package:glaze_flutter/core/state/character_provider.dart';
import 'package:glaze_flutter/features/character_list/character_list_screen.dart';
import 'package:glaze_flutter/features/character_list/filtered_characters_provider.dart';
import 'package:glaze_flutter/features/character_list/widgets/character_folders_section.dart';
import 'package:glaze_flutter/features/character_list/widgets/character_grid.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/shared/shell/shell_header_provider.dart';

class _Settings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings(showOurPicks: false);
}

class _Characters extends CharactersNotifier {
  @override
  Future<List<Character>> build() async => const [];

  @override
  Future<int> backfillMissingAvatarThumbnails() async => 0;
}

class _Infinite extends InfiniteCharactersNotifier {
  _Infinite(super.arg);

  @override
  Future<InfiniteCharactersState> build() async =>
      const InfiniteCharactersState(items: [], totalCount: 0, loadedLimit: 25);
}

Widget _scope(Widget child, {List<CharacterFolder> folders = const []}) =>
    ProviderScope(
      overrides: [
        appSettingsProvider.overrideWith(_Settings.new),
        charactersProvider.overrideWith(_Characters.new),
        characterFoldersProvider.overrideWith((_) => Stream.value(folders)),
        folderMembershipsProvider.overrideWith(
          (_) => Stream.value(FolderMemberships.empty),
        ),
        infiniteCharactersProvider(
          kDefaultInfiniteCharactersKey,
        ).overrideWith(() => _Infinite(kDefaultInfiniteCharactersKey)),
      ],
      child: child,
    );

class _HeaderHost extends ConsumerWidget {
  const _HeaderHost();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final header = ref.watch(shellHeaderProvider).lastOrNull?.config;
    return Column(
      children: [
        if (header?.titleWidget != null) header!.titleWidget!,
        const Expanded(child: CharacterListScreen()),
      ],
    );
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('launcher order is Picks, Astoria, Favorites, real folders', (
    tester,
  ) async {
    await tester.pumpWidget(
      _scope(
        MaterialApp(
          home: Scaffold(
            body: CharacterFoldersSection(
              showOurPicks: true,
              showFavorites: true,
              onOpenFolder: (_) {},
              onOpenAstoriaAssistant: () {},
            ),
          ),
        ),
        folders: [const CharacterFolder(id: 'f', name: 'Real folder')],
      ),
    );
    await tester.pumpAndSettle();
    final picks = tester.getCenter(find.text('Our Picks')).dx;
    final astoria = tester
        .getCenter(find.byKey(CharacterFoldersSection.astoriaLauncherKey))
        .dx;
    final favorites = tester.getCenter(find.text('folder_favorites')).dx;
    final folder = tester.getCenter(find.text('Real folder')).dx;
    expect(picks, lessThan(astoria));
    expect(astoria, lessThan(favorites));
    expect(favorites, lessThan(folder));
  });

  testWidgets('default launcher navigates even with no supplied callback', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/characters',
      routes: [
        GoRoute(
          path: '/characters',
          builder: (_, _) =>
              Scaffold(body: CharacterFoldersSection(onOpenFolder: (_) {})),
        ),
        GoRoute(
          path: '/support',
          builder: (_, _) => const Scaffold(body: Text('Support opened')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(_scope(MaterialApp.router(routerConfig: router)));
    await tester.pumpAndSettle();
    expect(find.text('Our Picks'), findsNothing);
    await tester.tap(find.byKey(CharacterFoldersSection.astoriaLauncherKey));
    await tester.pumpAndSettle();
    expect(find.text('Support opened'), findsOneWidget);
  });

  testWidgets('hidden Picks and empty library retain screen launcher', (
    tester,
  ) async {
    await tester.pumpWidget(
      _scope(const MaterialApp(home: CharacterListScreen())),
    );
    await tester.pumpAndSettle();
    expect(find.text('Our Picks'), findsNothing);
    expect(
      find.byKey(CharacterFoldersSection.astoriaLauncherKey),
      findsOneWidget,
    );
  });

  testWidgets('active search with nonempty results retains launcher', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(_Settings.new),
        charactersProvider.overrideWith(_Characters.new),
        characterFoldersProvider.overrideWith((_) => Stream.value(const [])),
        folderMembershipsProvider.overrideWith(
          (_) => Stream.value(FolderMemberships.empty),
        ),
        infiniteCharactersProvider(
          kDefaultInfiniteCharactersKey,
        ).overrideWith(() => _Infinite(kDefaultInfiniteCharactersKey)),
        // Force a nonempty result independent of search spelling and database.
        filteredCharactersProvider.overrideWith(
          (ref, query) => [Character(id: 'c', name: 'Result')],
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: _HeaderHost())),
      ),
    );
    await tester.pumpAndSettle();
    final header = container.read(shellHeaderProvider).last.config;
    final searchButton = header.actions!.whereType<IconButton>().first;
    searchButton.onPressed!();
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Result');
    await tester.pumpAndSettle();
    expect(find.byType(CharacterGrid), findsOneWidget);
    expect(
      find.byKey(CharacterFoldersSection.astoriaLauncherKey),
      findsOneWidget,
    );
  });
}
