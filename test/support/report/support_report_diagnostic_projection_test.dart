import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/services/report/support_report_diagnostic_projection.dart';

void main() {
  test('report links finite probable assessment to report-local evidence', () {
    final projection = SupportReportDiagnosticProjection.fromEvents([
      {
        'kind': 'transport_succeeded',
        'status_code': 200,
        'truncated': 0,
        'attempt': 1,
        '_causalAssessment': {
          'observedFactCode': 'provider_finish_reason_recorded',
          'factConfidence': 'confirmed_by_check',
          'causalDiagnosis': 'probable_cause',
          'causalStatementCode': 'provider_finish_length',
          'alternatives': ['provider_specific_policy_or_normalization'],
          'missingEvidence': ['user_visible_symptom_correlation'],
          'nextSafeStep': 'compare_finish_reason_with_reported_visible_symptom',
          'automaticRepair': false,
        },
      },
    ]);
    final encoded = jsonEncode(projection.diagnoses);

    expect(encoded, contains('probableCause'));
    expect(encoded, contains('provider_finish_length'));
    expect(encoded, contains('event-1'));
    expect(encoded, contains('bounded_retained_slice_only'));
    expect(encoded, isNot(contains('payload_json')));
  });

  test('report never promotes scalar failure metadata to root cause', () {
    final projection = SupportReportDiagnosticProjection.fromEvents([
      {
        'kind': 'transport_failed',
        'status_code': 503,
        'truncated': 0,
        'attempt': 1,
      },
    ]);
    final encoded = jsonEncode(projection.diagnoses);

    expect(encoded, contains('"certainty":"confirmed"'));
    expect(encoded, contains('"certainty":"insufficientEvidence"'));
  });
}
