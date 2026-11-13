import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'ledger_preset_instruction_defaults.dart';
import 'ledger_preset_instruction_routing.dart';
import 'studio_config.dart';
import 'studio_preset_block_groups.dart';

const ledgerInstructionRevision = 1;

/// An immutable preview only. Planning never writes a preset or changes input.
final class LedgerPresetInstructionUpgradePlan {
  final StudioPreset original;
  final List<StudioPresetBlock> additions;
  final List<String> warnings;
  final String expectedFingerprint;

  LedgerPresetInstructionUpgradePlan({
    required this.original,
    required List<StudioPresetBlock> additions,
    required List<String> warnings,
    String? expectedFingerprint,
  }) : additions = List.unmodifiable(additions),
       warnings = List.unmodifiable(warnings),
       expectedFingerprint =
           expectedFingerprint ?? ledgerPresetInstructionFingerprint(original);

  bool get needsUpgrade =>
      original.runtime.ledgerInstructionRevision < ledgerInstructionRevision;

  StudioPreset get upgraded => !needsUpgrade
      ? original
      : original.copyWith(
          blocks: [...original.blocks, ...additions],
          runtime: original.runtime.copyWith(
            ledgerInstructionRevision: ledgerInstructionRevision,
          ),
        );
}

/// Stable SHA-256 over the full typed preset, including all routing, settings,
/// agents and timestamps. Map insertion order is not a semantic difference.
String ledgerPresetInstructionFingerprint(StudioPreset preset) {
  return ledgerPresetInstructionSourceFingerprint(preset.toJson());
}

/// A repository preview fingerprints the complete raw row, not a lossy typed
/// codec projection. Unknown fields and concurrent raw edits also invalidate it.
String ledgerPresetInstructionSourceFingerprint(Object? source) => sha256
    .convert(
      utf8.encode(jsonEncode(_sortedJson(jsonDecode(jsonEncode(source))))),
    )
    .toString();

Object? _sortedJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _sortedJson(value[key])};
  }
  if (value is List) return value.map(_sortedJson).toList();
  return value;
}

