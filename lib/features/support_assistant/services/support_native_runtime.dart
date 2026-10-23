import '../models/support_native_view.dart';
import '../models/support_permission_preferences.dart';
import '../models/support_permission_provenance.dart';
import '../models/support_recipient_resolution.dart';
import '../models/support_permission_scope.dart';
import 'support_authorization_service.dart';
import 'support_permission_store.dart';

part 'support_native_local_context.dart';

/// Native custody and lease epoch. No Ref, persisted private results or executor.
final class SupportNativeRuntime {
  SupportNativeRuntime({
    required this.permissions,
    required this.resolveRecipient,
    required this.loadSelectedConnection,
    required this.configurationRevision,
    required this.configurationStable,
    this.gameSourceCheckpoint,
    this.gameSourceStable,
  }) {
    _configuration = configurationRevision();
    _configurationWasStable = configurationStable();
    authorization = SupportAuthorizationService(
      readPolicy: permissions.readForNative,
      allowsUse: _allowsUse,
      currentNativeContext: () {
        checkConfiguration();
        final p = snapshot.preferences;
        return SupportNativePermissionContext(
          supportSessionId: sessionId,
          epoch: epoch,
          scope: p?.scope,
          recipient: p?.recipient,
        );
      },
    );
  }
  final SupportPermissionStore permissions;
  final Future<SupportRecipientResolution> Function(String) resolveRecipient;
  final Future<SupportConnectionInspection?> Function(String, bool Function())
  loadSelectedConnection;
  final int Function() configurationRevision;
  final bool Function() configurationStable;
  final void Function()? gameSourceCheckpoint;
  final bool Function()? gameSourceStable;
  late final SupportAuthorizationService authorization;
  String sessionId = '';
  int epoch = 1, writeOwner = 1, lifetime = 1, pending = 0, _reload = 0;
  late int _configuration;
  late bool _configurationWasStable;
  bool alive = true, recipientConfirmed = false;
  int settingsPending = 0;
  int _localEpoch = 1, _localPending = 0;
  Object _localOwner = Object();
  bool _localExhausted = false;
  String? error;
  SupportPermissionSnapshot snapshot = const SupportPermissionSnapshot(
    SupportPermissionAvailability.unavailable,
  );
  SupportRecipientResolution recipient = const SupportRecipientUnavailable(
    SupportRecipientUnavailableReason.selectionMissing,
  );
  SupportConnectionInspection? _inspection;
  final _listeners = <void Function()>{};
  final _gameSourceIntents = <void Function()>{};

  /// Source retirement invalidates UI issuers, not recipient/write ownership or
  /// unrelated queued grant merges. Only the original native controller listens.
  void Function() listenGameSourceRetirement(void Function() listener) {
    if (!alive) return () {};
    _gameSourceIntents.add(listener);
    return () => _gameSourceIntents.remove(listener);
  }

  void retireGameSourceIntents() {
    for (final listener in List.of(_gameSourceIntents)) {
      if (!alive || !_gameSourceIntents.contains(listener)) continue;
      try {
        listener();
      } catch (_) {
        // A UI observer cannot prevent synchronous source-lease retirement.
      }
    }
  }

