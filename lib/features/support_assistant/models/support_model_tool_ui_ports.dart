import 'support_app_action_context.dart';

/// Native original-screen ports, never decoded from model input or persisted.
final class SupportModelToolUiPorts {
  const SupportModelToolUiPorts({
    this.confirmation,
    this.navigation,
    this.backupFileHost,
    this.sourceTargetSelection,
  });
  final SupportAppConfirmationPort? confirmation;
  final SupportAppNavigationPort? navigation;

  /// Service composition requires the exact native file-host implementation.
  /// The model layer retains a native port, not a service/source or JSON handle.
  final SupportAppConfirmationPort? backupFileHost;
  final SupportSourceTargetSelectionPort? sourceTargetSelection;
}

/// LOCAL discovery only. Candidate and observation identities are opaque native
/// pointers, never model arguments, body grants or persisted selections.
abstract interface class SupportSourceTargetSelectionPort {
  Future<SupportSourceTargetCandidate?> selectSource(
    SupportSourceTargetSelectionRequest request,
  );
}

final class SupportSourceTargetCandidate {
  const SupportSourceTargetCandidate({
    required this.observation,
    required this.label,
    required this.hint,
  });
  final Object observation;
  final String label, hint;
}

/// Exact host-issued LOCAL page. No selectors or observations are made by UI.
final class SupportSourceTargetPage {
  SupportSourceTargetPage({
    required List<SupportSourceTargetCandidate> candidates,
    required this.hasNext,
  }) : candidates = List.unmodifiable(candidates);
  final List<SupportSourceTargetCandidate> candidates;
  final bool hasNext;
}

final class SupportSourceTargetSelectionRequest {
  SupportSourceTargetSelectionRequest({
    required this.context,
    required this.callId,
    required this.isOriginalCurrent,
    required List<SupportSourceTargetCandidate> candidates,
    bool hasNext = false,
    this.loadNext,
  }) : initialPage = SupportSourceTargetPage(
         candidates: candidates,
         hasNext: hasNext,
       );
  final SupportAppActionContext context;
  final String callId;
  final bool Function() isOriginalCurrent;
  final SupportSourceTargetPage initialPage;
  List<SupportSourceTargetCandidate> get candidates => initialPage.candidates;
  final Future<SupportSourceTargetPage?> Function(SupportSourceTargetPage)?
  loadNext;
  bool get current => context.current && isOriginalCurrent() && context.current;
}
