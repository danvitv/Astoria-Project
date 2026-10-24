import 'support_app_action_context.dart';

/// Native original-screen ports, never decoded from model input or persisted.
final class SupportModelToolUiPorts {
  const SupportModelToolUiPorts({
    this.confirmation,
    this.navigation,
    this.backupFileHost,
  });
  final SupportAppConfirmationPort? confirmation;
  final SupportAppNavigationPort? navigation;

  /// Service composition requires the exact native file-host implementation.
  /// The model layer retains a native port, not a service/source or JSON handle.
  final SupportAppConfirmationPort? backupFileHost;
}
