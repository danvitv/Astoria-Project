import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/character_folder.dart';
import 'package:glaze_flutter/core/constants/support_assistant_availability.dart';
import 'package:glaze_flutter/features/character_list/character_list_screen.dart';
import 'package:glaze_flutter/features/character_list/widgets/character_folders_section.dart';
import 'package:glaze_flutter/features/character_list/widgets/character_grid.dart';
import 'package:glaze_flutter/shared/shell/shell_header_provider.dart';
import 'package:glaze_flutter/shared/widgets/glaze_scaffold.dart';

import 'helpers/launcher_test_harness.dart';

class _HeaderHost extends ConsumerWidget {
  const _HeaderHost();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final header = ref.watch(shellHeaderProvider).lastOrNull?.config;
    return Column(
      children: [
        if (header?.actions != null) Row(children: header!.actions!),
        if (header?.titleWidget != null) header!.titleWidget!,
        const Expanded(child: CharacterListScreen()),
      ],
    );
  }
}

void _offlineTest(
  String description,
  Future<void> Function(WidgetTester tester, LauncherTestHarness harness)
  body, {
  bool showOurPicks = false,
  List<Character> characters = const [],
  List<CharacterFolder> folders = const [],
}) {
  testWidgets(description, (tester) async {
    final harness = LauncherTestHarness(
      showOurPicks: showOurPicks,
      characters: characters,
      folders: folders,
    );
    await harness.runOffline(() async {
      try {
        await body(tester, harness);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    });
  });
}

void _expectDisabledEntries() {
  expect(supportAssistantWorkspaceEnabled, isFalse);
  expect(find.byKey(CharacterFoldersSection.astoriaLauncherKey), findsNothing);
  expect(
    find.byWidgetPredicate(
      (widget) =>
          widget is GlazePillButton &&
          widget.icon == Icons.support_agent_rounded,
    ),
    findsNothing,
  );
}

Future<void> _search(WidgetTester tester, String query) async {
  // Header actions are SizedBox-wrapped. Render them in the host and locate
  // the descendant IconButton instead of whereType<IconButton>() on the list.
  final searchButton = find.widgetWithIcon(IconButton, Icons.search_rounded);
  expect(searchButton, findsOneWidget);
  await tester.tap(searchButton);
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), query);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  _offlineTest(
    'enabled presentation order is Picks, Astoria, Favorites, real folders',
    (tester, harness) async {
      var opened = 0;
      await tester.pumpWidget(
        harness.scope(
          home: Scaffold(
            body: CharacterFoldersSection(
              showOurPicks: true,
              showAstoriaAssistant: true,
              showFavorites: true,
              onOpenFolder: (_) {},
              onOpenAstoriaAssistant: () => opened++,
            ),
          ),
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
      await tester.tap(find.byKey(CharacterFoldersSection.astoriaLauncherKey));
      expect(opened, 1);
    },
    folders: [const CharacterFolder(id: 'f', name: 'Real folder')],
  );

  _offlineTest(
    'explicitly enabled default callback opens a synthetic safe route',
    (tester, harness) async {
      final router = GoRouter(
        initialLocation: '/characters',
        routes: [
          GoRoute(
            path: '/characters',
            builder: (_, _) => Scaffold(
              body: CharacterFoldersSection(
                showAstoriaAssistant: true,
                onOpenFolder: (_) {},
              ),
            ),
          ),
          GoRoute(
            path: '/support',
            builder: (_, _) => const Scaffold(body: Text('Support opened')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(harness.scope(routerConfig: router));
      await tester.pumpAndSettle();
      expect(find.text('Our Picks'), findsNothing);
      await tester.tap(find.byKey(CharacterFoldersSection.astoriaLauncherKey));
      await tester.pumpAndSettle();
      expect(find.text('Support opened'), findsOneWidget);
    },
  );

  _offlineTest(
    'disabled screen with hidden Picks and empty library has no launcher',
    (tester, harness) async {
      await tester.pumpWidget(harness.scope(home: const CharacterListScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Our Picks'), findsNothing);
      expect(find.text('No characters yet'), findsOneWidget);
      expect(find.text('Import Character'), findsOneWidget);
      _expectDisabledEntries();
    },
  );

  _offlineTest(
    'disabled screen searches nonempty results without a launcher',
    (tester, harness) async {
      await tester.pumpWidget(
        harness.scope(home: const Scaffold(body: _HeaderHost())),
      );
      await tester.pumpAndSettle();
      await _search(tester, 'Result');
      expect(find.byType(CharacterGrid), findsOneWidget);
      final grid = tester.widget<CharacterGrid>(find.byType(CharacterGrid));
      expect(grid.characters.map((c) => c.name), ['Result']);
      expect(find.text('Our Picks'), findsNothing);
      expect(find.text('folder_favorites'), findsNothing);
      _expectDisabledEntries();
    },
    showOurPicks: true,
    characters: [
      Character(id: 'c', name: 'Result', tokenCount: 1),
      Character(id: 'other', name: 'Other', fav: true, tokenCount: 1),
    ],
  );

  _offlineTest(
    'disabled screen with visible Picks and empty library has no launcher',
    (tester, harness) async {
      await tester.pumpWidget(harness.scope(home: const CharacterListScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Our Picks'), findsOneWidget);
      final grid = tester.widget<CharacterGrid>(find.byType(CharacterGrid));
      expect(grid.characters, isEmpty);
      expect(grid.totalCount, 0);
      _expectDisabledEntries();
    },
    showOurPicks: true,
  );

  _offlineTest(
    'disabled empty search has no assistant pill or launcher',
    (tester, harness) async {
      await tester.pumpWidget(
        harness.scope(home: const Scaffold(body: _HeaderHost())),
      );
      await tester.pumpAndSettle();
      await _search(tester, 'No match');
      expect(find.byType(CharacterGrid), findsNothing);
      expect(find.text('no_characters'), findsOneWidget);
      expect(find.text('Our Picks'), findsNothing);
      _expectDisabledEntries();
    },
    showOurPicks: true,
    characters: [Character(id: 'c', name: 'Result', tokenCount: 1)],
  );
}
