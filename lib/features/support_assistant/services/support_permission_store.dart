import 'dart:convert';
import 'dart:math';
import '../../../core/db/repositories/support_repo.dart';
import '../../../core/models/support_models.dart';
import '../../../core/support/support_payload_cipher.dart';
import '../models/support_permission_preferences.dart';
import '../models/support_permission_scope.dart';
import 'support_permission_codec.dart';

/// Trusted native composition ONLY: never expose these methods in a tool,
/// imported card, model response or text-command registry. SupportRepo owns
/// synchronous latest-row decisions, encryption, parent checks and rollback.
final class SupportPermissionStore {
  SupportPermissionStore(
    this.repo, {
    String Function()? newIdentity,
    int Function()? now,
  }) : _newIdentity = newIdentity ?? _randomIdentity,
       _now = now ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch);
  final SupportRepo repo;
  final String Function() _newIdentity;
  final int Function() _now;
  static const codec = SupportPermissionCodec();

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
      final p = codec.decode(
        sessionId,
        await repo.getContextBlockById(codec.idFor(sessionId)),
      );
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
  }) => _update(sessionId, (p) => p.withNativeGrant(right, enabled), isCurrent);

  Future<SupportPermissionPreferences?> selectScopeFromNative(
    String sessionId,
    SupportPermissionScope? scope, {
    required bool Function() isCurrent,
  }) => _update(sessionId, (p) => p.withNativeScope(scope), isCurrent);

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
    final current = codec.decode(reviewed.supportSessionId, latest);
    if (current.policyIdentity != reviewed.policyIdentity ||
        !_sameScope(current.scope, reviewed.scope) ||
        !_sameRecipient(current.recipient, reviewed.recipient)) {
      return null;
    }
    final base = latest == null
        ? _freshDeny(reviewed.supportSessionId)
        : current;
    return codec.encode(change(base), latest?.createdAt ?? _now());
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
        codec.decode(sessionId, latest);
        throw StateError('Permissions do not need recovery.');
      } on SupportPermissionsUnavailable catch (e) {
        if (e.availability != SupportPermissionAvailability.corrupt) rethrow;
      }
      return codec.encode(_freshDeny(sessionId, revision: 1), latest.createdAt);
    }, isCurrent);
  }

  Future<SupportPermissionPreferences?> _update(
    String sessionId,
    SupportPermissionPreferences Function(SupportPermissionPreferences) update,
    bool Function() isCurrent,
  ) => _mutate(sessionId, (latest) {
    final p = latest == null
        ? _freshDeny(sessionId)
        : codec.decode(sessionId, latest);
    return codec.encode(update(p), latest?.createdAt ?? _now());
  }, isCurrent);

  Future<SupportPermissionPreferences?> _mutate(
    String sessionId,
    SupportContextBlock? Function(SupportContextBlock?) change,
    bool Function() isCurrent,
  ) async {
    try {
      final durable = await repo.mutateContextBlock(
        blockId: codec.idFor(sessionId),
        sessionId: sessionId,
        mutate: change,
        isCurrent: isCurrent,
      );
      if (!isCurrent() || durable == null) return null;
      return codec.decode(sessionId, durable);
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
