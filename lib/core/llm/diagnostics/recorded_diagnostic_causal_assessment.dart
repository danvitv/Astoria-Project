/// Deterministic assessment of one already-recognized recorded runtime unit.
/// It never reads provider prose, reconstructs missing events or proposes a
/// mutation. A probable cause explains only the recorded call symptom.
final class RecordedDiagnosticCausalAssessment {
  const RecordedDiagnosticCausalAssessment._({
    required this.observedFactCode,
    required this.causalDiagnosis,
    required this.causalStatementCode,
    required this.alternatives,
    required this.missingEvidence,
    required this.nextSafeStep,
  });

  final String observedFactCode;
  final String causalDiagnosis;
  final String causalStatementCode;
  final List<String> alternatives;
  final List<String> missingEvidence;
  final String nextSafeStep;

  static RecordedDiagnosticCausalAssessment? fromRuntime(Object? value) {
    if (value is! Map<String, Object?> ||
        value['factConfidence'] != 'confirmed_by_check' ||
        value['automaticRepair'] != false) {
      return null;
    }
    return switch (value['finding']) {
      'recorded_generation_runtime_outcome' when _recognizedGeneration(value) =>
        _generation(value),
      'recorded_studio_runtime_outcome' when _recognizedStudio(value) =>
        _studio(value),
      _ => null,
    };
  }

  static bool _recognizedGeneration(Map<String, Object?> value) {
    final outcome = value['outcome'], status = value['transportStatus'];
    return value['attempt'] == 1 &&
        value['causalDiagnosis'] == 'insufficient_data' &&
        value['scope'] == 'this_saved_main_call_event_only' &&
        value['method'] == 'native_recorded_request_and_callbacks' &&
        value['runCompleteness'] == 'not_proven_by_retained_events' &&
        (value['actualTokenUse'] == 'unknown_not_recorded' ||
            value['actualUsageEvidence'] == 'unknown_not_recorded') &&
        value['callFacts'] is Map<String, Object?> &&
        ((outcome == 'completed' && status == 'ok') ||
            (outcome == 'failed' &&
                const {
                  'http_4xx',
                  'http_5xx',
                  'timeout',
                  'cancelled',
                  'connection_closed',
                  'socket_error',
                  'error',
                }.contains(status)));
  }

  static bool _recognizedStudio(Map<String, Object?> value) =>
      value['attempt'] is int &&
      (value['attempt'] as int) >= 1 &&
      (value['attempt'] as int) <= 3 &&
      value['causalDiagnosis'] == 'insufficient_data' &&
      value['scope'] == 'this_saved_runtime_event_only' &&
      value['method'] == 'native_recorded_runtime_branch' &&
      value['runCompleteness'] == 'not_proven_by_retained_events' &&
      value['reason'] is String &&
      value['stage'] is String;

  Map<String, Object?> toJson({String? evidenceId}) => Map.unmodifiable({
    'observedFactCode': observedFactCode,
    'factConfidence': 'confirmed_by_check',
    'causalDiagnosis': causalDiagnosis,
    'causalStatementCode': causalStatementCode,
    if (evidenceId != null) 'evidenceIds': [evidenceId],
    'alternatives': alternatives,
    'missingEvidence': missingEvidence,
    'nextSafeStep': nextSafeStep,
    'automaticRepair': false,
  });

  static RecordedDiagnosticCausalAssessment _generation(
    Map<String, Object?> unit,
  ) {
    final status = unit['transportStatus'];
    if (unit['outcome'] == 'failed') {
      return _probable(
        observed: 'recorded_main_transport_failure',
        statement: switch (status) {
          'timeout' => 'recorded_timeout_ended_call',
          'http_4xx' => 'recorded_http_client_rejection_ended_call',
          'http_5xx' => 'recorded_http_server_failure_ended_call',
          'cancelled' => 'recorded_cancellation_ended_call',
          _ => 'recorded_transport_failure_ended_call',
        },
        alternatives: const [
          'provider_or_gateway_behavior',
          'network_or_local_cancellation',
          'incomplete_retained_run',
        ],
        next: 'inspect_exact_connection_and_adjacent_recorded_attempts',
      );
    }
    return _fromCallFacts(
      unit['callFacts'],
      completedCode: 'recorded_main_call_completed',
    );
  }

