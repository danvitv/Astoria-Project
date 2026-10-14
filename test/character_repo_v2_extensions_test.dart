import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';

void main() {
  late AppDatabase db;
  late CharacterRepo repo;
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = CharacterRepo(db);
  });
  tearDown(() => db.close());

  test(
    'put/get persists V2 fields and does not mutate passed metadata',
    () async {
      final metadata = <String, dynamic>{
        'catalogUrl': 'https://example.invalid/card',
        'custom': {'nested': true},
        'depth_prompt': {'prompt': 'old', 'depth': 4, 'role': 'system'},
        'world': 'old book',
      };
      final card = Character(
        id: 'fields',
        name: 'Fields',
        depthPrompt: 'Stay curious.',
        depthPromptDepth: 0,
        depthPromptRole: 'assistant',
        world: 'New book',
        extensions: metadata,
      );
      await repo.put(card);
      final saved = (await repo.getById(card.id))!;
      expect(saved.depthPrompt, 'Stay curious.');
      expect(saved.depthPromptDepth, 0);
      expect(saved.depthPromptRole, 'assistant');
      expect(saved.world, 'New book');
      expect(saved.extensions['depth_prompt'], {
        'prompt': 'Stay curious.',
        'depth': 0,
        'role': 'assistant',
      });
      expect(saved.extensions['custom'], metadata['custom']);
      expect(metadata['world'], 'old book');
      expect((metadata['depth_prompt'] as Map)['prompt'], 'old');
    },
  );

  test('putAll keeps zero/deep depths and all roles', () async {
    final cards = [
      for (final (i, role) in ['system', 'user', 'assistant'].indexed)
        Character(
          id: 'batch-$i',
          name: role,
          depthPrompt: 'prompt-$i',
          depthPromptDepth: [0, 20, 42][i],
          depthPromptRole: role,
          world: 'book-$i',
        ),
    ];
    await repo.putAll(cards);
    for (final card in cards) {
      final saved = (await repo.getById(card.id))!;
      expect(saved.depthPrompt, card.depthPrompt);
      expect(saved.depthPromptDepth, card.depthPromptDepth);
      expect(saved.depthPromptRole, card.depthPromptRole);
      expect(saved.world, card.world);
    }
  });

  test(
    'extension-only imports hydrate fields and retain unknown V2 keys',
    () async {
      const extensions = {
        'depth_prompt': {'prompt': 'Imported', 'depth': 27, 'extra': 'retain'},
        'world': 'Imported book',
        'custom': ['unchanged'],
      };
      await repo.put(
        const Character(id: 'import', name: 'Import', extensions: extensions),
      );
      final saved = (await repo.getById('import'))!;
      expect(saved.depthPrompt, 'Imported');
      expect(saved.depthPromptDepth, 27);
      expect(saved.depthPromptRole, 'system');
      expect(saved.world, 'Imported book');
      await repo.put(saved);
      final raw = await db
          .customSelect(
            "SELECT extensions_json FROM characters WHERE char_id = 'import'",
          )
          .getSingle();
      expect(jsonDecode(raw.read<String>('extensions_json')), extensions);
      await repo.putAll([
        const Character(
          id: 'batch-import',
          name: 'Import',
          extensions: extensions,
        ),
      ]);
      expect((await repo.getById('batch-import'))!.depthPromptDepth, 27);
    },
  );

  test(
    'defaults preserve extensions; explicit clearing removes only owned keys',
    () async {
      await repo.put(
        const Character(
          id: 'clear',
          name: 'Clear',
          extensions: {
            'depth_prompt': {'prompt': 'Keep', 'depth': 6, 'role': 'user'},
            'world': 'Keep book',
            'custom': true,
          },
        ),
      );
      final saved = (await repo.getById('clear'))!;
      await repo.put(saved.copyWith(depthPrompt: '', world: null));
      expect((await repo.getById('clear'))!.depthPrompt, 'Keep');
      final clearedExtensions = Map<String, dynamic>.from(saved.extensions)
        ..remove('depth_prompt')
        ..remove('world');
      await repo.put(
        saved.copyWith(
          depthPrompt: '',
          depthPromptDepth: 4,
          depthPromptRole: 'system',
          world: null,
          extensions: clearedExtensions,
        ),
      );
      final cleared = (await repo.getById('clear'))!;
      expect(cleared.depthPrompt, '');
      expect(cleared.depthPromptDepth, 4);
      expect(cleared.depthPromptRole, 'system');
      expect(cleared.world, isNull);
      expect(cleared.extensions, {'custom': true});
    },
  );

  test(
    'clone retains prompt/world and catalog, variable and custom metadata',
    () async {
      await repo.put(
        const Character(
          id: 'original',
          name: 'Original',
          extensions: {
            'depth_prompt': {
              'prompt': 'Original prompt',
              'depth': 9,
              'role': 'user',
              'extra': 1,
            },
            'world': 'Original book',
            'catalogUrl': 'https://example.invalid/card',
            'variables': {'count': 3},
            'custom': {'flag': true},
          },
        ),
      );
      final original = (await repo.getById('original'))!;
      await repo.put(
        original.copyWith(
          id: 'clone',
          variantGroupId: 'original',
          variantOrder: 1,
        ),
      );
      final clone = (await repo.getById('clone'))!;
      expect(clone.extensions, original.extensions);
      expect(clone.depthPrompt, original.depthPrompt);
      expect(clone.depthPromptDepth, original.depthPromptDepth);
      expect(clone.depthPromptRole, original.depthPromptRole);
      expect(clone.world, original.world);
    },
  );

  test('missing or malformed V2 values use safe model defaults', () async {
    await repo.putAll([
      const Character(id: 'missing', name: 'Missing'),
      const Character(
        id: 'malformed',
        name: 'Malformed',
        extensions: {
          'depth_prompt': {'prompt': 3, 'depth': 'bad', 'role': ''},
          'world': 5,
        },
      ),
      const Character(
        id: 'not-map',
        name: 'Not map',
        extensions: {'depth_prompt': 'bad', 'world': ''},
      ),
    ]);
    for (final id in ['missing', 'malformed', 'not-map']) {
      final saved = (await repo.getById(id))!;
      expect(saved.depthPrompt, '');
      expect(saved.depthPromptDepth, 4);
      expect(saved.depthPromptRole, 'system');
      expect(saved.world, isNull);
    }
  });
}
