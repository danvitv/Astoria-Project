import 'dart:convert';

import '../../../../core/llm/diagnostics/recorded_diagnostic_causal_assessment.dart';
import '../../../../core/llm/transport/native_tool_types.dart';

/// Extracts only native finite runtime summaries from one admitted Source4 read.
/// Other source payloads remain opaque and are never retained or interpreted.
abstract final class SupportDiagnosticCausalSource {
  static List<SupportDiagnosticCausalObservation> observe(
    NativeToolCall call,
    Map<String, Object?> data,
  ) {
    if (call.name != 'astoria_source_read') return const [];
    final sourceText = data['sourceText'];
    if (sourceText is! String || sourceText.length > 131072) return const [];
    try {
      final wire = jsonDecode(sourceText);
      if (wire is! Map<String, dynamic> ||
          wire['operation'] != 'astoria_source_read' ||
          wire['status'] != 'ok' ||
          wire['effect'] != 'none' ||
          wire['complete'] != true ||
          wire['partial'] != false ||
          wire['nextCursor'] != null ||
          wire['incompleteReason'] != null ||
          wire['trust'] != 'untrusted_source_data') {
        return const [];
      }
      final pieces = wire['pieces'];
      if (pieces is! List ||
          pieces.length > 5 ||
          wire['count'] != pieces.length) {
        return const [];
      }
      final result = <SupportDiagnosticCausalObservation>[];
      for (final piece in pieces) {
        if (piece is! Map<String, dynamic> || piece['complete'] != true) {
          continue;
        }
        final payload = piece['payload'];
        if (payload is! Map<String, dynamic>) continue;
        if (payload['identityLink'] !=
                'native_exact_session_run_call_attempt' ||
            !const {
              'exact_session_run_call_attempt',
              'missing_or_ambiguous',
            }.contains(payload['requestLink'])) {
          continue;
        }
        final assessment = RecordedDiagnosticCausalAssessment.fromRuntime(
          payload.cast<String, Object?>(),
        );
        final reference = payload['eventReference'];
        if (assessment == null ||
            reference is! int ||
            reference < 1 ||
            reference > 1000000000) {
          continue;
        }
        result.add(
          SupportDiagnosticCausalObservation(
            evidenceId: '${call.id}:event-$reference',
            assessment: assessment,
          ),
        );
      }
      return List.unmodifiable(result);
    } catch (_) {
      return const [];
    }
  }
}

final class SupportDiagnosticCausalObservation {
  const SupportDiagnosticCausalObservation({
    required this.evidenceId,
    required this.assessment,
  });

  final String evidenceId;
  final RecordedDiagnosticCausalAssessment assessment;
}