  void Function() listen(void Function() listener) {
    if (!alive) return () {};
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void notify() {
    if (alive) gameSourceCheckpoint?.call();
    for (final listener in List.of(_listeners)) {
      if (!_listeners.contains(listener)) continue;
      try {
        listener();
      } catch (_) {
        // Native observers cannot abort admitted ordinary or permission writes.
      }
    }
  }

  SupportConnectionInspection? get inspection {
    checkConfiguration();
    return _inspection;
  }

  /// Synchronous observation only: no settings, resolver or API read/refresh.
  void invalidateConfiguration() {
    if (!alive) return;
    _configuration = configurationRevision();
    _configurationWasStable = configurationStable();
    writeOwner++;
    recipientConfirmed = false;
    _clearLease();
    recipient = const SupportRecipientUnavailable(
      SupportRecipientUnavailableReason.staleContext,
    );
    notify();
  }

  void checkConfiguration() {
    if (!alive) return;
    gameSourceCheckpoint?.call();
    if (!alive) return;
    if (_configuration != configurationRevision() ||
        _configurationWasStable != configurationStable()) {
      invalidateConfiguration();
    }
  }

  bool _allowsUse(SupportPermissionUse use) {
    checkConfiguration();
    if (!alive ||
        sessionId.isEmpty ||
        pending > 0 ||
        settingsPending > 0 ||
        !configurationStable() ||
        !snapshot.isAvailable) {
      return false;
    }
    if (use != SupportPermissionUse.modelContext) return true;
    final resolved = recipient;
    return recipientConfirmed &&
        resolved is SupportResolvedRecipient &&
        resolved.context.sameAs(recipientContext) &&
        resolved.recipient.configurationRevision == configurationRevision() &&
        resolved.recipient.sameAs(snapshot.preferences?.recipient);
  }

  /// Lease invalidation is separate from write ownership: independent grants merge.
  void invalidateLease() {
    _clearLease();
    notify();
  }

  void _clearLease() {
    epoch++;
    _inspection = null;
  }

  void invalidateBindings() {
    writeOwner++;
    recipientConfirmed = false;
    invalidateLease();
  }

  /// Separate generation-preferences transaction: deny across the queued edit,
  /// permission clear and failure, not just its admission.
  void Function() beginSettingsChange() {
    settingsPending++;
    pending++;
    invalidateBindings();
    var settled = false;
    return () {
      if (settled) return;
      settled = true;
      settingsPending--;
      pending--;
      invalidateLease();
    };
  }

  void selectSession(String id, {bool force = false}) {
    if (!force && id == sessionId) return;
    _retireLocalOwner();
    invalidateBindings();
    lifetime++;
    sessionId = id;
    snapshot = const SupportPermissionSnapshot(
      SupportPermissionAvailability.unavailable,
    );
    recipient = const SupportRecipientUnavailable(
      SupportRecipientUnavailableReason.selectionMissing,
    );
    error = null;
    notify();
  }

  SupportRecipientContext? get recipientContext => alive && sessionId.isNotEmpty
      // Recipient-review ownership is not the data-lease epoch. Independent
      // grants fence prepared data without cancelling another native toggle.
      ? SupportRecipientContext(supportSessionId: sessionId, epoch: writeOwner)
      : null;
  bool _ownsBinding(String id, int owner) =>
      alive && sessionId == id && writeOwner == owner;

  bool owns(String id, int owner) {
    if (alive) gameSourceCheckpoint?.call();
    return _ownsBinding(id, owner) &&
        // Settings already fence all native consent admission. Their ORIGINAL
        // queued finally still owns recipient clearing; source stability must
        // not suppress that independent deny write or replace its custody.
        (settingsPending > 0 || (gameSourceStable?.call() ?? true));
  }

  Future<bool> refresh({bool resolve = false}) async {
    checkConfiguration();
    final id = sessionId, owner = writeOwner, serial = ++_reload;
    if (!alive || id.isEmpty) return false;
    final next = await permissions.readForNative(id);
    checkConfiguration();
    // Permission observation can remove/switch the selected game source while
    // it is pending. It does not grant admission or renew any old data epoch.
    if (!_ownsBinding(id, owner) || serial != _reload) {
      return false;
    }
    final a = snapshot.preferences, b = next.preferences;
    _reconcileLocalSnapshot(next);
    if (a?.policyIdentity != b?.policyIdentity ||
        a?.revision != b?.revision ||
        snapshot.availability != next.availability) {
      invalidateLease();
      if (a?.policyIdentity != b?.policyIdentity ||
          !(a?.scope == null ? b?.scope == null : a!.scope!.sameAs(b?.scope)) ||
          !(a?.recipient == null
              ? b?.recipient == null
              : a!.recipient!.sameAs(b?.recipient))) {
        // Durable observer changes invalidate dialogs, not unrelated grant revisions.
        writeOwner++;
        recipientConfirmed = false;
      }
    }
    snapshot = next;
    if (resolve) {
      final stamp = epoch;
      final result = await resolveRecipient(id);
      if (!alive || id != sessionId || stamp != epoch || serial != _reload) {
        return false;
      }
      recipient = result;
      if (result is! SupportResolvedRecipient ||
          !result.recipient.sameAs(snapshot.preferences?.recipient)) {
        recipientConfirmed = false;
      }
    }
    notify();
    return true;
  }

  /// Actual offline path. Denial happens before recipient/settings/API metadata loads.
  Future<bool> inspectSelectedConnection(
    String id,
    bool Function() isCurrent,
  ) async {
    _inspection = null;
    if (!alive || id != sessionId || !isCurrent()) return false;
    final admissionLifetime = lifetime;
    if (!await refresh()) return false;
    if (!alive ||
        lifetime != admissionLifetime ||
        id != sessionId ||
        !isCurrent() ||
        pending > 0 ||
        !configurationStable() ||
        snapshot.preferences?.allows(SupportPermission.readSafeSettings) !=
            true ||
        snapshot.preferences?.scope?.safeCategories.contains(
              SupportSafeCategory.connections,
            ) !=
            true) {
      return false;
    }
    checkConfiguration();
    final stamp = epoch, revision = configurationRevision();
    bool current() =>
        alive &&
        id == sessionId &&
        stamp == epoch &&
        revision == configurationRevision() &&
        configurationStable() &&
        isCurrent();
    final lease = await authorization.prepare(
      supportSessionId: id,
      use: SupportPermissionUse.localRead,
      sources: [
        SupportPermissionSource.safeProjection(
          id,
          SupportSafeCategory.connections,
        ),
      ],
    );
    if (lease == null || !current()) return false;
    try {
      final data = await authorization.loadLocal(lease, () async {
        if (!current()) throw SupportAuthorizationDenied();
        final selected = await loadSelectedConnection(id, current);
        if (!current() || selected == null) throw SupportAuthorizationDenied();
        return selected;
      });
      await authorization.consume(lease, data, (value) {
        if (current()) {
          _inspection = value;
          notify();
        }
      });
      return current() && _inspection != null;
    } on SupportAuthorizationDenied {
      return false;
    }
  }

  void dispose() {
    if (!alive) return;
    _retireLocalOwner();
    alive = false;
    lifetime++;
    writeOwner++;
    recipientConfirmed = false;
    _clearLease();
    snapshot = const SupportPermissionSnapshot(
      SupportPermissionAvailability.unavailable,
    );
    recipient = const SupportRecipientUnavailable(
      SupportRecipientUnavailableReason.staleContext,
    );
    notify();
    _listeners.clear();
    _gameSourceIntents.clear();
  }
}
