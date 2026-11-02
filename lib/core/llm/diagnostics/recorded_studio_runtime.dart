import 'studio_runtime_call_facts.dart';

/// Recognizes only the closed orchestration vocabulary, never saved settings,
/// output/error prose, or arbitrary JSON claiming an outcome.
abstract final class RecordedStudioRuntime {
  static Map<String, Object?>? fromColumns(Map<String, Object?> row) {
    if (row['parser_name'] != 'studio_runtime_v1' ||
        row['status_code'] != null ||
        row['truncated'] != 0 ||
        row['_diagnosticIdentityValid'] != 1) {
      return null;
    }
    final attempt = row['attempt'];
    if (attempt is! int || attempt < 1 || attempt > 3) return null;
    final stage = row['stage'];
    if (!const {
      'studio.pre_generation.phase',
      'studio.controller',
      'studio.final',
      'studio.post_processing',
    }.contains(stage)) {
      return null;
    }
    final phase = stage == 'studio.pre_generation.phase';
    final status = row['status'];
    final reason = row['parser_code'];
    final expectedKind = phase
        ? status == 'blocking_failure'
              ? 'pipeline_failed'
              : 'pipeline_completed'
        : 'result_selected';
    if (row['kind'] != expectedKind) return null;
    final valid = switch ((status, reason)) {
      ('executed', 'pre_generation_completed') => phase,
      (
        'skipped',
        'no_enabled_agents' ||
            'no_final_agent' ||
            'no_pre_generation_controllers',
      ) =>
        phase,
      (
        'blocking_failure',
        'missing_preset' ||
            'think_writer_missing' ||
            'pre_generation_exception' ||
            'pre_generation_timeout',
      ) =>
        phase,
      ('executed', 'controller_results_accepted') =>
        stage == 'studio.controller',
      ('blocking_failure', 'required_tracker_failed') =>
        phase || stage == 'studio.controller',
      ('skipped', 'cache_hit') => stage == 'studio.controller',
      ('executed', 'transport_completed') ||
      ('failed', 'transport_failed') ||
      (
        'fallback',
        'idle_timeout_partial' || 'cancelled_child_partial',
      ) => !phase,
      ('cancelled', 'cancelled') => true,
      _ => false,
    };
    if (!valid) return null;
    var callFacts =
        !phase &&
            const {
              'transport_completed',
              'transport_failed',
              'idle_timeout_partial',
              'cancelled_child_partial',
              'cancelled',
            }.contains(reason)
        ? StudioRuntimeCallFacts.fromSavedPayload(row['payload_json'])
        : null;
    if (callFacts != null) {
      final branch =
          (callFacts['streamObservation'] as Map)['completionBranch'];
      final consistent = switch ((reason, branch)) {
        ('transport_completed', 'complete') ||
        ('transport_failed', 'error' || 'timeout') ||
        ('idle_timeout_partial', 'idle_timeout') ||
        ('cancelled_child_partial', 'cancel_with_streamed_text') ||
        ('cancelled', 'cancelled') => true,
        _ => false,
      };
      if (!consistent) callFacts = null;
    }
    return {
      'finding': 'recorded_studio_runtime_outcome',
      'outcome': status,
      'reason': reason,
      'stage': stage,
      'attempt': attempt,
      'factConfidence': 'confirmed_by_check',
      'causalDiagnosis': 'insufficient_data',
      'scope': 'this_saved_runtime_event_only',
      'method': 'native_recorded_runtime_branch',
      'eventUnit': phase
          ? 'pre_generation_phase_decision'
          : reason == 'cache_hit'
          ? 'controller_cache_decision'
          : reason == 'controller_results_accepted' ||
                reason == 'required_tracker_failed'
          ? 'controller_invocation_outcome'
          : 'transport_completion_outcome',
      'transportEvidence': 'not_proven_by_runtime_event',
      'runCompleteness': 'not_proven_by_retained_events',
      'automaticRepair': false,
      if (callFacts != null) 'callFacts': callFacts,
    };
  }
}
