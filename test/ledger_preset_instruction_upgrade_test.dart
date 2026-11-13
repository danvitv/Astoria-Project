import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/ledger_preset_instruction_defaults.dart';
import 'package:glaze_flutter/core/models/ledger_preset_instruction_upgrade.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/studio_preset_codec.dart';
import 'package:glaze_flutter/core/models/studio_preset_block_groups.dart';

StudioPresetBlock primary(String id, {String content = 'custom\r\n policy '}) =>
    StudioPresetBlock(
      id: id,
      title: 'My unchanged title',
      content: content,
      enabled: false,
      locked: true,
      order: -7,
      section: '',
      injectionPoint: 'final',
      role: 'user',
      mode: 'custom-mode',
      targetAgentId: 'custom-agent',
      sourceAgentId: 'source',
      insertionMode: 'depth',
      depth: 3,
      appendToLastMessage: true,
    );

void main() {
  test('planning is pure and preserves every authored block field', () {
    final original = StudioPreset(
      id: 'custom',
      name: 'Custom',
      blocks: [
        primary('ledger_system'),
        primary('ledger_reconciliation_prompt'),
        const StudioPresetBlock(id: 'unrelated', content: 'keep', order: 42),
      ],
      agents: const [StudioAgent(id: 'my-agent', role: 'my role')],
      ledgerApiConfigId: 'ledger-api',
      expensiveApiConfigId: 'expensive-api',
      cheapApiConfigId: 'cheap-api',
      cleanerApiConfigId: 'cleaner-api',
      maxFinalHistoryMessages: 91,
      agentEnabled: const {'ledger': false},
      agentBlockRestoreState: const {
        'a': ['b'],
      },
      agentEnabledBeforeDependencyOff: const {'a': true},
      controllerAlternativeBlockIds: const {
        'a': ['c'],
      },
      runtime: const StudioRuntimeSettings(
        reasoningTagStart: '<think>',
        reasoningTagEnd: '</think>',
        broadcastBlocks: ['unrelated'],
      ),
      updatedAt: 123,
    );
    final before = jsonEncode(original.toJson());
    final plan = planLedgerPresetInstructionUpgrade(original);
    expect(jsonEncode(original.toJson()), before);
    expect(plan.additions.map((block) => block.id), [
      'ledger_consolidated_policy_header',
      'ledger_shared_policy',
      'ledger_turn_policy',
      'ledger_reconciliation_policy',
      'ledger_output_repair',
      'ledger_cleanup_repair',
    ]);
    for (var i = 0; i < original.blocks.length; i++) {
      expect(identical(plan.upgraded.blocks[i], original.blocks[i]), isTrue);
      expect(plan.upgraded.blocks[i].toJson(), original.blocks[i].toJson());
    }
    final withoutUpgrade = plan.upgraded.copyWith(
      blocks: original.blocks,
      runtime: plan.upgraded.runtime.copyWith(ledgerInstructionRevision: 0),
    );
    expect(jsonEncode(withoutUpgrade.toJson()), before);
    expect(
      plan.warnings.any((warning) => warning.contains('disabled')),
      isTrue,
    );
    expect(plan.warnings.any((warning) => warning.contains('routing')), isTrue);
    expect(plan.additions.every((block) => block.order > 42), isTrue);
    expect(plan.upgraded.runtime.ledgerInstructionRevision, 1);
  });

  test(
    'missing base prompts appear as explicit editable preview additions',
    () {
      const preset = StudioPreset(id: 'empty');
      final plan = planLedgerPresetInstructionUpgrade(preset);
      final additions = {for (final block in plan.additions) block.id: block};
      expect(
        additions['ledger_system']!.content,
        ledgerDefaultTurnInstructions,
      );
      expect(
        additions['ledger_reconciliation_prompt']!.content,
        ledgerDefaultReconciliationInstructions,
      );
      expect(
        additions['ledger_shared_policy']!.content,
        ledgerDefaultSharedInstructions,
      );
      expect(additions.containsKey('ledger_turn_policy'), isFalse);
      expect(
        additions['ledger_output_repair']!.content,
        ledgerDefaultRepairInstructions,
      );
      expect(
        additions['ledger_cleanup_repair']!.content,
        ledgerDefaultCleanupRepairInstructions,
      );
      expect(additions, hasLength(6));
      expect(
        plan.warnings.where((value) => value.contains('missing')),
        hasLength(2),
      );
      expect(preset.blocks, isEmpty);
      for (final block in plan.additions) {
        expect(block.enabled, isTrue);
        expect(block.locked, isFalse);
        expect(block.type, StudioBlockType.instruction);
        expect(block.injectionPoint, 'ledger');
        expect(block.section, '');
        expect(block.mode, 'direct');
      }
    },
  );

  test('custom reconciliation receives a separate transferred wrapper', () {
    final original = StudioPreset(
      id: 'custom',
      blocks: [primary('ledger_reconciliation_prompt')],
    );
    final plan = planLedgerPresetInstructionUpgrade(original);
    expect(plan.upgraded.blocks.first, original.blocks.first);
    expect(
      plan.additions
          .singleWhere((b) => b.id == 'ledger_reconciliation_policy')
          .content,
      ledgerTransferredReconciliationInstructions,
    );
    final defaultPlan = planLedgerPresetInstructionUpgrade(
      StudioPreset(
        id: 'default-content',
        blocks: [
          primary(
            'ledger_reconciliation_prompt',
            content: ledgerDefaultReconciliationInstructions,
          ),
        ],
      ),
    );
    expect(
      defaultPlan.additions.any((b) => b.id == 'ledger_reconciliation_policy'),
      isFalse,
    );
  });

  test(
    'custom turn receives transfer once; complete default avoids duplicate',
    () {
      final custom = planLedgerPresetInstructionUpgrade(
        StudioPreset(id: 'turn', blocks: [primary('ledger_system')]),
      );
      expect(
        custom.additions
            .singleWhere((b) => b.id == 'ledger_turn_policy')
            .content,
        ledgerTransferredTurnInstructions,
      );
      final complete = planLedgerPresetInstructionUpgrade(
        StudioPreset(
          id: 'complete',
          blocks: [
            primary('ledger_system', content: ledgerDefaultTurnInstructions),
          ],
        ),
      );
      expect(
        complete.additions.any((b) => b.id == 'ledger_turn_policy'),
        isFalse,
      );
    },
  );

  test('repeated planning of compatible additions appends no duplicates', () {
    final first = planLedgerPresetInstructionUpgrade(
      const StudioPreset(id: 'compatible'),
    );
    final withoutMarker = first.upgraded.copyWith(
      runtime: const StudioRuntimeSettings(),
    );
    final second = planLedgerPresetInstructionUpgrade(withoutMarker);
    expect(second.additions, isEmpty);
    expect(second.upgraded.runtime.ledgerInstructionRevision, 1);
    expect(second.upgraded.blocks, first.upgraded.blocks);
  });

  test('disabled compatible policy is preserved rather than enabled', () {
    final block = primary(
      'ledger_shared_policy',
      content: ledgerDefaultSharedInstructions,
    );
    final plan = planLedgerPresetInstructionUpgrade(
      StudioPreset(id: 'disabled', blocks: [block]),
    );
    expect(plan.upgraded.blocks.first, block);
    expect(plan.additions.any((b) => b.id == block.id), isFalse);
    expect(plan.warnings.any((value) => value.contains('disabled')), isTrue);
  });

  test('reserved policy collision fails without changing input', () {
    for (final id in [
      'ledger_consolidated_policy_header',
      'ledger_shared_policy',
      'ledger_turn_policy',
      'ledger_reconciliation_policy',
      'ledger_output_repair',
      'ledger_cleanup_repair',
    ]) {
      final preset = StudioPreset(id: 'collision', blocks: [primary(id)]);
      final before = jsonEncode(preset.toJson());
      expect(
        () => planLedgerPresetInstructionUpgrade(preset),
        throwsStateError,
      );
      expect(jsonEncode(preset.toJson()), before);
    }
  });

  test('new policies do not inherit trailing disabled folder', () {
    const preset = StudioPreset(
      id: 'folder',
      blocks: [
        StudioPresetBlock(
          id: 'custom_folder',
          title: '━ Disabled',
          section: '',
          injectionPoint: 'ledger',
          enabled: false,
        ),
      ],
    );
    final plan = planLedgerPresetInstructionUpgrade(preset);
    final enabled = resolveEnabledStudioPresetBlocks(
      plan.upgraded.blocks,
    ).map((block) => block.id).toSet();
    expect(enabled, contains('ledger_system'));
    expect(enabled, contains('ledger_shared_policy'));
    expect(preset.blocks.single.enabled, isFalse);
  });

  test(
    'duplicate reserved IDs fail rather than picking an arbitrary block',
    () {
      final preset = StudioPreset(
        id: 'duplicate',
        blocks: [primary('ledger_system'), primary('ledger_system')],
      );
      expect(
        () => planLedgerPresetInstructionUpgrade(preset),
        throwsStateError,
      );
    },
  );

  test('revision marker prevents deleted blocks from regrowing forever', () {
    for (final revision in [1, 2, 19]) {
      final preset = StudioPreset(
        id: 'deleted',
        runtime: StudioRuntimeSettings(ledgerInstructionRevision: revision),
      );
      final plan = planLedgerPresetInstructionUpgrade(preset);
      expect(plan.needsUpgrade, isFalse);
      expect(plan.additions, isEmpty);
      expect(identical(plan.upgraded, preset), isTrue);
    }
  });

  test('fingerprint is stable but covers full preset state', () {
    const original = StudioPreset(id: 'fingerprint');
    final fingerprint = ledgerPresetInstructionFingerprint(original);
    expect(fingerprint, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(
      ledgerPresetInstructionFingerprint(original.copyWith()),
      fingerprint,
    );
    for (final changed in [
      original.copyWith(name: 'renamed'),
      original.copyWith(updatedAt: 1),
      original.copyWith(blocks: [primary('ledger_system')]),
      original.copyWith(agents: const [StudioAgent(id: 'agent')]),
      original.copyWith(cheapApiConfigId: 'api'),
      original.copyWith(ledgerApiConfigId: 'api'),
      original.copyWith(maxFinalHistoryMessages: 12),
      original.copyWith(agentEnabled: const {'a': false}),
      original.copyWith(
        agentBlockRestoreState: const {
          'a': ['b'],
        },
      ),
      original.copyWith(
        runtime: const StudioRuntimeSettings(reasoningTagEnd: 'end'),
      ),
      original.copyWith(
        runtime: const StudioRuntimeSettings(ledgerInstructionRevision: 1),
      ),
    ]) {
      expect(ledgerPresetInstructionFingerprint(changed), isNot(fingerprint));
    }
    expect(
      ledgerPresetInstructionFingerprint(
        original.copyWith(agentEnabled: const {'a': true, 'b': false}),
      ),
      ledgerPresetInstructionFingerprint(
        original.copyWith(agentEnabled: const {'b': false, 'a': true}),
      ),
    );
  });

  test('codec round-trips revision and malformed marker preserves runtime', () {
    for (final revision in [0, 1, 12]) {
      final runtime = StudioRuntimeSettings(
        ledgerInstructionRevision: revision,
      );
      final decoded = StudioPresetCodec.decodePreset({
        'id': 'codec',
        'runtime': StudioPresetCodec.encodeRuntime(runtime),
      }).preset.runtime;
      expect(decoded.ledgerInstructionRevision, revision);
    }
    final legacy = StudioPresetCodec.decodePreset({'id': 'legacy'}).preset;
    expect(legacy.runtime.ledgerInstructionRevision, 0);
    final malformed = StudioPresetCodec.decodePreset({
      'id': 'malformed',
      'runtime': {
        'ledgerInstructionRevision': '1',
        'reasoningTagStart': 'preserve this',
      },
    }).preset.runtime;
    expect(malformed.ledgerInstructionRevision, 0);
    expect(malformed.reasoningTagStart, 'preserve this');
  });
}
