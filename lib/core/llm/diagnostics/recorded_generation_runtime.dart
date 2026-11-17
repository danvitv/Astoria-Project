import 'generation_runtime_call_facts.dart';

/// Recognizes one ordinary main-model event and its closed provider-neutral
/// request/callback envelope. Raw request, response and error prose are ignored.
abstract final class RecordedGenerationRuntime {
  static Map<String, Object?>? fromColumns(Map<String, Object?> row) {
    if (row['stage'] != 'main' ||
        row['attempt'] != 1 ||
        row['_diagnosticIdentityValid'] != 1 ||
        row['truncated'] != 0 ||
        row['parser_name'] != null ||
        row['parser_code'] != null ||
        row['parser_detail'] != null) {
      return null;
    }
    final kind = row['kind'];
    final status = row['status'];
    final statusCode = row['status_code'];
    final succeeded =
        kind == 'transport_succeeded' && status == 'ok' && statusCode == 200;
    final failedStatus = switch ((status, statusCode)) {
      ('http_4xx', int code) when code >= 400 && code < 500 => true,
      ('http_5xx', int code) when code >= 500 && code < 600 => true,
      (
        'timeout' ||
            'cancelled' ||
            'connection_closed' ||
            'socket_error' ||
            'error',
        0,
      ) =>
        true,
      _ => false,
    };
    final failed = kind == 'transport_failed' && failedStatus;
    if (!succeeded && !failed) return null;

    final callFacts = GenerationRuntimeCallFacts.fromSavedPayload(
      row['payload_json'],
    );
    if (callFacts == null) return null;
    final branch = (callFacts['streamObservation'] as Map)['completionBranch'];
    final consistent = succeeded
        ? branch == 'complete'
        : switch (status) {
            'timeout' => branch == 'timeout',
            'cancelled' => branch == 'cancelled',
            _ => branch == 'error',
          };
    if (!consistent) return null;

    return {
      'finding': 'recorded_generation_runtime_outcome',
      'outcome': succeeded ? 'completed' : 'failed',
      'transportStatus': status,
      'attempt': 1,
      'factConfidence': 'confirmed_by_check',
      'causalDiagnosis': 'insufficient_data',
      'scope': 'this_saved_main_call_event_only',
      'method': 'native_recorded_request_and_callbacks',
      'callFacts': callFacts,
      'runCompleteness': 'not_proven_by_retained_events',
      'actualTokenUse': 'unknown_not_recorded',
      'contextBudgetEvidence': callFacts.containsKey('contextPlanning')
          ? 'recorded_prompt_builder_plan'
          : 'not_recorded',
      'automaticRepair': false,
    };
  }
}
