import 'support_permission_preferences.dart';
import 'support_recipient_resolution.dart';

/// Opaque displayed consent origin. Only a native issuer can validate it;
/// implementing this interface or reconstructing view fields grants nothing.
abstract interface class SupportNativeDisplayedIntent {}

/// Transient native-only inspection. Never a chat card, context or model input.
final class SupportConnectionInspection {
  const SupportConnectionInspection({
    required this.connectionLabel,
    required this.protocolLabel,
    required this.modelLabel,
    required this.configured,
    required this.characterCount,
  });
  final String connectionLabel, protocolLabel, modelLabel;
  final bool configured;
  final int characterCount;
  @override
  String toString() => 'SupportConnectionInspection';
}

final class SupportNativeRightView {
  const SupportNativeRightView(
    this.right,
    this.enabled,
    this.available,
    this.reason,
  );
  final SupportPermission right;
  final bool enabled, available;
  final String? reason;
}

/// Safe immutable UI snapshot. No policy JSON, raw config, exception or key.
final class SupportNativeView {
  SupportNativeView({
    required this.sessionId,
    required this.availability,
    required this.busy,
    required this.recipient,
    required this.needsRecipientConfirmation,
    required Iterable<SupportNativeRightView> rights,
    this.gameSessionId,
    this.gameMessageCount = 0,
    this.supportMessageCount = 0,
    this.connectionsSelected = false,
    this.error,
    this.inspection,
    this.displayedIntent,
  }) : rights = List.unmodifiable(rights);
  final String sessionId;
  final SupportPermissionAvailability availability;
  final bool busy, needsRecipientConfirmation, connectionsSelected;
  final SupportRecipientResolution recipient;
  final List<SupportNativeRightView> rights;
  final String? gameSessionId, error;
  final int gameMessageCount, supportMessageCount;
  final SupportConnectionInspection? inspection;
  final SupportNativeDisplayedIntent? displayedIntent;
  @override
  String toString() => 'SupportNativeView';
}
