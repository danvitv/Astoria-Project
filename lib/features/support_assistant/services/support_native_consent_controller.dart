import '../../../core/models/support_consent_selection.dart';
import '../models/support_native_view.dart';
import '../models/support_permission_preferences.dart';
import '../models/support_permission_scope.dart';
import '../models/support_recipient_resolution.dart';
import 'support_native_runtime.dart';

part 'support_native_selection_intents.dart';

/// Private issuer-owned anchor, minted atomically with the emitted view. Grant
/// revision/lease epoch are deliberately absent: same-binding edits can merge.
final class _DisplayedIntent implements SupportNativeDisplayedIntent {
  _DisplayedIntent(
    this._issuer,
    this._issuerLifetime,
    this._session,
    this._owner,
    this._lifetime,
    this._configuration,
    this._availability,
    this._policy,
  );
  final SupportNativeConsentController _issuer;
  final String _session;
  final int _issuerLifetime, _owner, _lifetime, _configuration;
  final SupportPermissionAvailability _availability;
  final SupportPermissionPreferences? _policy;
}

/// Opaque native review. Persisted JSON/text cannot mint this intent issuer.
final class SupportNativeReview {
  SupportNativeReview._(
    this._issuer,
    this._issuerLifetime,
    this._owner,
    this._lifetime,
    this._policy,
    this.view,
  );
  final SupportNativeConsentController _issuer;
  final int _issuerLifetime;
  final int _owner;
  final int _lifetime;
  final SupportPermissionPreferences? _policy;
  final SupportNativeView view;
}

/// Bounded native intents only. No generic command parser or tool exposure.
final class SupportNativeConsentController {
  SupportNativeConsentController({
    required this.runtime,
    required this.readMessages,
  });
  final SupportNativeRuntime runtime;
  final SupportNativeMessageReader readMessages;
  int _issuerLifetime = 1;

  /// Retire emitted intents when this UI controller is replaced, including an
  /// already admitted write. Does not invalidate a replacement controller's
  /// runtime or cancel unrelated grant merges under this same live issuer.
  void invalidateDisplayedIntents() => _issuerLifetime++;

  SupportNativeView get view => _buildView();

  SupportNativeView _buildView({bool includeInspection = true}) {
    runtime.checkConfiguration();
    final p = runtime.snapshot.preferences;
    final contextAvailable = runtime.alive && runtime.configurationStable();
    final busy = runtime.pending > 0 || !runtime.configurationStable();
    return SupportNativeView(
      sessionId: runtime.sessionId,
      availability: contextAvailable
          ? runtime.snapshot.availability
          : SupportPermissionAvailability.unavailable,
      busy: busy,
      displayedIntent: _DisplayedIntent(
        this,
        _issuerLifetime,
        runtime.sessionId,
        runtime.writeOwner,
        runtime.lifetime,
        runtime.configurationRevision(),
        runtime.snapshot.availability,
        p,
      ),
      recipient: runtime.recipient,
      needsRecipientConfirmation: !runtime.recipientConfirmed,
      gameSessionId: p?.scope?.gameSessionId,
      gameMessageCount: p?.scope?.gameHistory?.messageIds.length ?? 0,
      supportMessageCount: p?.scope?.supportHistory?.messageIds.length ?? 0,
      connectionsSelected:
          p?.scope?.safeCategories.contains(SupportSafeCategory.connections) ==
          true,
      themeSelected:
          p?.scope?.safeCategories.contains(SupportSafeCategory.theme) == true,
      rights: SupportPermission.values.map((right) {
        final available =
            contextAvailable &&
            !busy &&
            runtime.snapshot.isAvailable &&
            runtime.settingsPending == 0 &&
            p!.hasScopeFor(right) &&
            _implementedSelection(right, p.scope) &&
            (right != SupportPermission.readSafeSettings ||
                p.scope!.safeCategories.any(_implementedSafeCategory)) &&
            (right != SupportPermission.modelSafeSettingsDiagnostics ||
                p.scope!.safeCategories.contains(
                  SupportSafeCategory.connections,
                )) &&
            (!_recipientDependent(right) || runtime.recipientConfirmed);
        return SupportNativeRightView(
          right,
          contextAvailable &&
              p?.allows(right) == true &&
              (!_recipientDependent(right) || runtime.recipientConfirmed),
          available,
          available
              ? null
              : 'Сначала явно выбери доступную область и получателя; загрузчики личных категорий ещё недоступны.',
        );
      }),
      error: runtime.error,
      inspection: includeInspection ? runtime.inspection : null,
    );
  }

