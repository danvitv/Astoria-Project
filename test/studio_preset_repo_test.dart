import 'dart:convert';

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/studio_preset_repo.dart';
import 'package:glaze_flutter/core/llm/studio_turn_config_snapshot.dart';
import 'package:glaze_flutter/core/models/ledger_prompt_injection_mode.dart';
import 'package:glaze_flutter/core/models/ledger_prompt_injection_policy.dart';
import 'package:glaze_flutter/core/models/pipeline_settings.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/features/studio/studio_agent_toggle.dart';

void main() {
  late AppDatabase db;
  late StudioPresetRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = StudioPresetRepo(db);
  });
  tearDown(() => db.close());

  test('round-trips complete preset runtime payload', () async {
    const preset = StudioPreset(
      id: 'studio_direct_loom_v1',
      name: 'Direct Loom v1',
      agentEnabled: {'continuity': false, 'final': true},
      agentEnabledBeforeDependencyOff: {'continuity': true, 'world': false},
      agents: [
        StudioAgent(id: 'continuity', controllerId: 'continuity'),
        StudioAgent(id: 'final', controllerId: 'final'),
      ],
      expensiveApiConfigId: 'expensive',
      cheapApiConfigId: 'cheap',
      cleanerApiConfigId: 'cleaner',
      maxFinalHistoryMessages: 17,
      runtime: StudioRuntimeSettings(
        broadcastBlocks: ['\uFEFFfirst\r\nline', 'second\nline'],
      ),
    );

    await repo.upsert(preset);
    final restored = await repo.getById(preset.id);

    expect(restored?.agentEnabled, preset.agentEnabled);
    expect(
      restored?.agentEnabledBeforeDependencyOff,
      preset.agentEnabledBeforeDependencyOff,
    );
    expect(restored?.agents, preset.agents);
    expect(restored?.expensiveApiConfigId, 'expensive');
    expect(restored?.cheapApiConfigId, 'cheap');
    expect(restored?.cleanerApiConfigId, 'cleaner');
    expect(restored?.maxFinalHistoryMessages, 17);
    expect(restored?.runtime, preset.runtime);
    expect(restored?.runtime.broadcastBlocks, preset.runtime.broadcastBlocks);
    expect(restored?.name, preset.name);
  });

  for (final originallyEnabled in [true, false]) {
    test(
      'native dependency OFF survives ordinary editor save and restores $originallyEnabled',
      () async {
        final preset = StudioPreset(
          id: 'dependency-$originallyEnabled',
          name: 'Dependency restoration',
          agentEnabled: {
            'continuity': originallyEnabled,
            'ledger': true,
            'final': true,
          },
          agents: const [
            StudioAgent(id: 'continuity', controllerId: 'continuity'),
            StudioAgent(id: 'ledger', controllerId: 'ledger'),
            StudioAgent(id: 'final', controllerId: 'final'),
          ],
          blocks: const [
            StudioPresetBlock(id: 'final_main_prompt', section: 'final'),
          ],
        );
        await repo.upsert(preset);
        final before = (await repo.controlObserve(preset.id))!;
        final disabled = applyStudioAgentToggle(before, 'ledger', false);
        expect(
          await repo.controlAgentToggle(
            expected: before,
            toggled: disabled,
            timestamp: 2,
            current: () => true,
          ),
          true,
        );
        final editor = (await repo.getById(preset.id))!;
        expect(editor.agentEnabled['continuity'], false);
        expect(editor.agentEnabledBeforeDependencyOff, {
          'continuity': originallyEnabled,
        });
        await repo.upsert(
          editor.copyWith(
            name: 'Ordinary editor rename',
            runtime: editor.runtime.copyWith(
              broadcastBlocks: ['Unrelated setting'],
            ),
          ),
        );
        final reopened = (await StudioPresetRepo(db).getById(preset.id))!;
        expect(reopened.agentEnabledBeforeDependencyOff, {
          'continuity': originallyEnabled,
        });
        expect(reopened.agents, editor.agents);
        expect(reopened.blocks, editor.blocks);
        expect(reopened.runtime.broadcastBlocks, ['Unrelated setting']);
        expect(await repo.controlObserve(preset.id), reopened);
        await repo.upsert(applyStudioAgentToggle(reopened, 'ledger', true));
        final enabled = (await repo.getById(preset.id))!;
        expect(enabled.agentEnabled['continuity'], originallyEnabled);
        expect(enabled.agentEnabledBeforeDependencyOff, isEmpty);
        expect(enabled.agentEnabled['final'], true);
        expect(enabled.runtime.broadcastBlocks, ['Unrelated setting']);
      },
    );
  }

  test(
    'refuses to overwrite a Main Writer with a partial agent list',
    () async {
      const original = StudioPreset(
        id: 'think-preset',
        agents: [
          StudioAgent(id: 'final', controllerId: 'final'),
          StudioAgent(id: 'think', controllerId: 'think'),
        ],
      );
      await repo.upsert(original);

      await expectLater(
        repo.upsert(original.copyWith(agents: [original.agents.last])),
        throwsStateError,
      );
      expect((await repo.getById(original.id))?.agents, original.agents);
      await expectLater(
        repo.upsert(
          const StudioPreset(
            id: 'new-think-preset',
            agents: [StudioAgent(id: 'think', controllerId: 'think')],
          ),
        ),
        throwsStateError,
      );

      await repo.upsert(
        const StudioPreset(
          id: 'think-preset',
          name: 'Renamed without editing controllers',
        ),
      );
      final renamed = await repo.getById(original.id);
      expect(renamed?.name, 'Renamed without editing controllers');
      expect(renamed?.agents, original.agents);
    },
  );

  test('round-trips blocks in final, cleaner, and ledger sections', () async {
    const preset = StudioPreset(
      id: 'pipeline-sections',
      name: 'Pipeline sections',
      agents: [],
      blocks: [
        StudioPresetBlock(
          id: 'final_main_prompt',
          section: '',
          injectionPoint: 'final',
        ),
        StudioPresetBlock(
          id: 'cleaner_system',
          section: '',
          injectionPoint: 'cleaner',
        ),
        StudioPresetBlock(
          id: 'ledger_system',
          section: '',
          injectionPoint: 'ledger',
        ),
        StudioPresetBlock(
          id: 'ledger_reconciliation_prompt',
          section: '',
          injectionPoint: 'ledger',
        ),
      ],
    );

    await repo.upsert(preset);
    final restored = await repo.getById(preset.id);

    expect(restored?.blocks.map((block) => block.injectionPoint), [
      'final',
      'cleaner',
      'ledger',
      'ledger',
    ]);
  });

  test('repairs pipeline routing already corrupted in stored JSON', () async {
    await db
        .into(db.studioPresetRows)
        .insert(
          StudioPresetRowsCompanion.insert(
            presetId: 'corrupted-routing',
            name: 'Corrupted routing',
            blocksJson: Value(
              jsonEncode([
                {
                  'id': 'final_main_prompt',
                  'type': 'instruction',
                  'section': '',
                  'injectionPoint': 'pregen',
                },
                {
                  'id': 'cleaner_system',
                  'type': 'instruction',
                  'section': '',
                  'injectionPoint': 'final',
                },
                {
                  'id': 'ledger_system',
                  'type': 'instruction',
                  'section': '',
                  'injectionPoint': 'pregen',
                },
                {
                  'id': 'ledger_reconciliation_prompt',
                  'type': 'instruction',
                  'section': '',
                  'injectionPoint': 'final',
                },
                {
                  'id': 'custom',
                  'type': 'instruction',
                  'section': '',
                  'injectionPoint': 'final',
                },
              ]),
            ),
          ),
        );

    final restored = await repo.getById('corrupted-routing');

    expect(restored?.blocks.map((block) => block.injectionPoint), [
      'final',
      'cleaner',
      'ledger',
      'ledger',
      'final',
    ]);
  });

  test('reads legacy block rows and upserts canonical JSON', () async {
    await db
        .into(db.studioPresetRows)
        .insert(
          StudioPresetRowsCompanion.insert(
            presetId: 'legacy',
            name: 'Legacy',
            blocksJson: Value(
              jsonEncode([
                {
                  'id': 'continuity_task',
                  'kind': 'tracker_instruction',
                  'content': 'Track it',
                  'section': 'pregen',
                },
              ]),
            ),
          ),
        );

    final preset = await repo.getById('legacy');
    expect(preset?.blocks.single.targetAgentId, 'continuity');

    await repo.upsert(preset!);
    final row = await (db.select(
      db.studioPresetRows,
    )..where((table) => table.presetId.equals('legacy'))).getSingle();
    final block = (jsonDecode(row.blocksJson) as List).single as Map;
    expect(block['type'], 'instruction');
    expect(block.containsKey('kind'), isFalse);
  });

  test(
    'empty and malformed runtime JSON default without damaging payload',
    () async {
      for (final entry in {'empty': '{}', 'malformed': '{not-json'}.entries) {
        await db
            .into(db.studioPresetRows)
            .insert(
              StudioPresetRowsCompanion.insert(
                presetId: entry.key,
                name: entry.key,
                blocksJson: Value(
                  jsonEncode([
                    {'id': 'history', 'kind': 'chat_history'},
                  ]),
                ),
                agentsJson: Value(
                  jsonEncode([
                    {'id': 'agent_${entry.key}_continuity_1'},
                  ]),
                ),
                runtimeSettingsJson: Value(entry.value),
              ),
            );

        final restored = await repo.getById(entry.key);
        expect(restored?.runtime, const StudioRuntimeSettings());
        expect(restored?.blocks.single.type, StudioBlockType.history);
        expect(restored?.agents.single.controllerId, 'continuity');
      }
    },
  );

  test(
    'an empty blocks upsert does not erase an existing non-empty preset',
    () async {
      const preset = StudioPreset(
        id: 'guard-target',
        name: 'Guard target',
        blocks: [
          StudioPresetBlock(
            id: 'final_main_prompt',
            section: '',
            injectionPoint: 'final',
          ),
          StudioPresetBlock(
            id: 'cleaner_system',
            section: '',
            injectionPoint: 'cleaner',
          ),
        ],
      );
      await repo.upsert(preset);

      // A later save arrives with an empty block list (e.g. a corrupt decode).
      await repo.upsert(
        const StudioPreset(id: 'guard-target', name: 'Guard target'),
      );

      final restored = await repo.getById('guard-target');
      expect(restored?.blocks, hasLength(2));
      expect(restored?.blocks.map((block) => block.injectionPoint), [
        'final',
        'cleaner',
      ]);
    },
  );

  group('Ledger control header DB round trips', () {
    Map<String, Object?> header({Object? enabled = true}) => {
      'id': ledgerPromptInjectionHeaderId,
      'title': ledgerPromptInjectionHeaderTitle,
      'enabled': enabled,
      'type': 'instruction',
      'section': 'pregen',
    };

    Future<StudioPreset> roundTrip(String id, List<Object?> blocks) async {
      await db
          .into(db.studioPresetRows)
          .insert(
            StudioPresetRowsCompanion.insert(
              presetId: id,
              name: id,
              blocksJson: Value(jsonEncode(blocks)),
              runtimeSettingsJson: Value(
                jsonEncode({
                  'requestedLedgerPromptInjectionMode': 'gapFiller',
                  'requestedLedgerPromptInjectionAlgorithmVersion':
                      ledgerPromptInjectionAlgorithmVersion,
                }),
              ),
            ),
          );
      final firstRead = (await repo.getById(id))!;
      await repo.upsert(firstRead);
      return (await repo.getById(id))!;
    }

    LedgerPromptInjectionMode snapshotMode(StudioPreset preset) =>
        StudioTurnConfigSnapshot(
          config: const StudioConfig(sessionId: 'session', enabled: true),
          preset: preset,
          pipelineSettings: const PipelineSettings(),
          apiConfigs: const [],
          activeApiConfig: null,
        ).ledgerPromptInjectionPolicy.effectiveMode;

    test('enabled header and requested gap-filler version survive', () async {
      final restored = await roundTrip('enabled-header', [header()]);

      expect(restored.blocks.single.enabled, isTrue);
      expect(
        restored.runtime.requestedLedgerPromptInjectionMode,
        LedgerPromptInjectionMode.gapFiller,
      );
      expect(
        restored.runtime.requestedLedgerPromptInjectionAlgorithmVersion,
        ledgerPromptInjectionAlgorithmVersion,
      );
      expect(snapshotMode(restored), LedgerPromptInjectionMode.gapFiller);
    });

    test('exact disabled header remains authoritative', () async {
      final restored = await roundTrip('disabled-header', [
        header(enabled: false),
      ]);

      expect(restored.blocks.single.enabled, isFalse);
      expect(snapshotMode(restored), LedgerPromptInjectionMode.disabled);
    });

    test('duplicate known headers remain fail-closed', () async {
      final restored = await roundTrip('duplicate-header', [
        header(),
        header(),
      ]);

      expect(restored.blocks, hasLength(2));
      expect(snapshotMode(restored), LedgerPromptInjectionMode.disabled);
    });

    test('malformed known header is retained as disabled sentinel', () async {
      final restored = await roundTrip('malformed-header', [
        header(enabled: 'yes'),
      ]);

      expect(restored.blocks, hasLength(1));
      expect(restored.blocks.single.id, ledgerPromptInjectionHeaderId);
      expect(restored.blocks.single.title, ledgerPromptInjectionHeaderTitle);
      expect(restored.blocks.single.enabled, isFalse);
      expect(snapshotMode(restored), LedgerPromptInjectionMode.disabled);
    });

    test('absent known header preserves legacy behavior', () async {
      final restored = await roundTrip('absent-header', [
        {'id': 'ordinary', 'title': 'Ordinary', 'type': 'instruction'},
      ]);

      expect(snapshotMode(restored), LedgerPromptInjectionMode.legacy);
    });
  });
}