/// Adds visible editable policies without rewriting any authored block.
/// Applying [LedgerPresetInstructionUpgradePlan.upgraded] requires explicit
/// confirmation, including confirmation of missing base prompt creation.
LedgerPresetInstructionUpgradePlan planLedgerPresetInstructionUpgrade(
  StudioPreset preset,
) {
  if (preset.runtime.ledgerInstructionRevision >= ledgerInstructionRevision) {
    return LedgerPresetInstructionUpgradePlan(
      original: preset,
      additions: const [],
      warnings: const [],
    );
  }
  const reservedIds = {
    'ledger_consolidated_policy_header',
    'ledger_system',
    'ledger_reconciliation_prompt',
    'ledger_shared_policy',
    'ledger_turn_policy',
    'ledger_reconciliation_policy',
    'ledger_output_repair',
    'ledger_cleanup_repair',
  };
  final existing = <String, StudioPresetBlock>{};
  for (final block in preset.blocks) {
    if (!reservedIds.contains(block.id)) continue;
    if (existing.containsKey(block.id)) {
      throw StateError('Duplicate reserved Ledger block ID: ${block.id}.');
    }
    existing[block.id] = block;
  }
  final additions = <StudioPresetBlock>[];
  final warnings = <String>[];
  var nextOrder = preset.blocks.fold<int>(
    -1,
    (maximum, block) => block.order > maximum ? block.order : maximum,
  );
  final enabledIds = resolveEnabledStudioPresetBlocks(
    preset.blocks,
  ).map((block) => block.id).toSet();

  void warnIfInactive(StudioPresetBlock block) {
    if (!block.enabled) {
      warnings.add('${block.id} is disabled and will remain disabled.');
    }
    if (block.enabled && !enabledIds.contains(block.id)) {
      warnings.add(
        '${block.id} is disabled by its folder and will stay inactive.',
      );
    }
    if (block.content.trim().isEmpty) {
      warnings.add('${block.id} is blank and will remain blank.');
    }
    if (!isLedgerPresetInstruction(block)) {
      warnings.add(
        '${block.id} has non-canonical routing. It will not be repaired by '
        'this upgrade; review its Ledger routing before running the phase.',
      );
    }
  }

  void install(
    String id,
    String title,
    String content, {
    bool preserveCustom = false,
  }) {
    final block = existing[id];
    if (block != null) {
      if (!preserveCustom && block.content != content) {
        throw StateError(
          'Reserved Ledger block ID "$id" contains different content. '
          'Rename that block before upgrading; nothing was changed.',
        );
      }
      warnIfInactive(block);
      if (preserveCustom && block.content != content) {
        warnings.add(
          '$id keeps its custom text. Review it for conflicts with '
          'the newly visible transferred rules; no semantic merge is performed.',
        );
      }
      return;
    }
    additions.add(
      StudioPresetBlock(
        id: id,
        title: title,
        content: content,
        section: '',
        injectionPoint: 'ledger',
        order: ++nextOrder,
      ),
    );
    if (preserveCustom) {
      warnings.add(
        '$id is missing. Confirmation creates an editable default prompt.',
      );
    }
  }

  install(
    'ledger_system',
    'Ledger turn instructions',
    ledgerDefaultTurnInstructions,
    preserveCustom: true,
  );
  install(
    'ledger_reconciliation_prompt',
    'Ledger reconciliation instructions',
    ledgerDefaultReconciliationInstructions,
    preserveCustom: true,
  );
  install(
    'ledger_shared_policy',
    'Ledger shared policy',
    ledgerDefaultSharedInstructions,
  );
  // Complete new defaults already contain the transferred turn semantics.
  // Existing custom primaries receive them in a separate editable block.
  final turn = existing['ledger_system'];
  if ((turn != null && turn.content != ledgerDefaultTurnInstructions) ||
      existing.containsKey('ledger_turn_policy')) {
    install(
      'ledger_turn_policy',
      'Ledger transferred turn policy',
      ledgerTransferredTurnInstructions,
    );
  }
  // New default reconciliation instructions already contain the wrapper.
  // A custom primary prompt is kept byte-for-byte and gets a separate policy.
  final reconciliation = existing['ledger_reconciliation_prompt'];
  if ((reconciliation != null &&
          reconciliation.content != ledgerDefaultReconciliationInstructions) ||
      existing.containsKey('ledger_reconciliation_policy')) {
    install(
      'ledger_reconciliation_policy',
      'Ledger transferred reconciliation policy',
      ledgerTransferredReconciliationInstructions,
    );
  }
  install(
    'ledger_output_repair',
    'Ledger output repair instructions',
    ledgerDefaultRepairInstructions,
  );
  install(
    'ledger_cleanup_repair',
    'Ledger knowledge cleanup repair instructions',
    ledgerDefaultCleanupRepairInstructions,
  );
  if (additions.isNotEmpty) {
    // A trailing authored folder may be disabled or have boundary content.
    // Start an explicit new editable group instead of inheriting its policy.
    if (existing.containsKey('ledger_consolidated_policy_header')) {
      throw StateError('Reserved Ledger consolidation folder already exists.');
    }
    final start = additions.first.order;
    for (var index = 0; index < additions.length; index++) {
      additions[index] = additions[index].copyWith(order: start + index + 1);
    }
    additions.insert(
      0,
      StudioPresetBlock(
        id: 'ledger_consolidated_policy_header',
        title: '━ Ledger consolidated policies',
        content: '',
        section: '',
        injectionPoint: 'ledger',
        order: start,
      ),
    );
  }
  return LedgerPresetInstructionUpgradePlan(
    original: preset,
    additions: additions,
    warnings: warnings,
  );
}
