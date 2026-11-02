/// Finite observations over original, correlated native metadata only. This
/// helper never reads sourceText, saved diagnosticReview, error prose or bodies.
/// A confirmed observation is not a causal diagnosis or a whole-target verdict.
final class SupportDiagnosticMetadataFinding {
  const SupportDiagnosticMetadataFinding(this.code, this.missing);

  final String code;
  final List<String> missing;

  static SupportDiagnosticMetadataFinding? observe(
    String tool,
    Map<String, Object?> arguments,
    Map<String, Object?> data,
  ) {
    if (data.containsKey('exactDuplicateOfCallId')) return null;
    switch (tool) {
      case 'astoria_connection_read':
        final configured = data['credentialConfigured'];
        if (configured is! bool || data['verification'] != 'notTested') {
          return null;
        }
        return SupportDiagnosticMetadataFinding(
          configured ? 'credential_recorded' : 'credential_not_recorded',
          const [
            'credential_validity',
            'recorded_transport_failure',
            'connection_test',
          ],
        );
      case 'astoria_session_diagnostics':
        if (arguments['view'] == 'requests') {
          final count = _count(data['captureSampleCount']);
          final truncated = _count(data['truncatedSampleCount']);
          final events = _count(data['eventSampleCount']);
          if (count == null ||
              truncated == null ||
              events == null ||
              data['sampleLimit'] != 32 ||
              count > 32 ||
              events > 32 ||
              truncated > count) {
            return null;
          }
          return SupportDiagnosticMetadataFinding(
            count == 0 && events == 0
                ? 'no_captures_in_bounded_sample'
                : truncated > 0
                ? 'truncated_capture_sample'
                : 'capture_sample_available',
            const [
              'complete_capture_history',
              'recorded_failure_details',
              'historical_assembled_prompt',
            ],
          );
        }
        if (arguments['view'] == 'catalog') {
          final count = _count(data['catalogRowCount']);
          final stale = _count(data['staleRowCount']);
          if (count == null || stale == null || stale > count) return null;
          return SupportDiagnosticMetadataFinding(
            stale > 0
                ? 'stale_catalog_rows_observed'
                : 'no_marked_stale_rows_observed',
            const [
              'semantic_catalog_correctness',
              'retrieval_quality',
              'canonical_book_validation',
            ],
          );
        }
        return null;
      case 'astoria_canon_validate':
        final status = data['status'];
        if (status != 'invalid' &&
            (status != 'assembled' ||
                data['requiresBaselineDecision'] is! bool)) {
          return null;
        }
        return SupportDiagnosticMetadataFinding(
          status == 'invalid'
              ? 'canon_assembly_unavailable'
              : data['requiresBaselineDecision'] == true
              ? 'baseline_decision_required'
              : 'canon_assembled',
          const ['narrative_truth', 'lineage_repair_verification'],
        );
      default:
        return null;
    }
  }

  static int? _count(Object? value) =>
      value is int && value >= 0 && value <= 1000000000 ? value : null;
}
