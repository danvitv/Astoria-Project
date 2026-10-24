import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/preset_repo.dart';
import 'package:glaze_flutter/core/llm/character_tokens.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/content/support_content_mutation.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/content/support_persona_control_adapter.dart';

import 'content_control_fixture.dart';
import 'content_control_isolation.dart';

// Prepared evidence only: actual typed gateway/owning memory repositories with
// the original synthetic native gesture/source fence, not model/ROOT integration.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  contentControlTest(
    'each selected body persists exact long whitespace and explicit empty after owning reload',
    (f) async {
      final text =
          ' \tFirst\r\n${List.filled(100, 'Exact body line\tkept\r\n').join()}Last\n\t \r';
      expect(text.length, greaterThan(256));
      expect(jsonEncode(text).length, lessThan(f.redactor.maxOutputLength));
      final targets = _targets(f);
      for (final target in targets) {
        final before = await _rows(f);
        for (final supplied in [text, '']) {
          final result = await f.call(target.action, {
            'operation': 'editText',
            ...target.arguments,
            'text': supplied,
          }, nativeGesture: true);
          expect(
            result.content['code'],
            'completed',
            reason: '${target.action}/${target.arguments}',
          );
          expect(result.content['effect'], 'persisted');
          expect(await target.reload(), supplied);
          if (target.action == 'astoria_character_manage') {
            final durable = (await f.characters.getById('character'))!;
            expect(
              durable.tokenCount,
              estimateCharacterTokens(durable),
              reason:
                  'The owning token cache is recalculated, never used as a body size bound.',
            );
          }
          expect(
            f.gesture.request!.arguments['text'],
            supplied,
            reason:
                'Exact supplied arguments belong to the original UI, not safe metadata.',
          );
          expect(f.gesture.request!.preview['textLength'], supplied.length);
          _safe(f, result.content, text);
          expect(
            _withoutSelected(await _rows(f), target),
            _withoutSelected(before, target),
            reason:
                'Only the selected body and existing native timestamp/token cache may change.',
          );
          expect(
            f.sources.isSessionPending('synthetic-native-content-source'),
            false,
          );
        }
      }
      expect(f.gesture.begins, targets.length * 2);
      expect(f.gesture.settlements, f.gesture.begins);
      for (final domain in [
        'character',
        'persona',
        'lorebook',
        'preset',
        'studioPreset',
      ]) {
        final result = await f.call('astoria_content_catalog', {
          'domain': domain,
        });
        _safe(f, result.content, text);
      }
      for (final item in [
        ('lorebook', 'lorebook'),
        ('preset', 'collision'),
        ('studioPreset', 'collision'),
      ]) {
        final result = await f.call('astoria_content_handles', {
          'domain': item.$1,
          'id': item.$2,
        });
        _safe(f, result.content, text);
      }
    },
  );

  contentControlTest(
    'JSON-looking prose and whitespace-only bodies are exact; legacy clearText still clears',
    (f) async {
      for (final target in _targets(f)) {
        for (final text in [
          ' \t{"shape": [1, 2], "note": "literal instructions"}\r\n End \t',
          ' \r\n\t ',
        ]) {
          final result = await f.call(target.action, {
            'operation': 'editText',
            ...target.arguments,
            'text': text,
          }, nativeGesture: true);
          expect(result.content['code'], 'completed');
          expect(await target.reload(), text);
          _safe(f, result.content, text);
        }
        final clear = await f.call(target.action, {
          'operation': 'editText',
          ...target.arguments,
          'clearText': true,
        }, nativeGesture: true);
        expect(clear.content['code'], 'completed');
        expect(await target.reload(), '');
        expect(f.gesture.request!.preview['textLength'], 0);
        _safe(f, clear.content, 'literal instructions');
      }
    },
  );

  contentControlTest(
    'child creation accepts exact supplied bodies and empty clearing without exposing names',
    (f) async {
      const text = ' \tNew child body\r\nSecond line\t \r';
      for (final item in [
        ('astoria_lorebook_entry_manage', 'lorebook', <String, Object?>{}),
        (
          'astoria_preset_block_manage',
          'collision',
          <String, Object?>{'name': 'Supplied label'},
        ),
        (
          'astoria_studio_block_manage',
          'collision',
          <String, Object?>{'title': 'Supplied label', 'section': 'final'},
        ),
      ]) {
        final result = await f.call(item.$1, {
          'operation': 'create',
          'id': item.$2,
          ...item.$3,
          'text': text,
        }, nativeGesture: true);
        expect(result.content['code'], 'completed');
        final preview = f.gesture.request!.preview;
        final key = item.$1 == 'astoria_lorebook_entry_manage'
            ? 'entryId'
            : 'blockId';
        final id = preview[key]! as String;
        Future<String> reload() async => switch (item.$1) {
          'astoria_lorebook_entry_manage' => (await f.lorebooks.getById(
            item.$2,
          ))!.entries.singleWhere((e) => e.id == id).content,
          'astoria_preset_block_manage' => (await f.presets.getById(
            item.$2,
          ))!.blocks.singleWhere((b) => b.id == id).content,
          _ => (await f.studio.getById(
            item.$2,
          ))!.blocks.singleWhere((b) => b.id == id).content,
        };
        expect(await reload(), text);
        _safe(f, result.content, text);
        expect(jsonEncode(preview), isNot(contains('Supplied label')));
        final clear = await f.call(item.$1, {
          'operation': 'editText',
          'id': item.$2,
          key: id,
          if (key == 'entryId') 'field': 'content',
          'text': '',
        }, nativeGesture: true);
        expect(clear.content['code'], 'completed');
        expect(await reload(), '');
        _safe(f, clear.content, text);
      }
      expect(
        (await f.presets.getById('collision'))!.name,
        ContentControlFixture.private,
      );
      expect(
        (await f.studio.getById('collision'))!.name,
        ContentControlFixture.private,
      );
    },
  );

  contentControlTest(
    'names, display names, world-book names and entry titles remain strict small metadata',
    (f) async {
      final before = await _rows(f);
      final cases = <(String, Map<String, Object?>, String)>[
        for (final tool in [
          'astoria_character_manage',
          'astoria_persona_manage',
          'astoria_lorebook_manage',
          'astoria_preset_manage',
        ])
          (tool, {'operation': 'create'}, 'name'),
        for (final field in ['name', 'displayName', 'world'])
          (
            'astoria_character_manage',
            {'operation': 'editText', 'id': 'character', 'field': field},
            'text',
          ),
        for (final field in ['name', 'displayName'])
          (
            'astoria_persona_manage',
            {'operation': 'editText', 'id': 'persona', 'field': field},
            'text',
          ),
        (
          'astoria_lorebook_manage',
          {'operation': 'editText', 'id': 'lorebook', 'field': 'name'},
          'text',
        ),
        (
          'astoria_lorebook_entry_manage',
          {
            'operation': 'editText',
            'id': 'lorebook',
            'entryId': 'entry',
            'field': 'comment',
          },
          'text',
        ),
        (
          'astoria_preset_manage',
          {'operation': 'editText', 'id': 'collision', 'field': 'name'},
          'text',
        ),
        (
          'astoria_preset_block_manage',
          {'operation': 'create', 'id': 'collision'},
          'name',
        ),
        for (final op in ['clone', 'rename'])
          (
            'astoria_studio_preset_manage',
            {'operation': op, 'id': 'collision'},
            'name',
          ),
        (
          'astoria_studio_block_manage',
          {'operation': 'create', 'id': 'collision', 'section': 'final'},
          'title',
        ),
      ];
      for (final item in cases) {
        for (final value in [
          'First\nSecond',
          'First\rSecond',
          'First\tSecond',
          ' leading',
          'trailing ',
          '',
          List.filled(257, 'n').join(),
        ]) {
          final result = await f.call(item.$1, {
            ...item.$2,
            item.$3: value,
          }, nativeGesture: true);
          expect(
            result.content['code'],
            'invalidArguments',
            reason: '${item.$1}/${item.$2}',
          );
          expect(result.content['effect'], 'none');
        }
      }
      expect(await _rows(f), before);
      expect(f.gesture.begins, 0);
      // Legacy clearText is still valid for optional native labels, not names.
      for (final item in [
        ('astoria_character_manage', 'character', 'displayName'),
        ('astoria_persona_manage', 'persona', 'displayName'),
        ('astoria_lorebook_entry_manage', 'lorebook', 'comment'),
      ]) {
        final result = await f.call(item.$1, {
          'operation': 'editText',
          'id': item.$2,
          'field': item.$3,
          if (item.$3 == 'comment') 'entryId': 'entry',
          'clearText': true,
        }, nativeGesture: true);
        expect(result.content['code'], 'completed');
      }
      expect((await f.personas.getById('persona'))!.displayName, '');
      expect(
        (await f.lorebooks.getById('lorebook'))!.entries.single.comment,
        '',
      );
    },
  );

  contentControlTest(
    'native schemas opt only text into body bounds; grouped names still accept exactly 256',
    (f) async {
      for (final definition in f.registry.definitions) {
        final properties = definition.parameters['properties']! as Map;
        for (final key in ['name', 'title']) {
          if (properties.containsKey(key)) {
            final field = properties[key] as Map;
            expect(field['maxLength'], 256);
            expect(field['minLength'], 1);
          }
        }
        if (properties.containsKey('text')) {
          final field = properties['text'] as Map;
          expect(field['maxLength'], 32768);
          expect(field['minLength'], 0);
        }
        expect(definition.parameters['additionalProperties'], false);
      }
      final name = List.filled(256, 'n').join();
      for (final item in [
        ('astoria_character_manage', 'character'),
        ('astoria_persona_manage', 'persona'),
        ('astoria_lorebook_manage', 'lorebook'),
        ('astoria_preset_manage', 'collision'),
      ]) {
        final result = await f.call(item.$1, {
          'operation': 'editText',
          'id': item.$2,
          'field': 'name',
          'text': name,
        }, nativeGesture: true);
        expect(result.content['code'], 'completed');
        _safe(f, result.content, name);
      }
      expect((await f.characters.getById('character'))!.name, name);
      expect((await f.personas.getById('persona'))!.name, name);
      expect((await f.lorebooks.getById('lorebook'))!.name, name);
      expect((await f.presets.getById('collision'))!.name, name);
      expect(
        (await f.studio.getById('collision'))!.name,
        ContentControlFixture.private,
      );
    },
  );

  contentControlTest(
    'body admission still refuses secrets, encoded redactor overflow, controls, nesting and irrelevant fields',
    (f) async {
      final before = await _rows(f);
      final base = <String, Object?>{
        'operation': 'editText',
        'id': 'persona',
        'field': 'prompt',
      };
      final cases = <(Map<String, Object?>, String)>[
        ({'text': 'First\nSYNTHETIC_SECRET_VALUE\tLast'}, 'unsafeMetadata'),
        ({'text': List.filled(9000, 'x').join()}, 'unsafeMetadata'),
        ({'text': List.filled(32769, 'x').join()}, 'invalidArguments'),
        ({'text': 'First\u0000Last'}, 'invalidArguments'),
        ({'text': 'First\u200bLast'}, 'invalidArguments'),
        (
          {
            'text': ['First', 'Last'],
          },
          'invalidArguments',
        ),
        (
          {
            'text': {'body': 'First\nLast'},
          },
          'invalidArguments',
        ),
        ({'text': 'First\nLast', 'unknown': true}, 'invalidArguments'),
        ({'text': 'First\nLast', 'clearText': true}, 'invalidArguments'),
        ({'clearText': false}, 'invalidArguments'),
        ({'text': 'First\nLast', 'name': 'irrelevant'}, 'invalidArguments'),
      ];
      for (final item in cases) {
        final result = await f.call('astoria_persona_manage', {
          ...base,
          ...item.$1,
        }, nativeGesture: true);
        expect(result.content['code'], item.$2);
        expect(result.content['effect'], 'none');
        expect(
          result.content.toString(),
          isNot(contains('SYNTHETIC_SECRET_VALUE')),
        );
      }
      expect(await _rows(f), before);
      expect(f.gesture.begins, 0);
    },
  );

  contentControlTest(
    'multiline bodies do not bypass original gesture, source lifetime, cancellation or protected targets',
    (f) async {
      const text = ' \tMust not persist\r\nSecond line \t';
      final args = <String, Object?>{
        'operation': 'editText',
        'id': 'persona',
        'field': 'prompt',
        'text': text,
      };
      final before = await f.personas.getById('persona');
      expect(
        (await f.call('astoria_persona_manage', args)).content['code'],
        'denied',
      );
      f.gesture.uiCurrent = false;
      expect(
        (await f.call(
          'astoria_persona_manage',
          args,
          nativeGesture: true,
        )).content['code'],
        'denied',
      );
      f.gesture.uiCurrent = true;
      final cancelled = f.context()..cancelToken.cancel();
      expect(
        (await f.call(
          'astoria_persona_manage',
          args,
          original: cancelled,
          nativeGesture: true,
        )).content['code'],
        'cancelled',
      );
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
      final original = f.context();
      var fencedAtRead = false;
      f.gesture.beforeGesture = (_) async {
        f.sql.afterNextSelect = () async {
          fencedAtRead = f.sources.isSessionPending(
            'synthetic-native-content-source',
          );
          original.cancelToken.cancel();
        };
      };
      expect(
        (await f.call(
          'astoria_persona_manage',
          args,
          original: original,
          nativeGesture: true,
        )).content['code'],
        'cancelled',
      );
      expect(fencedAtRead, true);
      f.gesture.beforeGesture = null;
      void Function()? finishOther;
      f.gesture.afterBegin = () {
        finishOther = f.sources.beginMutation(
          sessionId: 'synthetic-native-content-source',
        );
      };
      expect(
        (await f.call(
          'astoria_persona_manage',
          args,
          nativeGesture: true,
        )).content['code'],
        'stale',
      );
      finishOther!();
      f.gesture.afterBegin = null;
      expect(await f.personas.getById('persona'), before);
      for (final id in ['locked', 'history']) {
        final result = await f.call('astoria_studio_block_manage', {
          'operation': 'editText',
          'id': 'collision',
          'blockId': id,
          'text': text,
        }, nativeGesture: true);
        expect(result.content['code'], 'denied');
        _safe(f, result.content, text);
      }
      final protectedBlock = await f.call('astoria_preset_block_manage', {
        'operation': 'editText',
        'id': 'collision',
        'blockId': 'chat_history',
        'text': text,
      }, nativeGesture: true);
      expect(protectedBlock.content['code'], 'denied');
      expect(f.gesture.begins, f.gesture.settlements);
      expect(
        f.sources.isSessionPending('synthetic-native-content-source'),
        false,
      );
    },
  );

  contentControlTest(
    'multiline selected body CAS preserves a concurrent owner in every body family',
    (f) async {
      for (final target in _targets(f)) {
        final before = await _rows(f);
        f.gesture.beforeGesture = (_) async {
          switch (target.action) {
            case 'astoria_character_manage':
              final c = (await f.characters.getById('character'))!;
              await f.characters.put(
                c.copyWith(creatorNotes: '${c.creatorNotes ?? ''}concurrent'),
              );
            case 'astoria_persona_manage':
              final persona = (await f.personas.getById('persona'))!;
              await f.personas.put(
                persona.copyWith(prompt: '${persona.prompt}concurrent'),
              );
            case 'astoria_lorebook_manage' || 'astoria_lorebook_entry_manage':
              final b = (await f.lorebooks.getById('lorebook'))!;
              await f.lorebooks.put(
                b.copyWith(description: '${b.description}concurrent'),
              );
            case 'astoria_preset_manage' || 'astoria_preset_block_manage':
              final preset = (await f.presets.getById('collision'))!;
              await f.presets.put(
                preset.copyWith(
                  summaryPrompt: '${preset.summaryPrompt ?? ''}concurrent',
                ),
              );
            default:
              final studio = (await f.studio.getById('collision'))!;
              await f.studio.upsert(
                studio.copyWith(name: '${studio.name}concurrent'),
              );
          }
        };
        Map<String, Map<String, dynamic>>? concurrent;
        final mutate = f.gesture.beforeGesture!;
        f.gesture.beforeGesture = (request) async {
          await mutate(request);
          concurrent = await _rows(f);
        };
        final result = await f.call(target.action, {
          'operation': 'editText',
          ...target.arguments,
          'text': ' \tStale body\r\nMust not overwrite \t',
        }, nativeGesture: true);
        expect(result.content['code'], 'conflict');
        expect(result.content['effect'], 'none');
        expect(concurrent, isNot(before));
        expect(await _rows(f), concurrent);
        _safe(f, result.content, 'Must not overwrite');
      }
      f.gesture.beforeGesture = null;
      expect(f.gesture.begins, f.gesture.settlements);
    },
  );

  contentControlTest(
    'multiline raw JSON patches preserve unknown root, block, routing and entry fields',
    (f) async {
      final normal = await f.db.select(f.db.presets).getSingle();
      final normalData = jsonDecode(normal.dataJson) as Map<String, dynamic>;
      normalData['nativePrivateUnknown'] = ContentControlFixture.private;
      (normalData['blocks'] as List).first['nativePrivateUnknown'] =
          ContentControlFixture.private;
      await f.db
          .update(f.db.presets)
          .write(PresetsCompanion(dataJson: Value(jsonEncode(normalData))));
      final studio = await f.db.select(f.db.studioPresetRows).getSingle();
      final studioBlocks = jsonDecode(studio.blocksJson) as List;
      studioBlocks.first['nativePrivateUnknown'] =
          ContentControlFixture.private;
      await f.db
          .update(f.db.studioPresetRows)
          .write(
            StudioPresetRowsCompanion(
              blocksJson: Value(jsonEncode(studioBlocks)),
            ),
          );
      final book = await f.db.select(f.db.lorebooks).getSingle();
      final entries = jsonDecode(book.entriesJson) as List;
      entries.first['nativePrivateUnknown'] = ContentControlFixture.private;
      await f.db
          .update(f.db.lorebooks)
          .write(LorebooksCompanion(entriesJson: Value(jsonEncode(entries))));
      for (final target in _targets(f).where(
        (t) => [
          'astoria_preset_manage',
          'astoria_preset_block_manage',
          'astoria_studio_block_manage',
          'astoria_lorebook_entry_manage',
        ].contains(t.action),
      )) {
        final before = await _rows(f);
        const text = ' \tNew exact raw body\r\nLast line \t';
        final result = await f.call(target.action, {
          'operation': 'editText',
          ...target.arguments,
          'text': text,
        }, nativeGesture: true);
        expect(result.content['code'], 'completed');
        expect(await target.reload(), text);
        expect(
          _withoutSelected(await _rows(f), target),
          _withoutSelected(before, target),
        );
        _safe(f, result.content, text);
      }
    },
  );
}

