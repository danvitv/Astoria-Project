import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/state/character_provider.dart';
import 'package:glaze_flutter/core/state/lorebook_provider.dart';
import 'package:glaze_flutter/features/character_list/character_editor_screen.dart';
import 'package:glaze_flutter/shared/widgets/generic_editor.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const imported = Character(
    id: 'synthetic-editor-card',
    name: 'Synthetic card',
    depthPrompt: 'Imported depth instructions',
    depthPromptDepth: 8,
    depthPromptRole: 'user',
    world: 'Imported world',
    extensions: {
      'depth_prompt': {
        'prompt': 'Imported depth instructions',
        'depth': 8,
        'role': 'user',
      },
      'world': 'Imported world',
      'custom_import_extension': {'preserved': true},
      'talkativeness': 0.7,
    },
  );

  Future<_RecordingCharacters> pumpEditor(WidgetTester tester) async {
    final notifier = _RecordingCharacters(imported);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          charactersProvider.overrideWith(() => notifier),
          lorebooksProvider.overrideWith(_EmptyLorebooks.new),
        ],
        child: const MaterialApp(
          home: CharacterEditorScreen(charId: 'synthetic-editor-card'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(GenericEditor), findsOneWidget);
    return notifier;
  }

  Future<Character> saveValues(
    WidgetTester tester,
    _RecordingCharacters notifier,
    Map<String, dynamic> changes,
  ) async {
    final editor = tester.widget<GenericEditor>(find.byType(GenericEditor));
    // Exercise the existing editor save callback without adding the deliberately
    // hidden depth-prompt controls back to the UI.
    editor.onSave!({...editor.item, ...changes});
    await tester.pump();
    return notifier.saved.single;
  }

  testWidgets('an unrelated edit preserves imported depth/world extensions', (
    tester,
  ) async {
    final notifier = await pumpEditor(tester);
    final saved = await saveValues(tester, notifier, {'name': 'Renamed card'});
    expect(saved.depthPrompt, imported.depthPrompt);
    expect(saved.depthPromptDepth, 8);
    expect(saved.depthPromptRole, 'user');
    expect(saved.world, imported.world);
    expect(saved.extensions, imported.extensions);
    final editor = tester.widget<GenericEditor>(find.byType(GenericEditor));
    final fields = editor.config.expand((section) => section.fields);
    expect(fields.any((field) => field.key == 'depth_prompt'), isFalse);
  });

  testWidgets('explicit world None removes only its imported fallback', (
    tester,
  ) async {
    final notifier = await pumpEditor(tester);
    final saved = await saveValues(tester, notifier, {'world': null});
    expect(saved.world, isNull);
    expect(saved.extensions.containsKey('world'), isFalse);
    expect(
      saved.extensions['depth_prompt'],
      imported.extensions['depth_prompt'],
    );
    expect(saved.extensions['custom_import_extension'], {'preserved': true});
    expect(imported.extensions['world'], 'Imported world');
  });

  testWidgets('explicit empty depth prompt removes its imported fallback', (
    tester,
  ) async {
    final notifier = await pumpEditor(tester);
    final saved = await saveValues(tester, notifier, {'depth_prompt': '   '});
    expect(saved.depthPrompt, isEmpty);
    expect(saved.extensions.containsKey('depth_prompt'), isFalse);
    expect(saved.world, 'Imported world');
    expect(saved.extensions['world'], 'Imported world');
    expect(saved.extensions['custom_import_extension'], {'preserved': true});
    expect(imported.extensions.containsKey('depth_prompt'), isTrue);
  });

  testWidgets('clearing both does not mutate the original extensions map', (
    tester,
  ) async {
    final notifier = await pumpEditor(tester);
    final saved = await saveValues(tester, notifier, {
      'depth_prompt': '',
      'world': '   ',
    });
    expect(
      saved.extensions.keys,
      unorderedEquals(['custom_import_extension', 'talkativeness']),
    );
    expect(imported.extensions.keys, containsAll(['depth_prompt', 'world']));
    expect(saved.extensions['talkativeness'], 0.7);
    expect(saved.world, isNull);
  });
}

class _RecordingCharacters extends CharactersNotifier {
  _RecordingCharacters(this.initial);

  final Character initial;
  final List<Character> saved = [];

  @override
  Future<List<Character>> build() async => [initial];

  @override
  Future<void> save(Character character) async {
    saved.add(character);
  }
}

class _EmptyLorebooks extends LorebooksNotifier {
  @override
  Future<List<Lorebook>> build() async => [];
}