  /// Synchronous pre-admission check of the actual emitted snapshot, not live
  /// values reconstructed by a widget. No resolver, DB read or write is started.
  bool isDisplayedIntentCurrent(SupportNativeDisplayedIntent? intent) {
    runtime.checkConfiguration();
    if (intent is! _DisplayedIntent ||
        !identical(intent._issuer, this) ||
        intent._issuerLifetime != _issuerLifetime) {
      return false;
    }
    final a = intent._policy, b = runtime.snapshot.preferences;
    return runtime.owns(intent._session, intent._owner) &&
        runtime.lifetime == intent._lifetime &&
        runtime.configurationRevision() == intent._configuration &&
        runtime.configurationStable() &&
        runtime.pending == 0 &&
        runtime.settingsPending == 0 &&
        runtime.snapshot.availability == intent._availability &&
        a?.policyIdentity == b?.policyIdentity &&
        (a?.scope == null ? b?.scope == null : a!.scope!.sameAs(b?.scope)) &&
        (a?.recipient == null
            ? b?.recipient == null
            : a!.recipient!.sameAs(b?.recipient));
  }

  /// Local scope/read reviews skip recipient/settings/API resolution explicitly.
  /// This does not relax recipient-dependent grants or their resolver checkpoints.
  Future<SupportNativeReview?> prepareReview({
    SupportNativeDisplayedIntent? displayedIntent,
    bool resolveRecipient = true,
  }) async {
    runtime.checkConfiguration();
    if (!runtime.alive ||
        runtime.pending > 0 ||
        (displayedIntent != null &&
            !isDisplayedIntentCurrent(displayedIntent))) {
      return null;
    }
    final lifetime = runtime.lifetime, id = runtime.sessionId;
    if (!await runtime.refresh(resolve: resolveRecipient)) return null;
    if (!runtime.alive ||
        runtime.pending > 0 ||
        runtime.sessionId.isEmpty ||
        lifetime != runtime.lifetime ||
        id != runtime.sessionId ||
        (displayedIntent != null &&
            !isDisplayedIntentCurrent(displayedIntent))) {
      return null;
    }
    return SupportNativeReview._(
      this,
      _issuerLifetime,
      runtime.writeOwner,
      runtime.lifetime,
      runtime.snapshot.preferences,
      _buildView(includeInspection: false),
    );
  }

  bool _issuerCurrent(SupportNativeReview review) =>
      identical(review._issuer, this) &&
      review._issuerLifetime == _issuerLifetime;

  bool _current(SupportNativeReview review) {
    runtime.checkConfiguration();
    return _issuerCurrent(review) &&
        runtime.configurationStable() &&
        runtime.settingsPending == 0 &&
        runtime.lifetime == review._lifetime &&
        runtime.owns(review.view.sessionId, review._owner);
  }

  void cancelReview() => runtime.invalidateBindings();

  Future<bool> setGrant(
    SupportNativeReview review,
    SupportPermission right,
    bool enabled,
  ) async {
    if (!_current(review) || review._policy == null) return false;
    if (enabled &&
        (!review.view.rights.firstWhere((v) => v.right == right).available ||
            !_implementedSelection(right, review._policy.scope))) {
      return false;
    }
    // Independent queued toggles fence data, NOT other admitted write owners.
    runtime.invalidateLease();
    if (enabled && _recipientDependent(right)) {
      final result = await runtime.resolveRecipient(review.view.sessionId);
      if (!_current(review) ||
          !runtime.recipientConfirmed ||
          result is! SupportResolvedRecipient ||
          !result.recipient.sameAs(review._policy.recipient)) {
        return false;
      }
    }
    final success = await _write(
      review,
      () => enabled
          ? runtime.permissions.changeReviewedFromNative(
              review._policy,
              change: (p) => p.withNativeGrant(right, true),
              isCurrent: () => _current(review),
            )
          : runtime.permissions.setGrantFromNative(
              review.view.sessionId,
              right,
              false,
              isCurrent: () => _current(review),
            ),
    );
    if (!success || !enabled || !_recipientDependent(right)) return success;
    final stamp = runtime.writeOwner;
    final result = await runtime.resolveRecipient(review.view.sessionId);
    if (!_current(review) ||
        stamp != runtime.writeOwner ||
        result is! SupportResolvedRecipient ||
        !result.recipient.sameAs(review._policy.recipient)) {
      // Settings and permission rows are separate transactions. Never promote a
      // saved prerequisite into current authority after recipient-check failure.
      runtime.invalidateBindings();
      return false;
    }
    return true;
  }

