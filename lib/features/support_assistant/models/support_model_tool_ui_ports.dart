import 'support_app_action_context.dart';

/// Native original-screen ports, never decoded from model input or persisted.
final class SupportModelToolUiPorts {
  const SupportModelToolUiPorts({this.confirmation, this.navigation});
  final SupportAppConfirmationPort? confirmation;
  final SupportAppNavigationPort? navigation;
}
