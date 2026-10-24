import '../../../../../core/db/repositories/llm_request_capture_repo.dart';
import '../../../models/support_app_action.dart';

/// Native sink configuration is observed only. No request/error body is loaded,
/// and compile-time retention budgets are not misrepresented as writable prefs.
final class SupportAppDiagnosticsAdapter implements SupportAppActionAdapter {
  SupportAppDiagnosticsAdapter({required this.repo, required this.sinks});
  final LlmRequestCaptureRepo repo;
  final SupportAppDiagnosticSinksPort sinks;

  @override
  List<SupportAppActionDefinition> get definitions => [
    SupportAppActionDefinition(
      name: 'astoria_diagnostics_read',
      description:
          'Read local capture configuration and counts for the original '
          'session only. Never read requests, errors, keys or raw captures. '
          'Health and credential validity remain unknown.',
      risk: SupportAppActionRisk.metadata,
    ),
  ];

  @override
  Future<SupportAppPreparedAction?> prepare(
    String action,
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  ) async {
    if (action != 'astoria_diagnostics_read' || !context.current) return null;
    if (arguments.isNotEmpty) {
      throw const SupportAppActionRefused(
        SupportAppActionCode.invalidArguments,
      );
    }
    final configuration = sinks.observe();
    final counts = await repo.inspectControlCounts(context.sessionId);
    if (!context.current) return null;
    return SupportAppPreparedAction(
      target: 'secondary-original-session-diagnostics',
      observation: configuration,
      observationIsCurrent: () =>
          context.current && sinks.isCurrent(configuration),
      execute: (current) async => SupportAppActionOutcome(
        current() ? SupportAppActionCode.completed : SupportAppActionCode.stale,
        data: current()
            ? {
                'requestCaptureInstalled': configuration.requests,
                'callEventCaptureInstalled': configuration.events,
                'requestCount': counts.requests,
                'callEventCount': counts.events,
                'maxRowsPerSession': LlmRequestCaptureRepo.maxRowsPerSession,
                'maxBytesPerSession': LlmRequestCaptureRepo.maxBytesPerSession,
                'maxRowsTotal': LlmRequestCaptureRepo.maxRowsTotal,
                'maxBytesTotal': LlmRequestCaptureRepo.maxBytesTotal,
                'retentionMutable': false,
                'health': 'unknown',
                'credentialValidity': 'unknown',
              }
            : const {},
      ),
    );
  }
}

final class SupportAppDiagnosticSinkObservation {
  const SupportAppDiagnosticSinkObservation({
    required this.requests,
    required this.events,
  });
  final bool requests, events;
}

/// Configuration observation only; cannot install an arbitrary sink or change
/// capture lifetime. The app's existing installation provider remains owner.
abstract interface class SupportAppDiagnosticSinksPort {
  SupportAppDiagnosticSinkObservation observe();
  bool isCurrent(SupportAppDiagnosticSinkObservation observation);
}
