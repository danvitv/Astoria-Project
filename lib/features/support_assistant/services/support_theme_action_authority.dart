part of 'support_theme_action_service.dart';

final class SupportThemeIntent {
  SupportThemeIntent._(this._binding);
  final _ThemeBinding _binding;
}

final class SupportThemeObservation {
  SupportThemeObservation._(this._binding, this._native);
  final _ThemeBinding _binding;
  final ThemeSelectionObservation _native;
}

final class SupportThemeChoice {
  SupportThemeChoice._(this._binding, this._plan);
  final _ThemeBinding _binding;
  final ThemeSelectionPlan _plan;
  SupportThemeOperation get operation =>
      SupportThemeActionService._operation(_plan.operation);

  /// No stale label fallback after a known-value registration or owner loss.
  SupportThemeValue? get value {
    final s = _binding.service;
    if (!s._displayCurrent(_binding)) return null;
    final p = s.redaction.redactor;
    final result = s._project(
      _plan.after,
      _plan.before.id == _plan.after.id,
      p,
    );
    return s._displayCurrent(_binding) && identical(p, s.redaction.redactor)
        ? result
        : null;
  }
}

final class SupportThemeInstalledView {
  SupportThemeInstalledView._(Iterable<SupportThemeChoice> choices)
    : choices = List.unmodifiable(choices);
  final List<SupportThemeChoice> choices;
}

final class SupportThemeReview {
  SupportThemeReview._(this._binding, this._plan, this._applied);
  final _ThemeBinding _binding;
  final ThemeSelectionPlan? _plan;
  final SupportThemeApplied? _applied;
  SupportThemeActionKind get kind => _applied == null
      ? SupportThemeActionKind.apply
      : SupportThemeActionKind.undo;
  SupportThemeOperation get operation => SupportThemeActionService._operation(
    _applied?._receipt.operation ?? _plan!.operation,
  );
}

final class SupportThemeApproval {
  SupportThemeApproval._(this._review);
  final SupportThemeReview _review;
}

/// Transient SAME original receipt/custody. It is not Undo approval and has no
/// serializer, restoration constructor, raw content or historical fingerprint.
final class SupportThemeApplied {
  SupportThemeApplied._(
    this._custody,
    this._theme,
    this._reservation,
    this._receipt,
  );
  final SupportThemeActionCustody _custody;
  final ThemeNotifier _theme;
  final SupportMutationReservation _reservation;
  final ThemeSelectionReceipt _receipt;
}

final class _ThemeBinding {
  _ThemeBinding(
    this.service,
    this.controller,
    this.uiLifetime,
    this.externalCurrent,
    this.policy,
  ) : issuer = service._issuer,
      sessionId = service.runtime.sessionId,
      lifetime = service.runtime.lifetime,
      epoch = service.runtime.epoch,
      writeOwner = service.runtime.writeOwner,
      redactor = service.redaction.redactor;
  final SupportThemeActionService service;
  final Object controller, uiLifetime, issuer;
  final bool Function() externalCurrent;
  final String sessionId;
  final int lifetime, epoch, writeOwner;
  final SupportPermissionPreferences policy;
  final SecretRedactor redactor;
}

extension _ThemeAuthority on SupportThemeActionService {
  bool _readAllowed(SupportPermissionPreferences p) =>
      p.revision < maxSupportPermissionRevision &&
      p.allows(SupportPermission.readSafeSettings) &&
      p.scope?.safeCategories.contains(SupportSafeCategory.theme) == true;

  bool _samePolicy(
    SupportPermissionPreferences a,
    SupportPermissionPreferences? b,
  ) =>
      b != null &&
      a.supportSessionId == b.supportSessionId &&
      a.policyIdentity == b.policyIdentity &&
      a.revision == b.revision &&
      a.grants.length == b.grants.length &&
      a.grants.every(b.grants.contains) &&
      (a.scope == null ? b.scope == null : a.scope!.sameAs(b.scope)) &&
      (a.recipient == null
          ? b.recipient == null
          : a.recipient!.sameAs(b.recipient));

  bool _base(_ThemeBinding b) =>
      identical(b.service, this) &&
      _alive &&
      identical(b.issuer, _issuer) &&
      runtime.alive &&
      runtime.sessionId == b.sessionId &&
      runtime.lifetime == b.lifetime &&
      runtime.writeOwner == b.writeOwner &&
      runtime.pending == 0 &&
      runtime.settingsPending == 0 &&
      runtime.snapshot.isAvailable;

  bool _displayCurrent(_ThemeBinding b) {
    try {
      runtime.checkConfiguration();
      final p = runtime.snapshot.preferences;
      if (!_base(b) ||
          p == null ||
          !_readAllowed(p) ||
          !runtime.configurationStable() ||
          !isOriginalThemeOwner() ||
          !b.externalCurrent()) {
        return false;
      }
      runtime.checkConfiguration();
      return _base(b) &&
          _readAllowed(runtime.snapshot.preferences!) &&
          SupportThemeActionService._codec.identifier(
            b.sessionId,
            redaction.redactor,
          );
    } catch (_) {
      return false;
    }
  }

  bool _current(_ThemeBinding b, {bool changes = false}) {
    bool exact() =>
        _base(b) &&
        runtime.epoch == b.epoch &&
        _samePolicy(b.policy, runtime.snapshot.preferences) &&
        identical(b.redactor, redaction.redactor) &&
        _readAllowed(b.policy) &&
        (!changes ||
            b.policy.allows(SupportPermission.confirmedSettingsChanges)) &&
        SupportThemeActionService._codec.identifier(b.sessionId, b.redactor);
    try {
      runtime.checkConfiguration();
      if (!exact() ||
          !runtime.configurationStable() ||
          !isOriginalThemeOwner() ||
          !custody._current() ||
          !b.externalCurrent()) {
        return false;
      }
      // Callback reentrancy must not renew stale epoch/owner/policy authority.
      runtime.checkConfiguration();
      return exact();
    } catch (_) {
      return false;
    }
  }

  Future<bool> _fresh(_ThemeBinding b, {bool changes = false}) async {
    if (!_current(b, changes: changes)) return false;
    try {
      final next = await runtime.permissions.readForNative(b.sessionId);
      return _current(b, changes: changes) &&
          next.isAvailable &&
          _samePolicy(b.policy, next.preferences);
    } catch (_) {
      return false;
    }
  }
}
