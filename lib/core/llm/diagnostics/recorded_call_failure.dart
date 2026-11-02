/// Finite observations from native call-event columns, never response/error
/// prose or request JSON. A recorded outcome does not establish its root cause.
abstract final class RecordedCallFailure {
  static Map<String, Object?>? fromColumns(Map<String, Object?> columns) {
    final kind = columns['kind'];
    final status = columns['status'];
    final code = columns['status_code'];
    final attempt = columns['attempt'];
    final truncated = columns['truncated'];
    if (attempt is! int ||
        attempt < 1 ||
        attempt > 2147483647 ||
        (truncated != 0 && truncated != 1)) {
      return null;
    }

    String? finding;
    if (kind == 'parser_rejected') {
      if (status != null || code != null) return null;
      finding = 'recorded_parser_rejection';
    } else if (kind == 'transport_failed') {
      if (code is! int || code < 0 || code > 599) return null;
      if (code >= 400 && status == (code < 500 ? 'http_4xx' : 'http_5xx')) {
        finding = switch (code) {
          401 || 403 => 'recorded_http_authorization_rejection',
          404 => 'recorded_http_not_found',
          429 => 'recorded_http_rate_limit',
          >= 500 => 'recorded_http_server_error',
          _ => 'recorded_http_client_error',
        };
      } else if (code == 0 && status == 'timeout') {
        finding = 'recorded_timeout';
      } else if (code == 0 && status == 'cancelled') {
        finding = 'recorded_cancellation';
      } else if (code == 0 && status == 'error') {
        finding = 'recorded_transport_failure';
      } else {
        // Do not resolve contradictory/unknown native columns using prose.
        return null;
      }
    }
    if (finding == null) return null;
    return {
      'finding': finding,
      'factConfidence': 'confirmed_by_check',
      'causalDiagnosis': 'insufficient_data',
      'scope': 'this_saved_call_event_only',
      'method': 'native_recorded_columns',
      'attempt': attempt,
      if (kind == 'transport_failed' && code is int && code >= 400)
        'httpStatus': code,
      'detailTruncated': truncated == 1,
      'missingEvidence': [
        'underlying_failure_cause',
        'historical_request_completeness',
        'current_connection_validity',
        'live_provider_verification',
      ],
      'automaticRepair': false,
    };
  }
}
