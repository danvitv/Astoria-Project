import 'studio_config.dart';

/// Structural phase routing only. Content and extraction policy stay editable.
bool isLedgerPresetInstruction(StudioPresetBlock block) =>
    (block.section.isEmpty || block.section == 'ledger') &&
    block.injectionPoint == 'ledger' &&
    block.type == StudioBlockType.instruction &&
    block.mode == 'direct' &&
    block.targetAgentId == null &&
    block.groupBoundary == 'none' &&
    !block.appendToLastMessage;
