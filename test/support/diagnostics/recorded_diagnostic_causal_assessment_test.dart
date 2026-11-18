import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/diagnostics/recorded_diagnostic_causal_assessment.dart';

Map<String, Object?> generation({
  String outcome = 'completed',
  String status = 'ok',
  Map<String, Object?> callFacts = const {},
}) => {
  'finding': 'recorded_generation_runtime_outcome',
  'outcome': outcome,
  'transportStatus': status,
  'attempt': 1,
  'factConfidence': 'confirmed_by_check',
  'causalDiagnosis': 'insufficient_data',
  'scope': 'this_saved_main_call_event_only',
  'method': 'native_recorded_request_and_callbacks',
  'callFacts': callFacts,
  'runCompleteness': 'not_proven_by_retained_events',
  'actualUsageEvidence': 'unknown_not_recorded',
  'automaticRepair': false,
};

void main() {
  test('finite provider finish reason explains only its linked symptom', () {
    final assessment = RecordedDiagnosticCausalAssessment.fromRuntime(
      generation(callFacts: {'providerFinishReason': 'length'}),
    )!;

    expect(assessment.causalDiagnosis, 'probable_cause');
    expect(assessment.causalStatementCode, 'provider_finish_length');
    expect(assessment.missingEvidence, contains('independent_reproduction'));
  });

  test('recorded timeout is probable for termination, not universal cause', () {
    final assessment = RecordedDiagnosticCausalAssessment.fromRuntime(
      generation(outcome: 'failed', status: 'timeout'),
    )!;

    expect(assessment.causalDiagnosis, 'probable_cause');
    expect(assessment.causalStatementCode, 'recorded_timeout_ended_call');
    expect(assessment.toJson()['automaticRepair'], isFalse);
  });

  test('local history reduction remains insufficient as root cause', () {
    final assessment = RecordedDiagnosticCausalAssessment.fromRuntime(
      generation(
        callFacts: {
          'contextPlanning': {'reductionReason': 'sliding_budget_limit'},
        },
      ),
    )!;

    expect(assessment.causalDiagnosis, 'insufficient_data');
    expect(
      assessment.causalStatementCode,
      'history_reduction_not_proven_as_root_cause',
    );
  });

  test('recorded Studio required tracker failure is finite and probable', () {
    final assessment = RecordedDiagnosticCausalAssessment.fromRuntime({
      'finding': 'recorded_studio_runtime_outcome',
      'attempt': 1,
      'factConfidence': 'confirmed_by_check',
      'causalDiagnosis': 'insufficient_data',
      'scope': 'this_saved_runtime_event_only',
      'method': 'native_recorded_runtime_branch',
      'runCompleteness': 'not_proven_by_retained_events',
      'reason': 'required_tracker_failed',
      'stage': 'tracker',
      'callFacts': const <String, Object?>{},
      'automaticRepair': false,
    })!;

    expect(assessment.causalDiagnosis, 'probable_cause');
    expect(
      assessment.causalStatementCode,
      'recorded_studio_required_tracker_failed',
    );
  });
}
