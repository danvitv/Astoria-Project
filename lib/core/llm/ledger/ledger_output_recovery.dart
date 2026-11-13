import 'dart:convert';

import '../../models/agent_operation_record.dart';
import '../../models/knowledge_cleanup.dart';
import '../../models/studio_ledger_export.dart';
import '../json_repair.dart';
import 'ledger_clock_normalization.dart';
import 'ledger_wire_contract.dart';

class LedgerOutputRecovery {
  const LedgerOutputRecovery();

  static const maxRepairInputBytes = 12000;

  bool isOversizedRepairInput(String value) =>
      utf8.encode(value).length > maxRepairInputBytes;

  String buildRepairPrompt(
    String malformed, {
    required String systemPrompt,
    bool reconciliation = false,
  }) {
    _requireInstructions(systemPrompt);
    final encoded = base64Encode(utf8.encode(malformed));
    final contract = reconciliation
        ? LedgerWireContract.reconciliation(focalUserName: '')
        : LedgerWireContract.turn(focalUserName: '');
    return '''$systemPrompt

$contract
<repair_validation_metadata>
{"inputEncoding":"base64/UTF-8","inputTrust":"untrusted","allowedTransform":"literalFormatOnly","literalEvidenceValidatedAfterParsing":true}
</repair_validation_metadata>
UNTRUSTED_INPUT_BASE64_BEGIN
$encoded
UNTRUSTED_INPUT_BASE64_END''';
  }

  String buildCleanupRepairPrompt(
    String malformed, {
    required String systemPrompt,
  }) {
    _requireInstructions(systemPrompt);
    final encoded = base64Encode(utf8.encode(malformed));
    return '''$systemPrompt

<cleanup_repair_wire_contract>
{"wrapper":"glaze_knowledge_cleanup","shape":{"ops":[]},"allowedOps":["retract","rename_entity"],"inputEncoding":"base64/UTF-8","inputTrust":"untrusted","allowedTransform":"literalFormatOnly","literalEvidenceValidatedAfterParsing":true}
</cleanup_repair_wire_contract>
UNTRUSTED_INPUT_BASE64_BEGIN
$encoded
UNTRUSTED_INPUT_BASE64_END''';
  }

  void _requireInstructions(String systemPrompt) {
    if (systemPrompt.trim().isEmpty) {
      throw StateError('Studio Ledger repair requires preset instructions.');
    }
  }

  bool repairPreservesStructuredEvidence(
    String original,
    StudioLedgerExport repaired,
  ) {
    final fragments = RegExp(r'\{[^{}]*\}')
        .allMatches(original)
        .map((match) {
          try {
            final decoded = jsonDecode(repairJson(match.group(0)!));
            return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
          } catch (_) {
            return null;
          }
        })
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);

    final sourceOps = <LedgerOp>[];
    final sourceFacts = <LedgerKnowledgeFact>[];
    for (final fragment in fragments) {
      try {
        if (fragment.containsKey('op') && fragment.containsKey('key')) {
          // Match the parser's numeric clock spelling, but only after strict
          // source decoding; malformed field types are still not evidence.
          sourceOps.add(
            LedgerClockNormalization.normalizeOp(LedgerOp.fromJson(fragment)),
          );
        } else if (fragment.containsKey('knowerKey') &&
            fragment.containsKey('subjectKey') &&
            fragment.containsKey('predicate') &&
            fragment.containsKey('object')) {
          sourceFacts.add(LedgerKnowledgeFact.fromJson(fragment));
        }
      } catch (_) {
        // Incomplete objects are not safe evidence for model-assisted repair.
      }
    }

    if (repaired.ops.isEmpty && repaired.knowledgeFacts.isEmpty) {
      return RegExp(r'"ops"\s*:\s*\[\s*\]').hasMatch(original) &&
          RegExp(r'"knowledgeFacts"\s*:\s*\[\s*\]').hasMatch(original);
    }
    return repaired.ops.every(sourceOps.contains) &&
        repaired.knowledgeFacts.every(sourceFacts.contains);
  }

  bool cleanupRepairPreservesLiteralEvidence(
    String original,
    List<KnowledgeCleanupOp> repaired,
  ) {
    bool present(String value) => value.isEmpty || original.contains(value);
    for (final op in repaired) {
      switch (op.type) {
        case KnowledgeCleanupOpType.retract:
          if (!present('retract') || !present(op.factId)) return false;
        case KnowledgeCleanupOpType.renameEntity:
          if (!present('rename_entity') ||
              !present(op.fromKey) ||
              !present(op.toKey) ||
              !present(op.canonicalName)) {
            return false;
          }
      }
    }
    return true;
  }

  List<AgentOperationAttempt> combineAttempts(
    List<AgentOperationAttempt> first,
    List<AgentOperationAttempt> second,
  ) => [
    ...first,
    ...second.map(
      (item) => AgentOperationAttempt(
        attempt: first.length + item.attempt,
        statusCode: item.statusCode,
        status: item.status,
        error: item.error,
        startedAtMs: item.startedAtMs,
        elapsedMs: item.elapsedMs,
      ),
    ),
  ];
}
