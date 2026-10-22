import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:glaze_flutter/core/constants/support_assistant_availability.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/character_folder.dart';
import 'package:glaze_flutter/features/character_list/character_list_screen.dart';
import 'package:glaze_flutter/features/character_list/widgets/character_filter_sheet.dart';
import 'package:glaze_flutter/features/character_list/widgets/character_folders_section.dart';
import 'package:glaze_flutter/features/character_list/widgets/character_grid.dart';
import 'package:glaze_flutter/features/support_assistant/support_assistant_screen.dart';
import 'package:glaze_flutter/shared/widgets/glaze_spinner.dart';

import 'helpers/entry_route_fakes.dart';
import 'helpers/entry_route_test_harness.dart';
import 'helpers/support_native_widget_fixture.dart';

const _helpKey = ValueKey('astoria_assistant_help_entry');
final _rows = [
  Character(id: 'synthetic-result', name: 'Result', tokenCount: 1),
  Character(id: 'synthetic-other', name: 'Other', fav: true, tokenCount: 1),
];

// Bounded pumps also cover loading/error. Never settle an intentional spinner.
Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _mount(WidgetTester tester, EntryRouteTestHarness harness) async {
  tester.view.physicalSize = const Size(600, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(harness.scope());
  await _frames(tester);
}

Future<void> _search(WidgetTester tester, String query) async {
  await tester.tap(find.widgetWithIcon(IconButton, Icons.search_rounded));
  await _frames(tester);
  await tester.enterText(find.byType(TextField), query);
  await _frames(tester);
}

Future<void> _openEntry(
  WidgetTester tester,
  EntryRouteTestHarness harness,
  Key key,
) async {
  expect(find.byKey(key), findsOneWidget);
  expect(harness.supportStarts, 0);
  await tester.ensureVisible(find.byKey(key));
  await tester.tap(find.byKey(key));
  await _frames(tester);
  expect(harness.router.routeInformationProvider.value.uri.path, '/support');
  expect(find.byType(SupportAssistantScreen), findsOneWidget);
  expect(harness.supportStarts, 1);
}

bool _focusedInside(Key key) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  var inside = context.widget.key == key;
  context.visitAncestorElements((element) {
    if (element.widget.key == key) inside = true;
    return !inside;
  });
  return inside;
}

