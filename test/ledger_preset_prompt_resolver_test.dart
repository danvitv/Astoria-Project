import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/llm/ledger/ledger_preset_prompt_resolver.dart';
import 'package:glaze_flutter/core/llm/macro_engine.dart';
import 'package:glaze_flutter/core/models/ledger_preset_instruction_defaults.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

typedef _ResolvePrompt =
    String Function({
      required List<StudioPresetBlock> blocks,
      MacroContext? macroCtx,
    });

StudioPresetBlock _block(String id, String content, {int order = 0}) =>
    StudioPresetBlock(
      id: id,
      section: 'ledger',
      injectionPoint: 'ledger',
      content: content,
      order: order,
    );

void main() {
  const resolver = LedgerPresetPromptResolver();
  final phases = <String, _ResolvePrompt>{
    'ledger_system': resolver.resolveTurn,
    'ledger_reconciliation_prompt': resolver.resolveReconciliation,
    'ledger_output_repair': resolver.resolveOutputRepair,
    'ledger_cleanup_repair': resolver.resolveCleanupRepair,
  };

  group('Explicit primary instruction authority', () {
    for (final phase in phases.entries) {
      final id = phase.key;
      final resolve = phase.value;

      test('$id permits macro-free custom policy without MacroContext', () {
        final blocks = [_block(id, 'CUSTOM_$id')];
        expect(resolve(blocks: blocks), 'CUSTOM_$id');
      });

      test('$id never falls back when missing or unusable', () {
        final primary = _block(id, 'PRIMARY_SENTINEL');
        for (final blocks in <List<StudioPresetBlock>>[
          [],
          [_block('not_$id', 'WRONG_ID_SENTINEL')],
          [primary.copyWith(enabled: false)],
          [primary.copyWith(content: ' \n ')],
          [primary.copyWith(injectionPoint: 'cleaner')],
          [primary.copyWith(type: StudioBlockType.context)],
          [primary.copyWith(mode: 'pregenBrief')],
          [primary.copyWith(targetAgentId: 'other-agent')],
          [primary.copyWith(appendToLastMessage: true)],
          [primary.copyWith(section: 'cleaner')],
          [primary.copyWith(groupBoundary: 'open')],
          [primary, primary.copyWith(content: 'DUPLICATE_SENTINEL')],
        ]) {
          expect(() => resolve(blocks: blocks), throwsStateError);
        }
      });

      test('$id rejects misrouted effective supplementary policy', () {
        if (id != 'ledger_system' && id != 'ledger_reconciliation_prompt') {
          return;
        }
        for (final supplement in [
          _block('ledger_shared_policy', 'SHARED').copyWith(mode: 'custom'),
          _block(
            'ledger_shared_policy',
            'SHARED',
          ).copyWith(targetAgentId: 'think'),
          _block(
            'ledger_shared_policy',
            'SHARED',
          ).copyWith(appendToLastMessage: true),
        ]) {
          expect(
            () => resolve(blocks: [_block(id, 'PRIMARY'), supplement]),
            throwsStateError,
          );
        }
      });

      test('$id resolves standard macros without changing stored content', () {
        final blocks = [_block(id, '{{char}} / {{user}} / POLICY_$id')];
        final before = jsonEncode(blocks.map((b) => b.toJson()).toList());
        final prompt = resolve(
          blocks: blocks,
          macroCtx: const MacroContext(
            charName: 'Alice',
            userName: 'Danvi',
            charId: 'alice',
            sessionId: 'synthetic-session',
          ),
        );
        expect(prompt, 'Alice / Danvi / POLICY_$id');
        expect(jsonEncode(blocks.map((b) => b.toJson()).toList()), before);
      });

      test('$id rejects instructions emptied by macro expansion', () {
        expect(
          () => resolve(
            blocks: [_block(id, '{{getvar::missing_policy}}')],
            macroCtx: const MacroContext(
              charName: 'Alice',
              charId: 'alice',
              sessionId: 'synthetic-session',
            ),
          ),
          throwsStateError,
        );
      });

      test('$id respects disabled folders before routing or ID filtering', () {
        final header = _block('folder', '', order: 0).copyWith(
          title: '━ Ledger policies',
          enabled: false,
          injectionPoint: 'pregen',
          section: 'pregen',
        );
        final primary = _block(id, 'GROUPED_PRIMARY', order: 1);
        expect(primary.enabled, isTrue);
        expect(() => resolve(blocks: [header, primary]), throwsStateError);
        expect(
          resolve(blocks: [header.copyWith(enabled: true), primary]),
          'GROUPED_PRIMARY',
        );
      });
    }
  });

  group('Phase separation and supplementary policy', () {
    final blocks = [
      _block('ledger_system', 'TURN_ONLY', order: 10),
      _block('ledger_shared_policy', 'SHARED_POLICY', order: 20),
      _block('ledger_turn_policy', 'TURN_SUPPLEMENT', order: 30),
      _block('ledger_reconciliation_prompt', 'RECON_ONLY', order: 40),
      _block('ledger_reconciliation_policy', 'RECON_SUPPLEMENT', order: 50),
      _block('ledger_output_repair', 'OUTPUT_REPAIR_ONLY', order: 60),
      _block('ledger_cleanup_repair', 'CLEANUP_REPAIR_ONLY', order: 70),
      _block('unrelated_custom_block', 'DO_NOT_INJECT', order: 80),
    ];

    test('duplicate supplementary policy is rejected before assembly', () {
      final duplicate = [...blocks, _block('ledger_shared_policy', 'OTHER')];
      expect(() => resolver.resolveTurn(blocks: duplicate), throwsStateError);
      expect(
        () => resolver.resolveReconciliation(blocks: duplicate),
        throwsStateError,
      );
    });

    test(
      'turn and reconciliation include only their own policy plus shared',
      () {
        expect(
          resolver.resolveTurn(blocks: blocks),
          'TURN_ONLY\n\nSHARED_POLICY\n\nTURN_SUPPLEMENT',
        );
        expect(
          resolver.resolveReconciliation(blocks: blocks),
          'SHARED_POLICY\n\nRECON_ONLY\n\nRECON_SUPPLEMENT',
        );
      },
    );

    test('repair phases do not inherit extraction or shared instructions', () {
      expect(
        resolver.resolveOutputRepair(blocks: blocks),
        'OUTPUT_REPAIR_ONLY',
      );
      expect(
        resolver.resolveCleanupRepair(blocks: blocks),
        'CLEANUP_REPAIR_ONLY',
      );
    });

    test(
      'stored order is deterministic even when the input list is reversed',
      () {
        expect(
          resolver.resolveTurn(blocks: blocks.reversed.toList()),
          resolver.resolveTurn(blocks: blocks),
        );
        expect(
          resolver.resolveReconciliation(blocks: blocks.reversed.toList()),
          resolver.resolveReconciliation(blocks: blocks),
        );
      },
    );

    test('editing primary or shared content changes only supplied policy', () {
      final edited = blocks.map((block) {
        if (block.id == 'ledger_system') {
          return block.copyWith(content: 'EDITED_TURN');
        }
        if (block.id == 'ledger_shared_policy') {
          return block.copyWith(content: 'EDITED_SHARED');
        }
        return block;
      }).toList();
      expect(
        resolver.resolveTurn(blocks: edited),
        'EDITED_TURN\n\nEDITED_SHARED\n\nTURN_SUPPLEMENT',
      );
      expect(
        resolver.resolveReconciliation(blocks: edited),
        'EDITED_SHARED\n\nRECON_ONLY\n\nRECON_SUPPLEMENT',
      );
    });

    test('removed or disabled supplements are not silently restored', () {
      const supplementaryIds = {
        'ledger_shared_policy',
        'ledger_turn_policy',
        'ledger_reconciliation_policy',
      };
      final removed = blocks
          .where((block) => !supplementaryIds.contains(block.id))
          .toList();
      final disabled = blocks
          .map(
            (block) => supplementaryIds.contains(block.id)
                ? block.copyWith(enabled: false)
                : block,
          )
          .toList();
      for (final input in [removed, disabled]) {
        expect(resolver.resolveTurn(blocks: input), 'TURN_ONLY');
        expect(resolver.resolveReconciliation(blocks: input), 'RECON_ONLY');
      }
    });

    test('a disabled shared-policy folder cannot be bypassed by exact ID', () {
      final grouped = [
        _block('ledger_system', 'TURN', order: 0),
        _block('policy_folder', '', order: 1).copyWith(
          title: '━ Shared policy',
          enabled: false,
          injectionPoint: 'cleaner',
        ),
        _block('ledger_shared_policy', 'HIDDEN_SHARED', order: 2),
        _block(
          'policy_folder_group_close',
          '',
          order: 3,
        ).copyWith(groupBoundary: 'close'),
        _block('ledger_reconciliation_prompt', 'RECON', order: 4),
      ];
      expect(resolver.resolveTurn(blocks: grouped), 'TURN');
      expect(resolver.resolveReconciliation(blocks: grouped), 'RECON');
    });

    test(
      'enabled but misrouted supplement is an error, not hidden fallback',
      () {
        final misrouted = blocks
            .map(
              (block) => block.id == 'ledger_shared_policy'
                  ? block.copyWith(injectionPoint: 'cleaner')
                  : block,
            )
            .toList();
        expect(() => resolver.resolveTurn(blocks: misrouted), throwsStateError);
        expect(
          () => resolver.resolveReconciliation(blocks: misrouted),
          throwsStateError,
        );
        expect(
          resolver.resolveOutputRepair(blocks: misrouted),
          'OUTPUT_REPAIR_ONLY',
        );
      },
    );
  });

  test('default seed materializes all editable Ledger instruction phases', () {
    final blocks = defaultStudioPresetSeedBlocks()
        .map(StudioPresetBlock.fromJson)
        .toList();
    final expectedContent = {
      'ledger_system': ledgerDefaultTurnInstructions,
      'ledger_shared_policy': ledgerDefaultSharedInstructions,
      'ledger_reconciliation_prompt': ledgerDefaultReconciliationInstructions,
      'ledger_output_repair': ledgerDefaultRepairInstructions,
      'ledger_cleanup_repair': ledgerDefaultCleanupRepairInstructions,
    };
    for (final entry in expectedContent.entries) {
      final block = blocks.singleWhere((block) => block.id == entry.key);
      expect(block.enabled, isTrue);
      expect(block.type, StudioBlockType.instruction);
      expect(block.injectionPoint, 'ledger');
      expect(block.content, entry.value);
    }
    expect(
      resolver.resolveTurn(blocks: blocks),
      allOf(
        contains(ledgerDefaultTurnInstructions),
        contains(ledgerDefaultSharedInstructions),
      ),
    );
    expect(
      resolver.resolveReconciliation(blocks: blocks),
      allOf(
        contains(ledgerDefaultReconciliationInstructions),
        contains(ledgerDefaultSharedInstructions),
      ),
    );
    expect(
      resolver.resolveOutputRepair(blocks: blocks),
      ledgerDefaultRepairInstructions,
    );
    expect(
      resolver.resolveCleanupRepair(blocks: blocks),
      ledgerDefaultCleanupRepairInstructions,
    );
  });
}
