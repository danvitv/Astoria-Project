/// Bounded report-local projection of already-sanitized event rows.
/// Private runtime payloads never enter this object.
final class SupportReportDiagnosticProjection {
  const SupportReportDiagnosticProjection._(this.events, this.diagnoses);

  final Map<String, Object?> events;
  final Map<String, Object?> diagnoses;

  static SupportReportDiagnosticProjection fromEvents(
    List<Map<String, Object?>> rows,
  ) {
    final evidence = <Map<String, Object?>>[];
    final causalAssessments = <Map<String, Object?>>[];
    for (var i = 0; i < rows.length && i < 64; i++) {
      final row = rows[i], evidenceId = 'event-${i + 1}';
      evidence.add({
        'evidenceId': evidenceId,
        'kind': row['kind'],
        'status_code': row['status_code'],
        'truncated': row['truncated'],
        'attempt': row['attempt'],
      });
      final assessment = row['_causalAssessment'];
      if (assessment is Map<String, Object?> && causalAssessments.length < 16) {
        causalAssessments.add({
          ...assessment,
          'evidenceIds': [evidenceId],
        });
      }
    }
    final failures = evidence
        .where(
          (item) => const {
            'transport_failed',
            'parser_rejected',
            'pipeline_failed',
          }.contains(item['kind']),
        )
        .toList(growable: false);
    return SupportReportDiagnosticProjection._(
      Map.unmodifiable({
        'records': List<Map<String, Object?>>.unmodifiable(evidence),
        'hasMore': rows.length > 64,
        'retentionCompleteness': 'unknown',
      }),
      Map.unmodifiable({
        'observedFailure': {
          'certainty': failures.isEmpty ? 'insufficientEvidence' : 'confirmed',
          'statement': failures.isEmpty
              ? 'No failure observed in this bounded slice.'
              : 'Failure records exist in this bounded slice.',
          'evidenceIds': failures.map((item) => item['evidenceId']).toList(),
          'alternatives': ['Earlier or uncaptured records are unknown.'],
        },
        'rootCause': {
          'certainty':
              causalAssessments.any(
                (item) => item['causalDiagnosis'] == 'probable_cause',
              )
              ? 'probableCause'
              : 'insufficientEvidence',
          'evidenceIds': causalAssessments
              .expand((item) => item['evidenceIds'] as List)
              .toList(),
          'statement': causalAssessments.isEmpty
              ? 'Scalar metadata does not establish a root cause.'
              : 'Finite recorded-call assessments; probable applies only to the linked symptom.',
          'alternatives': [
            'Provider or network failure',
            'Parser incompatibility',
            'Incomplete retained evidence',
          ],
        },
        'causalAssessments': List<Map<String, Object?>>.unmodifiable(
          causalAssessments,
        ),
        'assessmentCompleteness': rows.length > 64
            ? 'bounded_with_more_events'
            : 'bounded_retained_slice_only',
      }),
    );
  }
}
