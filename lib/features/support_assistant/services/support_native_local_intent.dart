part of 'support_native_consent_controller.dart';

/// Actual emitted native local anchor. No reconstructed DTO/recipient epoch can
/// transplant it onto a replacement controller or authorize secret entry.
final class SupportNativeLocalDisplayedIntent {
  SupportNativeLocalDisplayedIntent._(
    this._issuer,
    this._issuerLifetime,
    this._runtimeLifetime,
    this._context,
    this._policy,
  );
  final SupportNativeConsentController _issuer;
  final int _issuerLifetime, _runtimeLifetime;
  final SupportNativePermissionContext _context;
  final SupportPermissionPreferences _policy;
  @override
  String toString() => 'SupportNativeLocalDisplayedIntent';
}

extension SupportNativeLocalIntents on SupportNativeConsentController {
  SupportNativeLocalDisplayedIntent? captureLocalDisplayedIntent() {
    final p = runtime.localPermissionSnapshot.preferences;
    if (p == null) return null;
    final intent = SupportNativeLocalDisplayedIntent._(
      this,
      _issuerLifetime,
      runtime.lifetime,
      runtime.localContext,
      p,
    );
    return isLocalDisplayedIntentCurrent(intent) ? intent : null;
  }

  bool isLocalDisplayedIntentCurrent(
    SupportNativeLocalDisplayedIntent? intent,
  ) {
    if (intent == null ||
        !identical(intent._issuer, this) ||
        intent._issuerLifetime != _issuerLifetime ||
        intent._runtimeLifetime != runtime.lifetime ||
        !runtime.localActionsAvailable ||
        !intent._context.sameAs(runtime.localContext)) {
      return false;
    }
    final p = runtime.localPermissionSnapshot.preferences;
    return p?.policyIdentity == intent._policy.policyIdentity &&
        p?.allows(SupportPermission.readSafeSettings) ==
            intent._policy.allows(SupportPermission.readSafeSettings) &&
        p?.allows(SupportPermission.confirmedSettingsChanges) ==
            intent._policy.allows(SupportPermission.confirmedSettingsChanges);
  }
}