  static RecordedDiagnosticCausalAssessment _studio(Map<String, Object?> unit) {
    final reason = unit['reason'];
    if (const {
      'required_tracker_failed',
      'missing_preset',
      'think_writer_missing',
      'pre_generation_exception',
      'pre_generation_timeout',
      'transport_failed',
      'idle_timeout_partial',
      'cancelled_child_partial',
      'cancelled',
    }.contains(reason)) {
      return _probable(
        observed: 'recorded_studio_nonstandard_outcome',
        statement: 'recorded_studio_$reason',
        alternatives: const [
          'upstream_controller_or_transport_state',
          'incomplete_retained_pipeline',
        ],
        next: 'inspect_linked_studio_phase_and_adjacent_attempts',
      );
    }
    return _fromCallFacts(
      unit['callFacts'],
      completedCode: 'recorded_studio_runtime_branch',
    );
  }

  static RecordedDiagnosticCausalAssessment _fromCallFacts(
    Object? value, {
    required String completedCode,
  }) {
    if (value is Map<String, Object?>) {
      final finish = value['providerFinishReason'];
      if (finish == 'length' ||
          finish == 'content_filter' ||
          finish == 'tool_calls' ||
          finish == 'function_call' ||
          finish == 'refusal' ||
          finish == 'pause_turn') {
        return _probable(
          observed: 'provider_finish_reason_recorded',
          statement: 'provider_finish_$finish',
          alternatives: const [
            'provider_specific_policy_or_normalization',
            'user_visible_symptom_not_recorded',
          ],
          next: 'compare_finish_reason_with_reported_visible_symptom',
        );
      }
      final planning = value['contextPlanning'];
      if (planning is Map<String, Object?> &&
          planning['reductionReason'] != null &&
          planning['reductionReason'] != 'none') {
        return _insufficient(
          observed: 'local_history_reduction_recorded',
          statement: 'history_reduction_not_proven_as_root_cause',
          next: 'compare_local_reduction_with_expected_history_scope',
        );
      }
      final studio = value['studioRequestBudget'];
      if (studio is Map<String, Object?> &&
          studio['historyReductionReason'] != null &&
          studio['historyReductionReason'] != 'none') {
        return _insufficient(
          observed: 'studio_history_reduction_recorded',
          statement: 'history_reduction_not_proven_as_root_cause',
          next: 'compare_studio_selection_with_expected_history_scope',
        );
      }
    }
    return _insufficient(
      observed: completedCode,
      statement: 'retained_evidence_does_not_establish_root_cause',
      next: 'collect_missing_linked_runtime_evidence',
    );
  }

  static RecordedDiagnosticCausalAssessment _probable({
    required String observed,
    required String statement,
    required List<String> alternatives,
    required String next,
  }) => RecordedDiagnosticCausalAssessment._(
    observedFactCode: observed,
    causalDiagnosis: 'probable_cause',
    causalStatementCode: statement,
    alternatives: List.unmodifiable(alternatives),
    missingEvidence: const [
      'complete_linked_run',
      'user_visible_symptom_correlation',
      'independent_reproduction',
    ],
    nextSafeStep: next,
  );

  static RecordedDiagnosticCausalAssessment _insufficient({
    required String observed,
    required String statement,
    required String next,
  }) => RecordedDiagnosticCausalAssessment._(
    observedFactCode: observed,
    causalDiagnosis: 'insufficient_data',
    causalStatementCode: statement,
    alternatives: const [
      'provider_or_network_behavior',
      'different_or_unretained_attempt',
      'reported_symptom_has_another_cause',
    ],
    missingEvidence: const [
      'complete_linked_run',
      'user_visible_symptom_correlation',
    ],
    nextSafeStep: next,
  );
}