Future<void> _focusEntry(WidgetTester tester, Key key) async {
  // Drive native traversal, rather than installing a test-only FocusNode.
  FocusManager.instance.primaryFocus?.unfocus();
  for (var i = 0; i < 16 && !_focusedInside(key); i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  expect(
    _focusedInside(key),
    isTrue,
    reason: 'Entry participates in keyboard traversal',
  );
}

void main() {
  setUpAll(initializeNativeWidgetLocalization);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final showPicks in [false, true]) {
    for (final nonempty in [false, true]) {
      testWidgets(
        'default-enabled root entry: Picks=$showPicks, nonempty=$nonempty, no configured model',
        (tester) async {
          final harness = EntryRouteTestHarness(
            prefs: await SharedPreferences.getInstance(),
            showOurPicks: showPicks,
            characters: nonempty ? _rows : const [],
          );
          await harness.runOffline(tester, () async {
            await _mount(tester, harness);
            expect(
              find.text('Our Picks'),
              showPicks ? findsOneWidget : findsNothing,
            );
            expect(harness.workspace.topics, isEmpty);
            expect(supportAssistantWorkspaceEnabled, isTrue);
            expect(
              tester
                  .widget<CharacterListScreen>(find.byType(CharacterListScreen))
                  .supportAssistantAvailable,
              isTrue,
            );
            await _openEntry(
              tester,
              harness,
              CharacterFoldersSection.astoriaLauncherKey,
            );
          });
        },
      );
    }
  }

  testWidgets(
    'actual screen keeps Picks → Astoria → Favorites → real folder order',
    (tester) async {
      final harness = EntryRouteTestHarness(
        prefs: await SharedPreferences.getInstance(),
        available: true,
        showOurPicks: true,
        characters: _rows,
        folders: [
          const CharacterFolder(id: 'synthetic-folder', name: 'Real folder'),
        ],
      );
      await harness.runOffline(tester, () async {
        await _mount(tester, harness);
        final positions = [
          tester.getCenter(find.text('Our Picks')).dx,
          tester
              .getCenter(find.byKey(CharacterFoldersSection.astoriaLauncherKey))
              .dx,
          tester.getCenter(find.text('Избранное')).dx,
          tester.getCenter(find.text('Real folder')).dx,
        ];
        for (var i = 1; i < positions.length; i++) {
          expect(positions[i - 1], lessThan(positions[i]));
        }
        // The entry is not a row or fake folder with a character identity.
        expect(
          tester.widget<CharacterGrid>(find.byType(CharacterGrid)).characters,
          _rows,
        );
      });
    },
  );

  for (final nonempty in [false, true]) {
    testWidgets(
      'enabled ${nonempty ? "nonempty" : "empty"} search has one usable entry',
      (tester) async {
        final harness = EntryRouteTestHarness(
          prefs: await SharedPreferences.getInstance(),
          available: true,
          showOurPicks: true,
          characters: _rows,
        );
        await harness.runOffline(tester, () async {
          await _mount(tester, harness);
          await _search(tester, nonempty ? 'Result' : 'No match');
          expect(harness.queries.last.search, nonempty ? 'Result' : 'No match');
          expect(find.text('Our Picks'), findsNothing);
          expect(find.text('Избранное'), findsNothing);
          if (nonempty) {
            expect(
              tester
                  .widget<CharacterGrid>(find.byType(CharacterGrid))
                  .characters
                  .map((c) => c.name),
              ['Result'],
            );
            expect(find.byKey(_helpKey), findsNothing);
          } else {
            expect(find.byType(CharacterGrid), findsNothing);
            expect(
              find.byKey(CharacterFoldersSection.astoriaLauncherKey),
              findsNothing,
            );
          }
          await _openEntry(
            tester,
            harness,
            nonempty ? CharacterFoldersSection.astoriaLauncherKey : _helpKey,
          );
        });
      },
    );
  }

  for (final nonempty in [false, true]) {
    testWidgets(
      'enabled ${nonempty ? "nonempty" : "empty"} favorites filter keeps help',
      (tester) async {
        final harness = EntryRouteTestHarness(
          prefs: await SharedPreferences.getInstance(),
          available: true,
          showOurPicks: true,
          characters: nonempty ? _rows : [_rows.first],
        );
        await harness.runOffline(tester, () async {
          await _mount(tester, harness);
          final filterControl = find.descendant(
            of: find.byType(CharacterGrid),
            matching: find.widgetWithIcon(
              GestureDetector,
              Icons.filter_list_rounded,
            ),
          );
          expect(filterControl, findsOneWidget);
          await tester.ensureVisible(filterControl);
          await tester.tap(filterControl);
          await _frames(tester);
          final sheet = find.byType(CharacterFilterSheet);
          expect(sheet, findsOneWidget);
          final favoriteToggle = find.descendant(
            of: sheet,
            matching: find.byType(Switch),
          );
          expect(favoriteToggle, findsOneWidget);
          expect(tester.widget<Switch>(favoriteToggle).value, isFalse);
          await tester.ensureVisible(favoriteToggle);
          await tester.tap(favoriteToggle);
          await _frames(tester);
          expect(tester.widget<Switch>(favoriteToggle).value, isTrue);
          // The sheet is on the root navigator and applies on disposal.
          Navigator.of(tester.element(sheet), rootNavigator: true).pop();
          await _frames(tester);
          expect(sheet, findsNothing);
          expect(
            harness.router.routeInformationProvider.value.uri.path,
            '/characters',
          );
          expect(harness.queries.last.search, isEmpty);
          expect(harness.queries.last.folderId, isNull);
          expect(harness.queries.last.favOnly, isTrue);
          expect(find.text('Our Picks'), findsNothing);
          if (nonempty) {
            final grid = tester.widget<CharacterGrid>(
              find.byType(CharacterGrid),
            );
            expect(grid.characters.map((c) => c.name), ['Other']);
            expect(grid.filterCount, 1);
            expect(find.byKey(_helpKey), findsNothing);
          } else {
            expect(find.byType(CharacterGrid), findsNothing);
            expect(
              find.byKey(CharacterFoldersSection.astoriaLauncherKey),
              findsNothing,
            );
          }
          await _openEntry(
            tester,
            harness,
            nonempty ? CharacterFoldersSection.astoriaLauncherKey : _helpKey,
          );
        });
      },
    );
  }

  for (final state in [EntryDataState.loading, EntryDataState.error]) {
    testWidgets('explicitly disabled initial $state has no support startup', (
      tester,
    ) async {
      final harness = EntryRouteTestHarness(
        prefs: await SharedPreferences.getInstance(),
        available: false,
        initialState: state,
      );
      await harness.runOffline(tester, () async {
        await _mount(tester, harness);
        expect(find.byType(AstoriaAssistantEntryButton), findsNothing);
        expect(harness.supportStarts, 0);
      });
    });
    testWidgets('enabled initial $state provides secondary help', (
      tester,
    ) async {
      final harness = EntryRouteTestHarness(
        prefs: await SharedPreferences.getInstance(),
        available: true,
        initialState: state,
      );
      await harness.runOffline(tester, () async {
        await _mount(tester, harness);
        expect(
          find.byKey(CharacterFoldersSection.astoriaLauncherKey),
          findsNothing,
        );
        expect(
          state == EntryDataState.loading
              ? find.byType(GlazeSpinner)
              : find.textContaining('Synthetic page error'),
          findsOneWidget,
        );
        await _openEntry(tester, harness, _helpKey);
      });
    });
    testWidgets('enabled filtered $state provides secondary help', (
      tester,
    ) async {
      final harness = EntryRouteTestHarness(
        prefs: await SharedPreferences.getInstance(),
        available: true,
        characters: _rows,
      );
      await harness.runOffline(tester, () async {
        await _mount(tester, harness);
        await _search(tester, 'Result');
        harness.characterOwner.show(state);
        await _frames(tester);
        expect(
          find.byKey(CharacterFoldersSection.astoriaLauncherKey),
          findsNothing,
        );
        expect(
          state == EntryDataState.loading
              ? find.byType(GlazeSpinner)
              : find.textContaining('Synthetic filtered library error'),
          findsOneWidget,
        );
        await _openEntry(tester, harness, _helpKey);
      });
    });
  }

  for (final compact in [false, true]) {
    for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.space]) {
      testWidgets(
        '${compact ? "pill" : "circle"} is a named tooltip button activated by ${key.keyLabel}',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            final harness = EntryRouteTestHarness(
              prefs: await SharedPreferences.getInstance(),
              available: true,
              characters: _rows,
            );
            await harness.runOffline(tester, () async {
              await _mount(tester, harness);
              if (compact) await _search(tester, 'No match');
              final entryKey = compact
                  ? _helpKey
                  : CharacterFoldersSection.astoriaLauncherKey;
              final entry = find.byKey(entryKey);
              final node = tester.getSemantics(
                find.descendant(
                  of: entry,
                  matching: find.byWidgetPredicate(
                    (w) => w is Semantics && w.properties.button == true,
                  ),
                ),
              );
              expect(node.getSemanticsData().flagsCollection.isButton, isTrue);
              expect(
                node.getSemanticsData().hasAction(SemanticsAction.tap),
                isTrue,
              );
              expect(node.label, 'Астория Ассистент');
              final tooltip = tester.widget<Tooltip>(
                find.descendant(of: entry, matching: find.byType(Tooltip)),
              );
              expect(tooltip.message, 'Астория Ассистент');
              await _focusEntry(tester, entryKey);
              await tester.sendKeyEvent(key);
              await _frames(tester);
              expect(
                harness.router.routeInformationProvider.value.uri.path,
                '/support',
              );
              expect(find.byType(SupportAssistantScreen), findsOneWidget);
            });
          } finally {
            // Framework end checks run before addTearDown callbacks.
            semantics.dispose();
          }
        },
      );
    }
  }

  for (final localized in [false, true]) {
    testWidgets(
      'en_US label ${localized ? "with" : "without"} EasyLocalization',
      (tester) async {
        final harness = EntryRouteTestHarness(
          prefs: await SharedPreferences.getInstance(),
          available: true,
        );
        await harness.runOffline(tester, () async {
          await tester.pumpWidget(
            harness.scope(
              home: Scaffold(
                body: CharacterFoldersSection(
                  showAstoriaAssistant: true,
                  onOpenFolder: (_) {},
                  onOpenAstoriaAssistant: () {},
                ),
              ),
              locale: const Locale('en', 'US'),
              localized: localized,
            ),
          );
          await _frames(tester);
          expect(find.text('Astoria Assistant'), findsOneWidget);
          expect(find.text('Астория Ассистент'), findsNothing);
        });
      },
    );
  }

  for (final compact in [false, true]) {
    testWidgets(
      'actual en_US ${compact ? "pill" : "circle"} uses the English entry name',
      (tester) async {
        final harness = EntryRouteTestHarness(
          prefs: await SharedPreferences.getInstance(),
          available: true,
          characters: _rows,
        );
        await harness.runOffline(tester, () async {
          tester.view.physicalSize = const Size(600, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            harness.scope(locale: const Locale('en', 'US')),
          );
          await _frames(tester);
          if (compact) await _search(tester, 'No match');
          final entry = find.byKey(
            compact ? _helpKey : CharacterFoldersSection.astoriaLauncherKey,
          );
          expect(
            find.descendant(
              of: entry,
              matching: find.text('Astoria Assistant'),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: entry,
              matching: find.text('Астория Ассистент'),
            ),
            findsNothing,
          );
        });
      },
    );
  }

  testWidgets(
    'null callback without a router does not advertise an inert entry',
    (tester) async {
      final harness = EntryRouteTestHarness(
        prefs: await SharedPreferences.getInstance(),
      );
      await harness.runOffline(tester, () async {
        await tester.pumpWidget(
          harness.scope(
            home: Scaffold(
              body: CharacterFoldersSection(
                showAstoriaAssistant: true,
                onOpenFolder: (_) {},
              ),
            ),
          ),
        );
        await _frames(tester);
        expect(
          find.byKey(CharacterFoldersSection.astoriaLauncherKey),
          findsNothing,
        );
        expect(find.byType(AstoriaAssistantEntryButton), findsNothing);
      });
    },
  );

  testWidgets(
    'cat caption remains two lines without overflow at narrow 2x text',
    (tester) async {
      final harness = EntryRouteTestHarness(
        prefs: await SharedPreferences.getInstance(),
        available: true,
      );
      await harness.runOffline(tester, () async {
        await tester.pumpWidget(
          harness.scope(
            home: Scaffold(
              body: MediaQuery(
                data: const MediaQueryData(
                  size: Size(320, 600),
                  textScaler: TextScaler.linear(2),
                ),
                child: SizedBox(
                  width: 320,
                  child: CharacterFoldersSection(
                    showAstoriaAssistant: true,
                    onOpenFolder: (_) {},
                    onOpenAstoriaAssistant: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        await _frames(tester);
        final caption = tester.widget<Text>(find.text('Астория Ассистент'));
        expect(caption.maxLines, 2);
        final image = tester.widget<Image>(
          find
              .descendant(
                of: find.byKey(CharacterFoldersSection.astoriaLauncherKey),
                matching: find.byType(Image),
              )
              .first,
        );
        expect(
          (image.image as AssetImage).assetName,
          'assets/logos/astoria-sticker.png',
        );
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets(
    'real-folder contents gain no extra entry and back restores root entry',
    (tester) async {
      final harness = EntryRouteTestHarness(
        prefs: await SharedPreferences.getInstance(),
        available: true,
        folders: [
          const CharacterFolder(id: 'synthetic-folder', name: 'Real folder'),
        ],
      );
      await harness.runOffline(tester, () async {
        await _mount(tester, harness);
        await tester.tap(find.text('Real folder'));
        await _frames(tester);
        expect(find.byType(AstoriaAssistantEntryButton), findsNothing);
        expect(harness.supportStarts, 0);
        await tester.tap(
          find.widgetWithIcon(IconButton, Icons.arrow_back_ios_new_rounded),
        );
        await _frames(tester);
        expect(
          find.byKey(CharacterFoldersSection.astoriaLauncherKey),
          findsOneWidget,
        );
      });
    },
  );

  testWidgets('disabled search/loading/error never advertises support help', (
    tester,
  ) async {
    final harness = EntryRouteTestHarness(
      prefs: await SharedPreferences.getInstance(),
      available: false,
      characters: _rows,
    );
    await harness.runOffline(tester, () async {
      await _mount(tester, harness);
      expect(
        tester
            .widget<CharacterListScreen>(find.byType(CharacterListScreen))
            .supportAssistantAvailable,
        isFalse,
      );
      await _search(tester, 'No match');
      for (final state in EntryDataState.values) {
        harness.characterOwner.show(state);
        await _frames(tester);
        expect(find.byType(AstoriaAssistantEntryButton), findsNothing);
        expect(harness.supportStarts, 0);
      }
    });
  });
}
