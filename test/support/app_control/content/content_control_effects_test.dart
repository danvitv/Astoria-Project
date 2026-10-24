import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/studio_preset_repo.dart';
import 'package:glaze_flutter/core/state/character_provider.dart';
import 'package:glaze_flutter/core/state/lorebook_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/personas/persona_list_provider.dart';
import 'package:glaze_flutter/features/presets/preset_list_provider.dart';

import 'content_control_fixture.dart';
import 'content_control_isolation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  contentControlTest(
    'actual family repositories + owning notifier refresh after exact native confirmation',
    (f) async {
      await f.container.read(charactersProvider.future);
      await f.container.read(personaListProvider.future);
      await f.container.read(lorebooksProvider.future);
      await f.container.read(presetListProvider.future);
      await f.container.read(studioPresetListProvider.future);
      for (final item in [
        ('astoria_character_manage', 'character', 'description'),
        ('astoria_persona_manage', 'persona', 'prompt'),
        ('astoria_lorebook_manage', 'lorebook', 'description'),
        ('astoria_preset_manage', 'collision', 'summaryPrompt'),
      ]) {
        final result = await f.call(item.$1, {
          'operation': 'editText',
          'id': item.$2,
          'field': item.$3,
          'text': 'New supplied text',
        }, nativeGesture: true);
        expect(result.content['code'], 'completed');
        expect(result.content['effect'], 'persisted');
        expect(
          result.content.toString(),
          isNot(contains(ContentControlFixture.private)),
        );
        expect(f.gesture.request!.preview['undoAvailable'], false);
      }
      final studio = await f.call('astoria_studio_preset_manage', {
        'operation': 'rename',
        'id': 'collision',
        'name': 'New Studio name',
      }, nativeGesture: true);
      expect(studio.content['code'], 'completed');
      final chars = await f.container.read(charactersProvider.future);
      expect(chars.single.description, 'New supplied text');
      expect(chars.single.systemPrompt, ContentControlFixture.private);
      expect(chars.single.currentSessionIndex, 4);
      expect(
        chars.single.extensions['privateNative'],
        ContentControlFixture.private,
      );
      final personas = await f.container.read(personaListProvider.future);
      expect(personas.single.prompt, 'New supplied text');
      expect(personas.single.displayName, ContentControlFixture.private);
      final books = await f.container.read(lorebooksProvider.future);
      expect(books.single.description, 'New supplied text');
      expect(
        books.single.entries.single.content,
        ContentControlFixture.private,
      );
      final ordinary = await f.container.read(presetListProvider.future);
      expect(ordinary.single.summaryPrompt, 'New supplied text');
      expect(ordinary.single.name, ContentControlFixture.private);
      final studioRows = await f.container.read(
        studioPresetListProvider.future,
      );
      expect(studioRows.single.name, 'New Studio name');
      expect(
        studioRows.single.blocks.first.content,
        ContentControlFixture.private,
      );
      expect(f.gesture.begins, 5);
      expect(f.gesture.settlements, 5);
    },
  );

  contentControlTest(
    'create persists native IDs without reading/cloning an existing private body',
    (f) async {
      for (final item in [
        ('astoria_character_manage', 'character'),
        ('astoria_persona_manage', 'persona'),
        ('astoria_lorebook_manage', 'lorebook'),
        ('astoria_preset_manage', 'preset'),
      ]) {
        final result = await f.call(item.$1, {
          'operation': 'create',
          'name': 'Supplied name',
        }, nativeGesture: true);
        expect(result.content['code'], 'completed');
        final data = result.content['data']! as Map;
        final id = data['id']! as String;
        expect(id, isNotEmpty);
        final list = await f.call('astoria_content_catalog', {
          'domain': item.$2,
        });
        expect((list.content['data']! as Map)['ids'], contains(id));
        expect((list.content['data']! as Map)['count'], 2);
      }
      expect(
        f.gesture.begins,
        0,
        reason:
            'Fresh native-generated rows cannot overwrite an existing source.',
      );
      final clone = await f.call('astoria_studio_preset_manage', {
        'operation': 'clone',
        'id': 'collision',
        'name': 'Supplied Studio clone',
      }, nativeGesture: true);
      expect(clone.content['code'], 'completed');
      final id = (clone.content['data']! as Map)['id']! as String;
      final copy = await f.studio.getById(id);
      expect(copy!.blocks.first.content, ContentControlFixture.private);
      expect(await f.presets.getById(id), isNull);
      expect(f.gesture.begins, 1);
    },
  );

  contentControlTest(
    'whole-group flags persist to every exact native variation with source text untouched',
    (f) async {
      await f.characters.put(
        const Character(
          id: 'variation',
          name: 'Native variation',
          description: ContentControlFixture.private,
          variantGroupId: 'character',
          variantOrder: 1,
        ),
      );
      final result = await f.call('astoria_character_manage', {
        'operation': 'hideGroup',
        'id': 'character',
        'value': true,
      }, nativeGesture: true);
      expect(result.content['code'], 'completed');
      expect(f.gesture.request!.preview['affectedRows'], 2);
      final rows = await f.characters.getVariants('character');
      expect(rows.every((c) => c.hidden), true);
      expect(
        rows.every((c) => c.description == ContentControlFixture.private),
        true,
      );
    },
  );

  contentControlTest(
    'entry/block settings are actual narrow persisted effects with private bodies untouched',
    (f) async {
      final entry = await f.call('astoria_lorebook_entry_manage', {
        'operation': 'settings',
        'id': 'lorebook',
        'entryId': 'entry',
        'enabled': false,
        'constant': true,
        'probability': 40,
        'order': 3,
      }, nativeGesture: true);
      expect(entry.content['code'], 'completed');
      final book = (await f.lorebooks.getById('lorebook'))!;
      expect(book.entries.single.enabled, false);
      expect(book.entries.single.constant, true);
      expect(book.entries.single.probability, 40);
      expect(book.entries.single.keys, [ContentControlFixture.private]);
      expect(book.entries.single.content, ContentControlFixture.private);
      expect(book.name, ContentControlFixture.private);
      final normal = await f.call('astoria_preset_block_manage', {
        'operation': 'settings',
        'id': 'collision',
        'blockId': 'ordinary-block',
        'enabled': false,
        'depth': 2,
      }, nativeGesture: true);
      expect(normal.content['code'], 'completed');
      final preset = (await f.presets.getById('collision'))!;
      expect(preset.blocks.first.enabled, false);
      expect(preset.blocks.first.depth, 2);
      expect(preset.blocks.first.content, ContentControlFixture.private);
      expect((await f.studio.getById('collision'))!.blocks.first.enabled, true);
      final studio = await f.call('astoria_studio_block_manage', {
        'operation': 'editText',
        'id': 'collision',
        'blockId': 'studio-block',
        'text': 'New short Studio instruction',
      }, nativeGesture: true);
      expect(studio.content['code'], 'completed');
      expect(
        (await f.studio.getById('collision'))!.blocks.first.content,
        'New short Studio instruction',
      );
      expect(
        (await f.presets.getById('collision'))!.blocks.first.content,
        ContentControlFixture.private,
      );
    },
  );

  contentControlTest(
    'new child IDs are executable handles without outbound names or bodies',
    (f) async {
      for (final item in [
        (
          'astoria_lorebook_entry_manage',
          'lorebook',
          'lorebook',
          <String, Object?>{'text': 'New supplied entry'},
        ),
        (
          'astoria_preset_block_manage',
          'preset',
          'collision',
          <String, Object?>{
            'name': 'New supplied block',
            'text': 'New supplied content',
          },
        ),
        (
          'astoria_studio_block_manage',
          'studioPreset',
          'collision',
          <String, Object?>{
            'title': 'New supplied title',
            'section': 'final',
            'text': 'New supplied instruction',
          },
        ),
      ]) {
        final create = await f.call(item.$1, {
          'operation': 'create',
          'id': item.$3,
          ...item.$4,
        }, nativeGesture: true);
        expect(create.content['code'], 'completed');
        final handles = await f.call('astoria_content_handles', {
          'domain': item.$2,
          'id': item.$3,
        });
        expect(handles.content['code'], 'completed');
        expect(
          handles.content.toString(),
          isNot(contains(ContentControlFixture.private)),
        );
        expect(handles.content.toString(), isNot(contains('New supplied')));
        final ids = ((handles.content['data']! as Map)['ids']! as List)
            .cast<String>();
        final nativeCreated = f
            .gesture
            .request!
            .preview[item.$2 == 'lorebook' ? 'entryId' : 'blockId'];
        expect(ids, contains(nativeCreated));
      }
    },
  );

  contentControlTest(
    'next-turn Studio runtime patches preserve native private settings and roster',
    (f) async {
      final before = (await f.studio.getById('collision'))!;
      final patch = await f.call('astoria_studio_runtime_manage', {
        'id': 'collision',
        'lane': 'cleaner',
        'maxTokens': 2400,
        'enabled': false,
      }, nativeGesture: true);
      expect(patch.content['code'], 'completed');
      final after = (await f.studio.getById('collision'))!;
      expect(after.runtime.cleaner!.postCleanerMaxTokens, 2400);
      expect(after.runtime.cleaner!.postCleanerEnabled, false);
      expect(
        after.runtime.cleaner!.postCleanerBannedWords,
        ContentControlFixture.private,
      );
      expect(after.agents, before.agents);
      expect(after.blocks, before.blocks);
      expect(
        before.runtime.cleaner!.postCleanerEnabled,
        true,
        reason: 'The already-owned immutable value is not mutated.',
      );
      expect(f.gesture.request!.preview['nextTurnOnly'], true);
      final ledger = await f.call('astoria_studio_runtime_manage', {
        'id': 'collision',
        'lane': 'ledger',
        'maxTokens': 2000,
      }, nativeGesture: true);
      expect(ledger.content['code'], 'completed');
      expect(
        (await f.studio.getById(
          'collision',
        ))!.runtime.ledger!.studioLedgerModel,
        'synthetic-model',
      );
    },
  );

  contentControlTest(
    'canonical native agent toggle retains dependency restoration without changing Main Writer',
    (f) async {
      final off = await f.call('astoria_studio_agent_set', {
        'id': 'collision',
        'controller': 'ledger',
        'enabled': false,
      }, nativeGesture: true);
      expect(off.content['code'], 'completed');
      final disabled = (await f.studio.controlObserve('collision'))!;
      expect(disabled.agentEnabled['continuity'], false);
      expect(disabled.agentEnabledBeforeDependencyOff['continuity'], true);
      final on = await f.call('astoria_studio_agent_set', {
        'id': 'collision',
        'controller': 'ledger',
        'enabled': true,
      }, nativeGesture: true);
      expect(on.content['code'], 'completed');
      final enabled = (await f.studio.controlObserve('collision'))!;
      expect(enabled.agentEnabled['continuity'], true);
      expect(enabled.agentEnabledBeforeDependencyOff, isEmpty);
      expect(
        enabled.agents.any((a) => a.controllerId == 'final' && a.enabled),
        true,
      );
    },
  );
}
