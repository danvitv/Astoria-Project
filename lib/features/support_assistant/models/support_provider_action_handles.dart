part of '../services/support_provider_action_service.dart';

final class SupportProviderUiIntent {
  SupportProviderUiIntent._(this._binding);
  final _ProviderBinding _binding;
}

sealed class SupportProviderConnectionHandle {
  SupportProviderConnectionHandle._(this._binding, this._view, this.purpose);
  final _ProviderBinding _binding;
  final KeylessApiConfigView _view;
  final SupportProviderPurpose purpose;

  SupportProviderSetupValue? get value => _binding.service._projectHandle(this);
}

final class SupportProviderChoice extends SupportProviderConnectionHandle {
  SupportProviderChoice._(
    _ProviderBinding binding,
    this._observation,
    SupportProviderPurpose purpose,
  ) : super._(binding, _observation.view, purpose);
  final KeylessApiConfigObservation _observation;
}

final class SupportProviderConnections {
  SupportProviderConnections._(Iterable<SupportProviderChoice> choices)
    : choices = List.unmodifiable(choices);
  final List<SupportProviderChoice> choices;
}

final class SupportProviderReview {
  SupportProviderReview._(
    this._binding,
    this.kind,
    this.purpose,
    this.destinationKind,
    this._before,
    this._after, {
    this._draft,
    this._choice,
    this._patch,
    this._undo,
  });
  final _ProviderBinding _binding;
  final SupportProviderActionKind kind;
  final SupportProviderPurpose purpose;
  final SupportProviderDestinationKind destinationKind;
  final KeylessApiConfigView? _before, _after;
  final KeylessApiConfigDraft? _draft;
  final SupportProviderChoice? _choice;
  final KeylessApiConfigPatch? _patch;
  final SupportProviderApplied? _undo;
  bool _closed = false;
  bool _cancelled = false;
}

/// Only a keyless-configuration preparation gesture. NEVER credential entry,
/// route binding, target assignment, network admission or a core route approval.
final class SupportProviderCustomDestinationConfirmation {
  SupportProviderCustomDestinationConfirmation._(this._review);
  final SupportProviderReview _review;
}

final class SupportProviderApproval {
  SupportProviderApproval._(this._review);
  final SupportProviderReview _review;
  bool _used = false;
}

/// Original same-service factual receipt; history cannot reconstruct it.
final class SupportProviderApplied extends SupportProviderConnectionHandle {
  SupportProviderApplied._(this._review, this._receipt)
    : super._(_review._binding, _receipt.after!, _review.purpose);
  final SupportProviderReview _review;
  final SupportProviderSetupReceipt _receipt;
  KeylessApiConfigObservation? _undoObservation;
  bool _undoUsed = false;
}

/// No retained display strings. The future returns this original fact even if
/// UI retirement means projectResult/value/readiness are no longer available.
final class SupportProviderActionResult {
  SupportProviderActionResult._(this.code, this._review, this.applied);
  final SupportProviderActionCode code;
  final SupportProviderReview _review;
  final SupportProviderApplied? applied;
}

final class _ProviderBinding {
  _ProviderBinding(
    this.service,
    this.controller,
    this.uiLifetime,
    this.externalCurrent,
    this.context,
    this.policy,
  ) : issuer = service._issuer;
  final SupportProviderActionService service;
  final Object controller, uiLifetime, issuer;
  final bool Function() externalCurrent;
  final SupportNativePermissionContext context;
  final SupportPermissionPreferences policy;
  String get sessionId => context.supportSessionId;
}
