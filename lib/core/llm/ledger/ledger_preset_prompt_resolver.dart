import '../../models/studio_config.dart';
import '../../models/ledger_preset_instruction_routing.dart';
import '../../models/studio_preset_block_groups.dart';
import '../macro_engine.dart';

/// Resolves authored Ledger policy without a runtime default or preset writes.
class LedgerPresetPromptResolver {
  const LedgerPresetPromptResolver();

  static const turnBlockId = 'ledger_system';
  static const reconciliationBlockId = 'ledger_reconciliation_prompt';
  static const sharedPolicyBlockId = 'ledger_shared_policy';
  static const turnPolicyBlockId = 'ledger_turn_policy';
  static const reconciliationPolicyBlockId = 'ledger_reconciliation_policy';
  static const outputRepairBlockId = 'ledger_output_repair';
  static const cleanupRepairBlockId = 'ledger_cleanup_repair';

  String resolveTurn({
    required List<StudioPresetBlock> blocks,
    MacroContext? macroCtx,
  }) => resolve(
    blocks: blocks,
    primaryBlockId: turnBlockId,
    allowedBlockIds: {turnBlockId, sharedPolicyBlockId, turnPolicyBlockId},
    macroCtx: macroCtx,
  );

  String resolveReconciliation({
    required List<StudioPresetBlock> blocks,
    MacroContext? macroCtx,
  }) => resolve(
    blocks: blocks,
    primaryBlockId: reconciliationBlockId,
    allowedBlockIds: {
      reconciliationBlockId,
      sharedPolicyBlockId,
      reconciliationPolicyBlockId,
    },
    macroCtx: macroCtx,
  );

  String resolveOutputRepair({
    required List<StudioPresetBlock> blocks,
    MacroContext? macroCtx,
  }) => resolve(
    blocks: blocks,
    primaryBlockId: outputRepairBlockId,
    allowedBlockIds: {outputRepairBlockId},
    macroCtx: macroCtx,
  );

  String resolveCleanupRepair({
    required List<StudioPresetBlock> blocks,
    MacroContext? macroCtx,
  }) => resolve(
    blocks: blocks,
    primaryBlockId: cleanupRepairBlockId,
    allowedBlockIds: {cleanupRepairBlockId},
    macroCtx: macroCtx,
  );

  String resolve({
    required List<StudioPresetBlock> blocks,
    required String primaryBlockId,
    required Set<String> allowedBlockIds,
    MacroContext? macroCtx,
  }) {
    final primaryId = primaryBlockId;
    if (!allowedBlockIds.contains(primaryId)) {
      throw ArgumentError('The primary Ledger block must be allowed.');
    }
    for (final id in allowedBlockIds) {
      if (blocks.where((block) => block.id == id).length > 1) {
        throw StateError('Duplicate Ledger instruction block "$id".');
      }
    }
    final primary = blocks.where((block) => block.id == primaryId).toList();
    if (primary.length != 1) {
      throw StateError(
        'Studio Ledger preset requires exactly one "$primaryId" instruction '
        'block; found ${primary.length}. Edit the active Studio preset.',
      );
    }
    _validateInstruction(primary.single);
    _validateContent(primary.single);

    // Resolve folders before selecting policy IDs, or disabling a folder would
    // silently leave its Ledger instruction active. Preserve the entire stored
    // sequence here, including structural rows, before phase/routing filters.
    final effective = resolveEnabledStudioPresetBlocks(blocks);
    if (!effective.any((block) => block.id == primaryId)) {
      throw StateError(
        'Studio Ledger preset instruction "$primaryId" is disabled '
        '(possibly by its group). Enable it in the active Studio preset.',
      );
    }

    final parts = <String>[];
    for (final block in effective.where(
      (block) => allowedBlockIds.contains(block.id),
    )) {
      _validateInstruction(block);
      _validateContent(block);
      final content = macroCtx == null
          ? block.content
          : replaceMacros(block.content, macroCtx).text;
      if (content.trim().isEmpty) {
        throw StateError(
          'Studio Ledger preset instruction "${block.id}" is blank after '
          'macro expansion. Edit the active Studio preset.',
        );
      }
      parts.add(content);
    }
    return parts.join('\n\n');
  }

  void _validateContent(StudioPresetBlock block) {
    if (block.content.trim().isEmpty) {
      throw StateError(
        'Studio Ledger preset instruction "${block.id}" is blank. '
        'Edit the active Studio preset.',
      );
    }
  }

  void _validateInstruction(StudioPresetBlock block) {
    if (!isLedgerPresetInstruction(block)) {
      throw StateError(
        'Studio Ledger preset block "${block.id}" must be an instruction '
        'routed to "ledger". Edit the active Studio preset.',
      );
    }
  }
}
