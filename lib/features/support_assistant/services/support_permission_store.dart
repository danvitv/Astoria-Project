import 'dart:convert';
import 'dart:math';
import '../../../core/db/repositories/support_repo.dart';
import '../../../core/models/support_models.dart';
import '../../../core/support/support_payload_cipher.dart';
import '../models/support_permission_preferences.dart';
import '../models/support_permission_scope.dart';
import 'support_permission_codec.dart';

final class _ApplicationDataRevocation {
  bool denied = false;
  bool unsaved = false;
  int revision = 0;
}

/// Trusted native composition ONLY: never expose these methods in a tool,
/// imported card, model response or text-command registry. SupportRepo owns
/// synchronous latest-row decisions, encryption, parent checks and rollback.
final class SupportPermissionStore {
  SupportPermissionStore(
    this.repo, {
    String Function()? newIdentity,
    int Function()? now,
    this.initializeGlobalOnRefresh = false,
  }) : _newIdentity = newIdentity ?? _randomIdentity,
       _now = now ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch);
  final SupportRepo repo;
  final String Function() _newIdentity;
  final int Function() _now;

  /// Production composition opts in; deliberate legacy fixtures stay per-chat.
  final bool initializeGlobalOnRefresh;
  bool _globalRequired = false;
  bool get globalRequired =>
      initializeGlobalOnRefresh || _globalRequired || applicationDataReadDenied;
  static const codec = SupportPermissionCodec();
  // Weakly tied to the actual native storage owner, not a widget, conversation,
  // bridge or repository instance. Failed denial writes cannot resurrect reads
  // through a replacement store/runtime on the same database.
  static final _revocations = Expando<_ApplicationDataRevocation>();
  _ApplicationDataRevocation get _revocation =>
      _revocations[repo.assistantPermissionStorageOwner] ??=
          _ApplicationDataRevocation();
  bool get applicationDataReadDenied => _revocation.denied;
  bool get applicationDataRevocationUnsaved => _revocation.unsaved;
  int get applicationDataRevocationRevision => _revocation.revision;

  /// Native OFF admission only, before any await. This is a denial, not an
  /// authority or permission write. It survives refresh and bridge replacement.
  int latchApplicationDataRevocation() {
    final state = _revocation;
    state.denied = true;
    state.unsaved = true;
    return ++state.revision;
  }

  void settleApplicationDataRevocation(int revision) {
    if (_revocation.revision == revision) _revocation.unsaved = false;
  }

  /// Called only after the current exact native enable review committed. A
  /// review predating another OFF gesture cannot clear that later denial.
  bool confirmApplicationDataConsent(int reviewedRevision) {
    final state = _revocation;
    if (state.revision != reviewedRevision) return false;
    state.denied = false;
    state.unsaved = false;
    state.revision++;
    return true;
  }

  /// Normal native workspace admission only. Existing rows are left unchanged.
  /// Current/chosen policy wins; otherwise newest existing legacy policy wins.
  Future<SupportPermissionPreferences?> initializeGlobalFromNative(
    String sessionId, {
    required bool Function() isCurrent,
  }) async {
    _globalRequired = true;
    try {
      final parent = await repo.getSessionById(sessionId);
      if (!isCurrent()) return null;
      if (parent == null) throw StateError('Support session missing.');
      if (parent.isLocked) {
        throw SupportPermissionsUnavailable(
          SupportPermissionAvailability.locked,
        );
      }
      final existing = await repo.getContextBlockById(
        SupportPermissionCodec.globalId,
      );
      if (!isCurrent()) return null;
      if (existing != null) return codec.decodeGlobal(sessionId, existing);
      final sessions = await repo.getAllSessions();
      if (!isCurrent()) return null;
      sessions.sort((a, b) {
        final updated = b.updatedAt.compareTo(a.updatedAt);
        if (updated != 0) return updated;
        final created = b.createdAt.compareTo(a.createdAt);
        return created != 0 ? created : a.id.compareTo(b.id);
      });
      final block = await repo.initializeAssistantPermissions(
        currentSessionId: sessionId,
        legacySessionIds: [
          sessionId,
          for (final s in sessions)
            if (s.id != sessionId) s.id,
        ],
        create: (legacy) => codec.encodeGlobal(
          legacy == null
              ? _freshDeny(sessionId)
              : codec.decode(legacy.sessionId, legacy),
          _now(),
        ),
        isCurrent: isCurrent,
      );
      if (!isCurrent() || block == null) return null;
      return codec.decodeGlobal(sessionId, block);
    } on SupportPermissionsUnavailable {
      rethrow;
    } on SupportCipherException {
      throw SupportPermissionsUnavailable(SupportPermissionAvailability.locked);
    } catch (_) {
      throw SupportPermissionsUnavailable(
        SupportPermissionAvailability.unavailable,
      );
    }
  }

  Future<SupportPermissionSnapshot> readForNative(String sessionId) async {
    try {
      final parent = await repo.getSessionById(sessionId);
      if (parent == null) {
        return const SupportPermissionSnapshot(
          SupportPermissionAvailability.unavailable,
        );
      }
      if (parent.isLocked) {
        return const SupportPermissionSnapshot(
          SupportPermissionAvailability.locked,
        );
      }
      final global = await repo.getContextBlockById(
        SupportPermissionCodec.globalId,
      );
      if (global == null && globalRequired) {
        throw SupportPermissionsUnavailable(
          SupportPermissionAvailability.unavailable,
        );
      }
      final p = global != null
          ? codec.decodeGlobal(sessionId, global)
          : codec.decode(
              sessionId,
              await repo.getContextBlockById(codec.idFor(sessionId)),
            );
      if (global != null) {
        _globalRequired = true;
        // The parentless row outlives chats. It must not make a deleted/locked
        // current conversation look readable after an awaited global decrypt.
        final latestParent = await repo.getSessionById(sessionId);
        if (latestParent == null) {
          return const SupportPermissionSnapshot(
            SupportPermissionAvailability.unavailable,
          );
        }
        if (latestParent.isLocked) {
          return const SupportPermissionSnapshot(
            SupportPermissionAvailability.locked,
          );
        }
      }
      return SupportPermissionSnapshot(
        SupportPermissionAvailability.available,
        p,
      );
    } on SupportPermissionsUnavailable catch (e) {
      return SupportPermissionSnapshot(e.availability);
    } on SupportCipherException {
      return const SupportPermissionSnapshot(
        SupportPermissionAvailability.locked,
      );
    } catch (_) {
      return const SupportPermissionSnapshot(
        SupportPermissionAvailability.unavailable,
      );
    }
  }

  Future<SupportPermissionPreferences?> setGrantFromNative(
    String sessionId,
    SupportPermission right,
    bool enabled, {
    required bool Function() isCurrent,
  }) async {
    // Broad access never exists in the legacy per-chat storage lane, including
    // fixtures. Revocation pins this store to the global row before any await.
    if (right == SupportPermission.readApplicationData) {
      if (await initializeGlobalFromNative(sessionId, isCurrent: isCurrent) ==
          null) {
        return null;
      }
    }
    return _update(
      sessionId,
      (p) => p.withNativeGrant(right, enabled),
      isCurrent,
    );
  }

  Future<SupportPermissionPreferences?> selectScopeFromNative(
    String sessionId,
    SupportPermissionScope? scope, {
    required bool Function() isCurrent,
  }) => _update(
    sessionId,
    (p) => p.withNativeScope(scope, supportHistorySelected: true),
    isCurrent,
  );

  Future<SupportPermissionPreferences?> selectRecipientFromNative(
    String sessionId,
    SupportPermissionRecipient? recipient, {
    required bool Function() isCurrent,
  }) => _update(sessionId, (p) => p.withNativeRecipient(recipient), isCurrent);

  /// Review identity and exact bindings INSIDE the latest-row transaction.
  /// Grant-only revisions deliberately do not conflict: independent toggles merge.
  /// A missing review may initialize deny/selection only while still missing.
  Future<SupportPermissionPreferences?> changeReviewedFromNative(
    SupportPermissionPreferences reviewed, {
    required SupportPermissionPreferences Function(SupportPermissionPreferences)
    change,
    required bool Function() isCurrent,
  }) => _mutate(reviewed.supportSessionId, (latest) {
    final reviewedMissing =
        reviewed.policyIdentity == 'missing' && reviewed.revision == 0;
    if ((latest == null) != reviewedMissing) return null;
    final current = _decode(reviewed.supportSessionId, latest);
    if (current.policyIdentity != reviewed.policyIdentity ||
        !_sameScope(current.scope, reviewed.scope) ||
        !_sameRecipient(current.recipient, reviewed.recipient) ||
        current.globalSource?.supportSessionId !=
            reviewed.globalSource?.supportSessionId) {
      return null;
    }
    final base = latest == null
        ? _freshDeny(reviewed.supportSessionId)
        : current;
    return _encode(change(base), latest, latest?.createdAt ?? _now());
  }, isCurrent);

  static bool _sameScope(
    SupportPermissionScope? a,
    SupportPermissionScope? b,
  ) => a == null ? b == null : a.sameAs(b);
  static bool _sameRecipient(
    SupportPermissionRecipient? a,
    SupportPermissionRecipient? b,
  ) => a == null ? b == null : a.sameAs(b);

  /// Explicit current-invalid recovery, ONLY to deny with a fresh identity.
  /// Missing, healthy, locked or deleted targets can never be recreated here.
  Future<SupportPermissionPreferences?> recoverToDenyFromNative(
    String sessionId, {
    required bool confirmed,
    required bool Function() isCurrent,
  }) async {
    if (!confirmed) throw StateError('Permission recovery not confirmed.');
    return _mutate(sessionId, (latest) {
      if (latest == null) throw StateError('Permissions do not need recovery.');
      try {
        _decode(sessionId, latest);
        throw StateError('Permissions do not need recovery.');
      } on SupportPermissionsUnavailable catch (e) {
        if (e.availability != SupportPermissionAvailability.corrupt) rethrow;
      }
      return _encode(
        _freshDeny(sessionId, revision: 1),
        latest,
        latest.createdAt,
      );
    }, isCurrent);
  }

  Future<SupportPermissionPreferences?> _update(
    String sessionId,
    SupportPermissionPreferences Function(SupportPermissionPreferences) update,
    bool Function() isCurrent,
  ) => _mutate(sessionId, (latest) {
    final p = latest == null
        ? _freshDeny(sessionId)
        : _decode(sessionId, latest);
    return _encode(update(p), latest, latest?.createdAt ?? _now());
  }, isCurrent);

  Future<SupportPermissionPreferences?> _mutate(
    String sessionId,
    SupportContextBlock? Function(SupportContextBlock?) change,
    bool Function() isCurrent,
  ) async {
    try {
      // Discover only the fixed profile. Every global write then re-reads the
      // latest row in its transaction, across independent store instances. The
      // legacy branch also rejects a global row appearing before its commit.
      final global = await repo.getContextBlockById(
        SupportPermissionCodec.globalId,
      );
      if (!isCurrent()) return null;
      if (global != null) _globalRequired = true;
      if (global == null && globalRequired) {
        throw SupportPermissionsUnavailable(
          SupportPermissionAvailability.unavailable,
        );
      }
      final durable = global != null
          ? await repo.mutateAssistantPermissions(
              currentSessionId: sessionId,
              mutate: change,
              isCurrent: isCurrent,
            )
          : await repo.mutateLegacyAssistantPermissions(
              currentSessionId: sessionId,
              mutate: change,
              isCurrent: isCurrent,
            );
      if (!isCurrent() || durable == null) return null;
      return _decode(sessionId, durable);
    } on SupportPermissionsUnavailable {
      rethrow;
    } on SupportCipherException {
      throw SupportPermissionsUnavailable(SupportPermissionAvailability.locked);
    } catch (_) {
      throw SupportPermissionsUnavailable(
        SupportPermissionAvailability.unavailable,
      );
    }
  }

  SupportPermissionPreferences _decode(
    String sessionId,
    SupportContextBlock? block,
  ) => block?.id == SupportPermissionCodec.globalId
      ? codec.decodeGlobal(sessionId, block!)
      : codec.decode(sessionId, block);
  SupportContextBlock _encode(
    SupportPermissionPreferences p,
    SupportContextBlock? latest,
    int now,
  ) => latest?.id == SupportPermissionCodec.globalId
      ? codec.encodeGlobal(p, now)
      : codec.encode(p, now);

  SupportPermissionPreferences _freshDeny(String id, {int revision = 0}) =>
      SupportPermissionPreferences(
        supportSessionId: id,
        policyIdentity: _newIdentity(),
        revision: revision,
      );
  static String _randomIdentity() {
    final random = Random.secure();
    return base64UrlEncode(
      List.generate(24, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
  }
}