final class _BodyTarget {
  const _BodyTarget(
    this.action,
    this.arguments,
    this.table,
    this.column,
    this.path,
    this.reload,
  );
  final String action, table, column;
  final Map<String, Object?> arguments;
  final List<Object> path;
  final Future<String?> Function() reload;
}

List<_BodyTarget> _targets(ContentControlFixture f) => [
  for (final field in CharacterControlText.values.where(
    (v) => ![
      CharacterControlText.name,
      CharacterControlText.displayName,
      CharacterControlText.world,
    ].contains(v),
  ))
    _BodyTarget(
      'astoria_character_manage',
      {'id': 'character', 'field': field.name},
      f.db.characters.actualTableName,
      field == CharacterControlText.depthPrompt ? 'extensionsJson' : field.name,
      field == CharacterControlText.depthPrompt ? ['depth_prompt'] : [],
      () async {
        final c = (await f.characters.getById('character'))!;
        return switch (field) {
          CharacterControlText.description => c.description,
          CharacterControlText.personality => c.personality,
          CharacterControlText.scenario => c.scenario,
          CharacterControlText.firstMes => c.firstMes,
          CharacterControlText.mesExample => c.mesExample,
          CharacterControlText.systemPrompt => c.systemPrompt,
          CharacterControlText.postHistoryInstructions =>
            c.postHistoryInstructions,
          CharacterControlText.creatorNotes => c.creatorNotes,
          CharacterControlText.depthPrompt => c.depthPrompt,
          _ => throw StateError('Not a body target.'),
        };
      },
    ),
  _BodyTarget(
    'astoria_persona_manage',
    {'id': 'persona', 'field': 'prompt'},
    f.db.personas.actualTableName,
    'prompt',
    [],
    () async => (await f.personas.getById('persona'))!.prompt,
  ),
  _BodyTarget(
    'astoria_lorebook_manage',
    {'id': 'lorebook', 'field': 'description'},
    f.db.lorebooks.actualTableName,
    'description',
    [],
    () async => (await f.lorebooks.getById('lorebook'))!.description,
  ),
  _BodyTarget(
    'astoria_lorebook_entry_manage',
    {'id': 'lorebook', 'entryId': 'entry', 'field': 'content'},
    f.db.lorebooks.actualTableName,
    'entriesJson',
    [0, 'content'],
    () async => (await f.lorebooks.getById('lorebook'))!.entries.single.content,
  ),
  for (final field in PresetControlText.values.where(
    (v) => v != PresetControlText.name,
  ))
    _BodyTarget(
      'astoria_preset_manage',
      {'id': 'collision', 'field': field.name},
      f.db.presets.actualTableName,
      'dataJson',
      [field.name],
      () async {
        final p = (await f.presets.getById('collision'))!;
        return switch (field) {
          PresetControlText.summaryPrompt => p.summaryPrompt,
          PresetControlText.guidedGenerationPrompt => p.guidedGenerationPrompt,
          PresetControlText.guidedImpersonationPrompt =>
            p.guidedImpersonationPrompt,
          PresetControlText.impersonationPrompt => p.impersonationPrompt,
          _ => throw StateError('Not a body target.'),
        };
      },
    ),
  _BodyTarget(
    'astoria_preset_block_manage',
    {'id': 'collision', 'blockId': 'ordinary-block'},
    f.db.presets.actualTableName,
    'dataJson',
    ['blocks', 0, 'content'],
    () async => (await f.presets.getById('collision'))!.blocks.first.content,
  ),
  _BodyTarget(
    'astoria_studio_block_manage',
    {'id': 'collision', 'blockId': 'studio-block'},
    f.db.studioPresetRows.actualTableName,
    'blocksJson',
    [0, 'content'],
    () async => (await f.studio.getById('collision'))!.blocks.first.content,
  ),
];

