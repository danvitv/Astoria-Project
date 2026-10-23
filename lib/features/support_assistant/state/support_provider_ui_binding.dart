import '../../../core/credentials/native_provider_credentials.dart';
import '../../../core/credentials/secret_redaction_coordinator.dart';
import '../../../core/db/repositories/api_config_repo.dart';
import '../../../core/models/keyless_api_config.dart';
import '../../../core/state/native_provider_runtime.dart';
import '../models/support_permission_preferences.dart';
import '../services/support_native_consent_controller.dart';
import '../services/support_native_runtime.dart';
import '../services/support_provider_action_service.dart';

export '../services/support_provider_action_service.dart';

part 'support_provider_key_entry.dart';

/// UI custody for ONE actual controller/local anchor. Busy state never revokes
/// its own started operation; receipts/futures are not recovered from strings.
final class SupportProviderUiBinding {
  SupportProviderUiBinding({
    required this._controller,
    required this._service,
    required this._native,
    required this._api,
    required this._redaction,
    required this._isOriginalUi,
  }) {
    _anchor = _controller.captureLocalDisplayedIntent();
    _intent = _service.emit(
      controller: _controller,
      uiLifetime: _lifetime,
      isCurrent: () => current,
    );
  }
  final SupportNativeConsentController _controller;
  final SupportProviderActionService _service;
  final NativeProviderRuntime _native;
  final ApiConfigRepo _api;
  final SecretRedactionCoordinator _redaction;
  final bool Function() _isOriginalUi;
  final _lifetime = Object();
  final _handles = Expando<bool>();
  final _reviews = Expando<bool>();
  SupportNativeLocalDisplayedIntent? _anchor;
  SupportProviderUiIntent? _intent;
  bool _disposed = false, _confirming = false;

  bool get current {
    bool exact() =>
        !_disposed &&
        _native.isCurrent &&
        _controller.isLocalDisplayedIntentCurrent(_anchor);
    if (!exact()) return false;
    try {
      return _isOriginalUi() && exact();
    } catch (_) {
      return false;
    }
  }

  Future<SupportProviderConnections?> observe(
    SupportProviderPurpose purpose,
  ) async {
    final intent = _intent;
    if (!current || intent == null) return null;
    final connections = await _service.observeConnections(intent, purpose);
    if (!current || connections == null) return null;
    for (final handle in connections.choices) {
      _handles[handle] = true;
    }
    return connections;
  }

  Future<SupportProviderReview?> prepare(
    SupportProviderSetupInput input, {
    SupportProviderChoice? updating,
  }) async {
    final intent = _intent;
    if (!current ||
        intent == null ||
        _confirming ||
        (updating != null && _handles[updating] != true)) {
      return null;
    }
    final review = updating == null
        ? await _service.prepareCreate(intent, input)
        : await _service.prepareUpdate(updating, input);
    if (!current || review == null) return null;
    _reviews[review] = true;
    return review;
  }

  SupportProviderSetupPreview? preview(SupportProviderReview review) =>
      current && _reviews[review] == true
      ? _service.projectReview(review)
      : null;

  bool confirmCustomDestination(SupportProviderReview review) =>
      current &&
      _reviews[review] == true &&
      _service.confirmCustomDestination(review) != null;

  void cancel(SupportProviderReview review) {
    if (_reviews[review] == true) _service.cancel(review);
  }

  /// Final gesture: approve -> execute before ANY notification or await. Claim
  /// the UI latch before approval callbacks can reenter it.
  Future<SupportProviderActionResult>? confirm(SupportProviderReview review) {
    if (!current || _confirming || _reviews[review] != true) return null;
    _confirming = true;
    final approval = _service.approve(review);
    if (approval == null) {
      _confirming = false;
      return null;
    }
    final original = _service.execute(approval);
    return _finishOriginal(original);
  }

  Future<SupportProviderActionResult> _finishOriginal(
    Future<SupportProviderActionResult> original,
  ) async {
    try {
      final result = await original;
      if (current && result.applied != null) _handles[result.applied!] = true;
      return result; // Actual original fact survives disposal, never a new job.
    } finally {
      _confirming = false;
    }
  }

  SupportProviderActionView? resultView(SupportProviderActionResult result) =>
      current ? _service.projectResult(result) : null;

  Future<SupportProviderReadiness?> readiness(
    SupportProviderConnectionHandle handle,
  ) => current && _handles[handle] == true
      ? _service.projectReadiness(handle)
      : Future.value();

  bool canUndo(SupportProviderApplied applied) =>
      current && _handles[applied] == true && _service.canUndo(applied);

  Future<SupportProviderReview?> prepareUndo(
    SupportProviderApplied applied,
  ) async {
    final intent = _intent;
    if (intent == null || !canUndo(applied)) return null;
    final review = await _service.prepareUndo(intent, applied);
    if (!current || review == null) return null;
    _reviews[review] = true;
    return review;
  }

  /// Native secret-entry adapter only; not an assistant tool/card/data gateway.
  Future<SupportProviderNativeKeyEntry?> prepareKeyEntry(
    SupportProviderConnectionHandle handle,
  ) async {
    if (!current || _handles[handle] != true || handle.value == null) {
      return null;
    }
    final before = handle.value!;
    final stamp = _native.mutations.observe();
    if (stamp == null || !await _freshLocalChanges() || !current) return null;
    bool guard() =>
        current && handle.value != null && _native.mutations.isCurrent(stamp);
    final facts = await _native.credentialReader.readConfiguration(
      connectionId: before.connectionId,
      isCurrent: guard,
    );
    if (!guard() || !facts.nativeManaged || facts.metadata == null) return null;
    final observed = await _api.inspectKeyless(before.connectionId);
    if (!guard() || observed == null || !_sameValue(before, observed.view)) {
      return null;
    }
    final saved = await _api.getById(before.connectionId);
    if (!guard() || saved == null) return null;
    final purpose = NativeProviderPurpose.values.byName(handle.purpose.name);
    final auth = _native.auth.referenceFor(saved, purpose);
    if (!guard() || auth == null) return null;
    if (facts.metadata!.configured) {
      final access = await _native.credentialReader.inspectSavedConnection(
        connection: auth,
        isCurrent: guard,
      );
      if (!guard() || access.state != NativeProviderCredentialState.ready) {
        return null;
      }
    }
    final entry = SupportProviderNativeKeyEntry._(this, handle, auth);
    return await entry._prepare() && current ? entry : null;
  }

  Future<bool> _freshLocalChanges() async {
    if (!current) return false;
    final before = _controller.runtime.localContext;
    final fresh = await _controller.runtime.permissions.readForNative(
      before.supportSessionId,
    );
    final p = fresh.preferences;
    return current &&
        before.sameAs(_controller.runtime.localContext) &&
        p != null &&
        p.policyIdentity ==
            _controller
                .runtime
                .localPermissionSnapshot
                .preferences
                ?.policyIdentity &&
        p.scope?.sameAs(before.scope) == true &&
        p.allows(SupportPermission.readSafeSettings) &&
        p.allows(SupportPermission.confirmedSettingsChanges);
  }

  void dispose() => _disposed = true;
}

bool _sameValue(
  SupportProviderSetupValue display,
  KeylessApiConfigView native,
) =>
    display.connectionId == native.connectionId &&
    display.name == native.displayName &&
    display.protocol == native.protocol &&
    display.endpoint == native.endpoint &&
    display.model == native.model &&
    display.maxTokens == native.maxTokens &&
    display.contextSize == native.contextSize &&
    display.temperature == native.temperature;
