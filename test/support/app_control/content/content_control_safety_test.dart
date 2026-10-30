import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/preset_folder_repo.dart';
import 'package:glaze_flutter/core/models/preset_folder.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/content/support_persona_control_adapter.dart';

import 'content_control_fixture.dart';
import 'content_control_isolation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  contentControlTest(
    'strict schema rejects wrong, unknown, multiline names, body-read and deletion arguments without effect',
    (f) async {
      final before = await f.characters.getById('character');
      for (final args in <Map<String, Object?>>[
        {'operation': 'read', 'id': 'character'},
        {'operation': 'delete', 'id': 'character'},
        {
          'operation': 'editText',
          'id': 'character',
          'field': 'name',
          'text': 'line one\nline two',
        },
        {
          'operation': 'editText',
          'id': 'character',
          'field': 'name',
          'text': List.filled(257, 'x').join(),
        },
        {
          'operation': 'editText',
          'id': 'character',
          'field': 'description',
          'text': 'x',
          'clearText': true,
        },
        {'operation': 'create', 'name': 'x', 'id': 'chosen-overwrite-id'},
        {'operation': 'favoriteGroup', 'id': 'character', 'value': 'true'},
        {
          'operation': 'favoriteGroup',
          'id': 'character',
          'value': true,
          'payload': '{}',
        },
      ]) {
        final result = await f.call(
          'astoria_character_manage',
          args,
          nativeGesture: true,
        );
        expect(result.content['code'], 'invalidArguments');
        expect(result.content['effect'], 'none');
      }
      expect(await f.characters.getById('character'), before);
      expect(f.gesture.begins, 0);
      final body = await f.call('astoria_content_read', {'id': 'character'});
      expect(body.content['code'], 'unknownAction');
      expect(
        body.content.toString(),
        isNot(contains(ContentControlFixture.private)),
      );
    },
  );

  contentControlTest(
    'no native gesture, revoked UI, cancelled context and absent source port never mutate',
    (f) async {
      final args = <String, Object?>{
        'operation': 'editText',
        'id': 'persona',
        'field': 'prompt',
        'text': 'Supplied',
      };
      final before = await f.personas.getById('persona');
      final noGesture = await f.call('astoria_persona_manage', args);
      expect(noGesture.content['code'], 'denied');
      f.gesture.uiCurrent = false;
      final revoked = await f.call(
        'astoria_persona_manage',
        args,
        nativeGesture: true,
      );
      expect(revoked.content['code'], 'denied');
      f.gesture.uiCurrent = true;
      final cancelled = f.context()..cancelToken.cancel();
      expect(
        (await f.call(
          'astoria_persona_manage',
          args,
          original: cancelled,
        )).content['code'],
        'cancelled',
      );
      final original = f.context();
      f.gesture.beforeGesture = (_) async {
        f.current = false;
      };
      expect(
        (await f.call(
          'astoria_persona_manage',
          args,
          original: original,
          nativeGesture: true,
        )).content['code'],
        'stale',
      );
      f.current = true;
      f.gesture.beforeGesture = null;
      // Match the production reserved/null source input without replacing any
      // captured repository/notifier graph or constructing default services.
      final unavailable = f.buildRegistry([
        SupportPersonaControlAdapter(
          repo: f.personas,
          mutations: SupportContentMutation(isOwnerCurrent: () => f.current),
          newId: () => 'unused',
          clock: () => 1,
          refresh: () {},
        ),
      ]);
      expect(
        (await f.call(
          'astoria_persona_manage',
          args,
          nativeGesture: true,
          gateway: unavailable,
        )).content['code'],
        'unavailable',
      );
      expect(await f.personas.getById('persona'), before);
    },
  );

  contentControlTest(
    'each family rejects exact-row conflict instead of overwriting a concurrent owner',
    (f) async {
      final mutations =
          <(String, Map<String, Object?>, Future<void> Function())>[
            (
              'astoria_character_manage',
              {
                'operation': 'editText',
                'id': 'character',
                'field': 'description',
                'text': 'stale',
              },
              () async {
                final c = (await f.characters.getById('character'))!;
                await f.characters.put(c.copyWith(description: 'concurrent'));
              },
            ),
            (
              'astoria_persona_manage',
              {
                'operation': 'editText',
                'id': 'persona',
                'field': 'prompt',
                'text': 'stale',
              },
              () async {
                final p = (await f.personas.getById('persona'))!;
                await f.personas.put(p.copyWith(prompt: 'concurrent'));
              },
            ),
            (
              'astoria_lorebook_manage',
              {
                'operation': 'editText',
                'id': 'lorebook',
                'field': 'description',
                'text': 'stale',
              },
              () async {
                final b = (await f.lorebooks.getById('lorebook'))!;
                await f.lorebooks.put(b.copyWith(description: 'concurrent'));
              },
            ),
            (
              'astoria_preset_manage',
              {
                'operation': 'editText',
                'id': 'collision',
                'field': 'summaryPrompt',
                'text': 'stale',
              },
              () async {
                final p = (await f.presets.getById('collision'))!;
                await f.presets.put(p.copyWith(summaryPrompt: 'concurrent'));
              },
            ),
            (
              'astoria_studio_preset_manage',
              {'operation': 'rename', 'id': 'collision', 'name': 'stale'},
              () async {
                final p = (await f.studio.getById('collision'))!;
                await f.studio.upsert(p.copyWith(name: 'concurrent'));
              },
            ),
          ];
      for (final item in mutations) {
        f.gesture.beforeGesture = (_) => item.$3();
        final result = await f.call(item.$1, item.$2, nativeGesture: true);
        expect(result.content['code'], 'conflict');
        expect(result.content['effect'], 'none');
      }
      f.gesture.beforeGesture = null;
      expect(
        (await f.characters.getById('character'))!.description,
        'concurrent',
      );
      expect((await f.personas.getById('persona'))!.prompt, 'concurrent');
      expect(
        (await f.lorebooks.getById('lorebook'))!.description,
        'concurrent',
      );
      expect(
        (await f.presets.getById('collision'))!.summaryPrompt,
        'concurrent',
      );
      expect((await f.studio.getById('collision'))!.name, 'concurrent');
      expect(f.gesture.begins, f.gesture.settlements);
    },
  );

  contentControlTest(
    'source guard is synchronous and cancellation after actual SQLite read has no write',
    (f) async {
      final before = await f.personas.getById('persona');
      final original = f.context();
      var pendingAtRead = false;
      f.gesture.beforeGesture = (_) async {
        f.sql.afterNextSelect = () async {
          pendingAtRead = f.sources.isSessionPending(
            'synthetic-native-content-source',
          );
          original.cancelToken.cancel();
        };
      };
      final result = await f.call(
        'astoria_persona_manage',
        {
          'operation': 'editText',
          'id': 'persona',
          'field': 'prompt',
          'text': 'must not persist',
        },
        nativeGesture: true,
        original: original,
      );
      expect(pendingAtRead, true);
      expect(result.content['code'], 'cancelled');
      expect(result.content['effect'], 'none');
      expect(await f.personas.getById('persona'), before);
      expect(
        f.sources.isSessionPending('synthetic-native-content-source'),
        false,
      );
      expect(f.gesture.begins, f.gesture.settlements);
    },
  );

  contentControlTest(
    'locked/history blocks, session canon books, card forks and Main Writer are protected',
    (f) async {
      await f.characters.put(
        const Character(
          id: 'fork',
          name: 'Native fork',
          variantGroupId: 'character',
          variantOrder: 1,
        ),
      );
      await f.lorebooks.put(
        const Lorebook(
          id: 'session-canon',
          name: 'Native canon',
          activationScope: 'chat',
          activationTargetId: 'session',
        ),
      );
      final cases = <(String, Map<String, Object?>)>[
        (
          'astoria_character_manage',
          {
            'operation': 'editText',
            'id': 'fork',
            'field': 'description',
            'text': 'x',
          },
        ),
        (
          'astoria_lorebook_manage',
          {'operation': 'setEnabled', 'id': 'session-canon', 'enabled': false},
        ),
        (
          'astoria_preset_block_manage',
          {
            'operation': 'settings',
            'id': 'collision',
            'blockId': 'chat_history',
            'enabled': false,
          },
        ),
        (
          'astoria_studio_block_manage',
          {
            'operation': 'editText',
            'id': 'collision',
            'blockId': 'locked',
            'text': 'x',
          },
        ),
        (
          'astoria_studio_block_manage',
          {
            'operation': 'settings',
            'id': 'collision',
            'blockId': 'history',
            'enabled': false,
          },
        ),
        (
          'astoria_studio_agent_set',
          {'id': 'collision', 'controller': 'final', 'enabled': false},
        ),
      ];
      for (final item in cases) {
        expect(
          (await f.call(item.$1, item.$2, nativeGesture: true)).content['code'],
          'denied',
        );
      }
      expect(f.gesture.begins, 0);
    },
  );

  contentControlTest(
    'a newer source admission retires the old fence before repository mutation',
    (f) async {
      final before = await f.personas.getById('persona');
      void Function()? finishOther;
      f.gesture.afterBegin = () {
        finishOther = f.sources.beginMutation(
          sessionId: 'synthetic-native-content-source',
        );
      };
      final result = await f.call('astoria_persona_manage', {
        'operation': 'editText',
        'id': 'persona',
        'field': 'prompt',
        'text': 'must not persist',
      }, nativeGesture: true);
      expect(result.content['code'], 'stale');
      expect(result.content['effect'], 'none');
      expect(await f.personas.getById('persona'), before);
      expect(f.gesture.begins, f.gesture.settlements);
      finishOther!();
      expect(
        f.sources.isSessionPending('synthetic-native-content-source'),
        false,
      );
    },
  );

  contentControlTest(
    'PresetKind collision memberships are untouched; no unsafe deletion definition exists',
    (f) async {
      final folders = PresetFolderRepo(f.db);
      final folder = await folders.create(name: 'Native private folder');
      await folders.addMember(folder.id, 'collision', PresetKind.normal);
      await folders.addMember(folder.id, 'collision', PresetKind.agentic);
      final before = await folders.watchMembers().first;
      for (final tool in [
        'astoria_preset_manage',
        'astoria_studio_preset_manage',
      ]) {
        final result = await f.call(tool, {
          'operation': 'delete',
          'id': 'collision',
        }, nativeGesture: true);
        expect(result.content['code'], 'invalidArguments');
      }
      expect(await folders.watchMembers().first, before);
      expect(await f.presets.getById('collision'), isNotNull);
      expect(await f.studio.getById('collision'), isNotNull);
    },
  );

  contentControlTest(
    'JSON patch preserves unknown raw import fields and native private prompts',
    (f) async {
      final row = await f.db.select(f.db.presets).getSingle();
      final data = jsonDecode(row.dataJson) as Map<String, dynamic>;
      data['nativePrivateUnknown'] = ContentControlFixture.private;
      (data['blocks'] as List).first['nativePrivateUnknown'] =
          ContentControlFixture.private;
      await (f.db.update(f.db.presets)
            ..where((t) => t.presetId.equals('collision')))
          .write(PresetsCompanion(dataJson: Value(jsonEncode(data))));
      final result = await f.call('astoria_preset_block_manage', {
        'operation': 'settings',
        'id': 'collision',
        'blockId': 'ordinary-block',
        'enabled': false,
      }, nativeGesture: true);
      expect(result.content['code'], 'completed');
      final after =
          jsonDecode((await f.db.select(f.db.presets).getSingle()).dataJson)
              as Map;
      expect(after['nativePrivateUnknown'], ContentControlFixture.private);
      expect(
        (after['blocks'] as List).first['nativePrivateUnknown'],
        ContentControlFixture.private,
      );
      expect(
        (after['blocks'] as List).first['content'],
        ContentControlFixture.private,
      );
      expect(
        result.content.toString(),
        isNot(contains(ContentControlFixture.private)),
      );
    },
  );
}