  Future<bool> confirmRecipient(SupportNativeReview review) async {
    if (!_current(review) ||
        review._policy == null ||
        review.view.recipient is! SupportResolvedRecipient) {
      return false;
    }
    final reviewed =
        (review.view.recipient as SupportResolvedRecipient).recipient;
    review = _admitBinding(review);
    final result = await runtime.resolveRecipient(review.view.sessionId);
    if (!_current(review) ||
        result is! SupportResolvedRecipient ||
        !reviewed.sameAs(result.recipient)) {
      return false;
    }
    final success = await _write(
      review,
      () => runtime.permissions.changeReviewedFromNative(
        review._policy!,
        change: (p) => p.withNativeRecipient(reviewed),
        isCurrent: () => _current(review),
      ),
    );
    // Own recipient observation during _write's awaited refresh may advance the
    // write owner. Keep the ORIGINAL issuer, not the pre-refresh owner, here.
    if (!success || !_issuerCurrent(review)) return false;
    runtime.checkConfiguration();
    if (runtime.alive &&
        runtime.configurationStable() &&
        runtime.settingsPending == 0 &&
        runtime.lifetime == review._lifetime &&
        runtime.sessionId == review.view.sessionId &&
        reviewed.sameAs(runtime.snapshot.preferences?.recipient)) {
      // A fresh resolver checkpoint after durable write; no stale saved descriptor hydration.
      final stamp = runtime.writeOwner;
      final current = await runtime.resolveRecipient(review.view.sessionId);
      // A retired completion only denies; it must not cancel replacement work.
      if (!_issuerCurrent(review)) return false;
      runtime.checkConfiguration();
      if (runtime.owns(review.view.sessionId, stamp) &&
          runtime.lifetime == review._lifetime &&
          runtime.configurationStable() &&
          runtime.settingsPending == 0 &&
          reviewed.sameAs(runtime.snapshot.preferences?.recipient) &&
          current is SupportResolvedRecipient &&
          reviewed.sameAs(current.recipient)) {
        runtime.recipient = current;
        runtime.recipientConfirmed = true;
        runtime.notify();
        return true;
      }
    }
    return false;
  }

  Future<bool> recoverToDeny(
    SupportNativeReview review, {
    required bool confirmed,
  }) {
    if (!confirmed ||
        !_current(review) ||
        review.view.availability != SupportPermissionAvailability.corrupt) {
      return Future.value(false);
    }
    review = _admitBinding(review);
    return _write(
      review,
      () => runtime.permissions.recoverToDenyFromNative(
        review.view.sessionId,
        confirmed: true,
        isCurrent: () => _current(review),
      ),
    );
  }

  SupportNativeReview _admitBinding(SupportNativeReview review) {
    runtime.invalidateBindings();
    return SupportNativeReview._(
      this,
      review._issuerLifetime,
      runtime.writeOwner,
      runtime.lifetime,
      review._policy,
      review.view,
    );
  }

  Future<bool> _write(
    SupportNativeReview review,
    Future<SupportPermissionPreferences?> Function() write,
  ) async {
    runtime.pending++;
    runtime.error = null;
    runtime.notify();
    var success = false;
    try {
      success = await write() != null && _current(review);
    } catch (_) {
      if (_current(review)) {
        runtime.error = 'Не удалось сохранить разрешения. Повтори проверку.';
      }
    } finally {
      runtime.pending--;
      if (runtime.alive && runtime.sessionId == review.view.sessionId) {
        await runtime.refresh();
      }
      runtime.notify();
    }
    return success;
  }

  static bool _implementedSafeCategory(SupportSafeCategory category) =>
      category == SupportSafeCategory.connections ||
      category == SupportSafeCategory.theme;

  static bool _implementedSelection(
    SupportPermission right,
    SupportPermissionScope? scope,
  ) {
    // The local game reader implements exact history only, not the broader
    // selected-data scope accepted by the generic permission policy.
    if (right == SupportPermission.readGameData) {
      return scope != null &&
          scope.gameSessionId?.isNotEmpty == true &&
          scope.gameHistory != null &&
          scope.selectedData.isEmpty;
    }
    return !{
      SupportPermission.readDiagnostics,
      SupportPermission.modelGameData,
      SupportPermission.modelPromptProviderSnippets,
      SupportPermission.modelAttachments,
      SupportPermission.reportPersonalDataAttachments,
    }.contains(right);
  }

  static bool _recipientDependent(SupportPermission right) => {
    SupportPermission.modelGameHistory,
    SupportPermission.modelSupportHistory,
    SupportPermission.modelSafeSettingsDiagnostics,
    SupportPermission.modelGameData,
    SupportPermission.modelPromptProviderSnippets,
    SupportPermission.modelAttachments,
    SupportPermission.confirmedConnectionTests,
  }.contains(right);
}
