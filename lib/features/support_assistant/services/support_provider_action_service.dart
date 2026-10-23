import 'dart:math';

import '../../../core/credentials/native_provider_credentials.dart';
import '../../../core/credentials/secret_redactor.dart';
import '../../../core/db/repositories/api_config_repo.dart';
import '../../../core/db/repositories/support_repo.dart';
import '../../../core/models/keyless_api_config.dart';
import '../../../core/models/support_models.dart';
import '../models/support_permission_preferences.dart';
import '../models/support_permission_provenance.dart';
import '../models/support_permission_scope.dart';
import '../models/support_provider_action_values.dart';
import '../models/support_provider_values.dart';
import 'support_authorization_service.dart';

export '../models/support_provider_action_values.dart';
export '../models/support_provider_values.dart';

part '../models/support_provider_action_handles.dart';
part 'support_provider_action_authority.dart';
part 'support_provider_action_projection.dart';
part 'support_provider_action_preparation.dart';
part 'support_provider_action_execution.dart';

/// Trusted constructor composition only. No text dispatcher, secret input,
/// native vault, ApiConfig hydration, HTTP, target assignment or probe surface.
final class SupportProviderActionService {
  SupportProviderActionService({
    required this.apiRepo,
    required this.setupRepo,
    required this.routePolicy,
    required this.currentPermissions,
    required this.currentLocalContext,
    required this.readPermissions,
    required this.currentRedactor,
    required this.isOriginalScopeCurrent,
    required this.readConnectionIds,
    required this.readReadiness,
    String Function()? newOperationId,
    int Function()? now,
  }) : _newOperationId = newOperationId ?? _operationId,
       _now = now ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch) {
    _authorization = SupportAuthorizationService(
      readPolicy: _readLocalPolicy,
      currentNativeContext: currentLocalContext,
      allowsUse: (use) => use == SupportPermissionUse.localRead && _alive,
    );
  }

  final ApiConfigRepo apiRepo;
  final SupportProviderSetupRepo setupRepo;
  final NativeProviderRoutePolicy routePolicy;
  final SupportPermissionSnapshot Function() currentPermissions;

  /// ORIGINAL local session/scope epoch, recipient MUST be null. Root advances
  /// it before local consent/scope changes, not on N1 recipient/redactor fences.
  final SupportNativePermissionContext Function() currentLocalContext;
  final Future<SupportPermissionSnapshot> Function(String) readPermissions;
  final SecretRedactor Function() currentRedactor;
  final bool Function() isOriginalScopeCurrent;

  /// Root's secret-free repository-owned ID projection, never model/tool IDs or
  /// ApiConfig.getAll hydration. Invoked only under local connections read grant.
  final Future<List<String>> Function(bool Function() isCurrent)
  readConnectionIds;

  /// Trusted metadata ONLY. Count is Unicode runes of the key, not record JSON.
  /// Root must read protected metadata/register its current redactor BEFORE any
  /// saved-row display. Unavailable/corrupt is null, never fabricated absence.
  /// Callback must recheck the supplied guard after every await. No test/resolver.
  final Future<SupportProviderReadiness?> Function(
    String connectionId,
    SupportProviderPurpose purpose,
    bool Function() isCurrent,
  )
  readReadiness;
  final String Function() _newOperationId;
  final int Function() _now;
  late final SupportAuthorizationService _authorization;
  final _custom = Expando<SupportProviderCustomDestinationConfirmation>();
  Object _issuer = Object();
  Object? _pending;
  bool _alive = true;

  SupportProviderUiIntent? emit({
    required Object controller,
    required Object uiLifetime,
    required bool Function() isCurrent,
  }) {
    try {
      final c = currentLocalContext();
      final p = _localPolicy(currentPermissions(), c);
      if (p == null) return null;
      final b = _ProviderBinding(this, controller, uiLifetime, isCurrent, c, p);
      return _current(b) ? SupportProviderUiIntent._(b) : null;
    } catch (_) {
      return null;
    }
  }

  void retireIntents() => _issuer = Object();
  void dispose() {
    _alive = false;
    retireIntents();
  }

  SupportProviderSetupPreview? projectReview(SupportProviderReview review) {
    final b = review._binding;
    if (!_current(b)) return null;
    final projected = _projectExact(review);
    return _current(b) ? projected : null;
  }

  /// Native gesture ONLY; no public JSON/boolean can manufacture this receipt.
  SupportProviderCustomDestinationConfirmation? confirmCustomDestination(
    SupportProviderReview review,
  ) {
    if (review._closed ||
        _custom[review] != null ||
        review.destinationKind != SupportProviderDestinationKind.customHttps ||
        !_current(review._binding, changes: true) ||
        projectReview(review) == null) {
      return null;
    }
    final confirmation = SupportProviderCustomDestinationConfirmation._(review);
    if (!_current(review._binding, changes: true) ||
        review._closed ||
        _custom[review] != null) {
      return null;
    }
    _custom[review] = confirmation;
    return confirmation;
  }

  /// Final separate native Apply/Undo gesture. UI must call execute immediately,
  /// BEFORE any notification, await, modal transition or reentrant callback.
  SupportProviderApproval? approve(SupportProviderReview review) {
    if (review._closed || !_admission(review) || review._closed) return null;
    review._closed = true;
    return SupportProviderApproval._(review);
  }

  void cancel(SupportProviderReview review) {
    if (identical(review._binding.service, this)) {
      review._closed = true;
      review._cancelled = true;
    }
  }

  SupportProviderActionView? projectResult(SupportProviderActionResult result) {
    if (!_current(result._review._binding)) return null;
    final preview = _projectExact(result._review);
    return _current(result._review._binding) && preview != null
        ? SupportProviderActionView(code: result.code, preview: preview)
        : null;
  }

  /// Eligibility for a CONDITIONAL update Undo, not a promise that it will win
  /// CAS. Create Undo deliberately unavailable without complete root proof.
  bool canUndo(SupportProviderApplied applied) {
    try {
      final observation = applied._undoObservation;
      return !applied._undoUsed &&
          applied._review.kind == SupportProviderActionKind.update &&
          applied._receipt.status == SupportMutationStatus.applied &&
          _current(applied._binding, changes: true) &&
          observation != null &&
          observation.nativeOwned &&
          apiRepo.sameKeylessObservation(observation, observation) &&
          _current(applied._binding, changes: true);
    } catch (_) {
      return false;
    }
  }

  static String _operationId() {
    final random = Random.secure();
    return 'provider-${List.generate(16, (_) => random.nextInt(256)).map((v) => v.toRadixString(16).padLeft(2, '0')).join()}';
  }
}