Future<Map<String, Map<String, dynamic>>> _rows(
  ContentControlFixture f,
) async => {
  f.db.characters.actualTableName:
      (await f.db.select(f.db.characters).getSingle()).toJson(),
  // The owning compatibility codec includes display_name, which the generated
  // Drift PersonaRow does not expose. Do not omit that private column assertion.
  f.db.personas.actualTableName: (await f.personas.getById(
    'persona',
  ))!.toJson(),
  f.db.lorebooks.actualTableName:
      (await f.db.select(f.db.lorebooks).getSingle()).toJson(),
  f.db.presets.actualTableName: (await f.db.select(f.db.presets).getSingle())
      .toJson(),
  f.db.studioPresetRows.actualTableName:
      (await f.db.select(f.db.studioPresetRows).getSingle()).toJson(),
};

Map<String, dynamic> _withoutSelected(
  Map<String, Map<String, dynamic>> rows,
  _BodyTarget target,
) {
  final result = jsonDecode(jsonEncode(rows)) as Map<String, dynamic>;
  final row = result[target.table] as Map<String, dynamic>;
  // Only the target table's established owning cache/timestamp is ignored.
  if (target.action == 'astoria_character_manage') row.remove('tokenCount');
  if (target.action == 'astoria_lorebook_manage' ||
      target.action == 'astoria_lorebook_entry_manage' ||
      target.action == 'astoria_studio_block_manage')
    row.remove('updatedAt');
  if (target.path.isEmpty) {
    row.remove(target.column);
  } else {
    final raw = jsonDecode(row[target.column] as String);
    dynamic parent = raw;
    for (final key in target.path.take(target.path.length - 1)) {
      parent = parent[key];
    }
    (parent as Map).remove(target.path.last);
    row[target.column] = raw;
  }
  return result;
}

void _safe(
  ContentControlFixture f,
  Map<String, Object?> result,
  String supplied,
) {
  for (final metadata in [
    result,
    f.gesture.request?.preview ?? <String, Object?>{},
  ]) {
    final encoded = jsonEncode(metadata);
    expect(encoded, isNot(contains(ContentControlFixture.private)));
    if (supplied.isNotEmpty) expect(encoded, isNot(contains(supplied)));
    void bounded(Object? value, int depth) {
      expect(depth, lessThanOrEqualTo(4));
      if (value is String) {
        expect(value.length, lessThanOrEqualTo(256));
        expect(value, isNot(contains(ContentControlFixture.private)));
        if (supplied.isNotEmpty) expect(value, isNot(contains(supplied)));
      }
      if (value is Map) {
        expect(value.length, lessThanOrEqualTo(32));
        for (final entry in value.entries) {
          bounded(entry.key, depth + 1);
          bounded(entry.value, depth + 1);
        }
      } else if (value is List) {
        expect(value.length, lessThanOrEqualTo(32));
        for (final item in value) {
          bounded(item, depth + 1);
        }
      }
    }

    bounded(metadata, 0);
  }
}
