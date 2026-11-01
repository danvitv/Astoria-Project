import 'dart:convert';

import '../../../../core/credentials/secret_redactor.dart';
import '../../../../core/llm/transport/native_tool_types.dart';
import 'support_diagnostic_skills.dart';

/// Deterministic observations over ONE already-admitted native metadata result,
/// not specialist agents or causal diagnoses. No body/source parser, cross-target
/// joining, cache, DB, model or tool calls. The original run owns continuation POSTs.
abstract final class SupportDiagnosticReview {
  static NativeToolResult annotate(
    NativeToolCall call,
    NativeToolResult result,
    List<SupportDiagnosticSkill> skills,
    SecretRedactor redactor,
  ) {
    if (skills.isEmpty ||
        result.callId != call.id ||
        result.name != call.name ||
        result.content['ok'] != true ||
        result.content['effect'] != 'none') {
      return result;
    }
    final data = result.content['data'];
    if (data is! Map<String, Object?> ||
        data.containsKey('exactDuplicateOfCallId')) {
      return result;
    }
    final ids = skills.map((s) => s.id).toSet();
    final review = switch (call.name) {
      'astoria_connection_read'
          when ids.contains(SupportDiagnosticSkillId.connectionDiagnostics) ||
              ids.contains(SupportDiagnosticSkillId.generationDiagnostics) =>
        _connection(data),
      'astoria_session_diagnostics'
          when call.arguments['view'] == 'requests' &&
              (ids.contains(SupportDiagnosticSkillId.generationDiagnostics) ||
                  ids.contains(SupportDiagnosticSkillId.studioDiagnostics)) =>
        _captures(data),
      'astoria_session_diagnostics'
          when call.arguments['view'] == 'catalog' &&
              ids.contains(SupportDiagnosticSkillId.dataIntegrityAndFix) =>
        _catalog(data),
      'astoria_canon_validate'
          when ids.contains(SupportDiagnosticSkillId.dataIntegrityAndFix) =>
        _canon(data),
      _ => null,
    };
    if (review == null) return result;
    final annotated = {
      ...review,
      'evidenceIds': [call.id],
      'scope': 'this_tool_observation_only',
      'method': 'deterministic_metadata_observation',
      'causalDiagnosis': 'insufficient_data',
    };
    // New literals/correlation are checked against the CURRENT redactor too.
    // Never sanitize an unsafe finding into a different purported fact.
    final encoded = jsonEncode(annotated);
    if (redactor.redactText(encoded) != encoded) return result;
    try {
      return NativeToolResult(
        callId: result.callId,
        name: result.name,
        content: {
          ...result.content,
          'data': {...data, 'diagnosticReview': annotated},
        },
      );
    } on NativeToolException {
      // Advice must not turn a valid near-budget native result into a failure.
      return result;
    }
  }

  static Map<String, Object?>? _connection(Map<String, Object?> d) {
    final configured = d['credentialConfigured'];
    if (configured is! bool || d['verification'] != 'notTested') return null;
    return {
      'finding': configured ? 'credential_recorded' : 'credential_not_recorded',
      'confidence': 'confirmed_by_check',
      'missingEvidence': [
        'credential_validity',
        'recorded_transport_failure',
        'connection_test',
      ],
    };
  }

  static Map<String, Object?>? _captures(Map<String, Object?> d) {
    final count = _count(d['captureSampleCount']);
    final truncated = _count(d['truncatedSampleCount']);
    final events = _count(d['eventSampleCount']);
    if (count == null ||
        truncated == null ||
        events == null ||
        d['sampleLimit'] != 32 ||
        count > 32 ||
        events > 32 ||
        truncated > count) {
      return null;
    }
    return {
      'finding': count == 0 && events == 0
          ? 'no_captures_in_bounded_sample'
          : truncated > 0
          ? 'truncated_capture_sample'
          : 'capture_sample_available',
      'confidence': 'confirmed_by_check',
      'missingEvidence': [
        'complete_capture_history',
        'recorded_failure_details',
        'historical_assembled_prompt',
      ],
    };
  }

  static Map<String, Object?>? _catalog(Map<String, Object?> d) {
    final count = _count(d['catalogRowCount']),
        stale = _count(d['staleRowCount']);
    if (count == null || stale == null || stale > count) return null;
    return {
      'finding': stale > 0
          ? 'stale_catalog_rows_observed'
          : 'no_marked_stale_rows_observed',
      'confidence': 'confirmed_by_check',
      'missingEvidence': [
        'semantic_catalog_correctness',
        'retrieval_quality',
        'canonical_book_validation',
      ],
    };
  }

  static Map<String, Object?>? _canon(Map<String, Object?> d) {
    final status = d['status'];
    if (status != 'invalid' &&
        (status != 'assembled' || d['requiresBaselineDecision'] is! bool)) {
      return null;
    }
    return {
      'finding': status == 'invalid'
          ? 'canon_assembly_unavailable'
          : d['requiresBaselineDecision'] == true
          ? 'baseline_decision_required'
          : 'canon_assembled',
      'confidence': 'confirmed_by_check',
      'missingEvidence': ['narrative_truth', 'lineage_repair_verification'],
    };
  }

  static int? _count(Object? n) =>
      n is int && n >= 0 && n <= 1000000000 ? n : null;
}
