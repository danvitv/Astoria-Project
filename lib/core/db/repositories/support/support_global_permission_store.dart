part of '../support_repo.dart';

/// Only this fixed encrypted singleton may have no conversation parent. Normal
/// context creation, message ranges and real-chat cascades remain unchanged.
final class _SupportGlobalPermissionStore {
  _SupportGlobalPermissionStore(this.context);
  final _SupportContextStore context;

  Future<SupportContextBlock?> initialize(
    String currentSessionId,
    List<String> legacySessionIds,
    SupportContextBlock Function(SupportContextBlock?) create,
    bool Function() current,
  ) => context.db.transaction(() async {
    if (!current()) return null;
    await context.sessions.requireParent(currentSessionId);
    if (!current()) return null;
    final existing = await context.get(SupportRepo.assistantPermissionsId);
    if (!current()) return null;
    if (existing != null) {
      _validate(existing);
      return existing;
    }
    SupportContextBlock? legacy;
    for (final sessionId in legacySessionIds) {
      if (sessionId.isEmpty) throw StateError('Invalid legacy policy parent.');
      final found = await context.get('workspace-permissions-v1:$sessionId');
      if (!current()) return null;
      if (found == null) continue;
      _requireSameSession(found.sessionId, sessionId);
      await context.sessions.requireParent(sessionId);
      if (!current()) return null;
      _requireUnlocked(found.isLocked);
      legacy = found;
      break;
    }
    final next = create(
      legacy,
    ); // Corrupt source throws; never skip to a default.
    if (!current()) return null;
    _validate(next);
    return context.write(next, isCurrent: current, requireReadableResult: true);
  });

  Future<SupportContextBlock?> mutate(
    String sessionId,
    SupportContextBlock? Function(SupportContextBlock) change,
    bool Function() current,
  ) => context.db.transaction(() async {
    if (!current()) return null;
    await context.sessions.requireParent(sessionId);
    if (!current()) return null;
    final latest = await context.get(SupportRepo.assistantPermissionsId);
    if (!current()) return null;
    // Missing here is unavailable, not permission to recreate/reset a profile.
    if (latest == null) throw StateError('Global permissions not initialized.');
    _validate(latest);
    final next = change(latest);
    if (next == null || !current()) return null;
    _validate(next);
    return context.write(next, isCurrent: current, requireReadableResult: true);
  });

  Future<SupportContextBlock?> mutateLegacy(
    String sessionId,
    SupportContextBlock? Function(SupportContextBlock?) change,
    bool Function() current,
  ) => context.db.transaction(() async {
    if (!current()) return null;
    await context.sessions.requireParent(sessionId);
    if (!current()) return null;
    if (await context.row(SupportRepo.assistantPermissionsId) != null) {
      throw StateError('Assistant permission routing changed.');
    }
    if (!current()) return null;
    final id = 'workspace-permissions-v1:$sessionId';
    final row = await context.row(id);
    if (!current()) return null;
    SupportContextBlock? latest;
    if (row != null) {
      _requireSameSession(row.sessionId, sessionId);
      latest = await context.mapper.context(row);
      _requireUnlocked(latest.isLocked);
    }
    if (!current()) return null;
    final next = change(latest);
    if (next == null || !current()) return null;
    if (next.id != id) throw StateError('Support context identity changed.');
    _requireSameSession(next.sessionId, sessionId);
    _requireUnlocked(next.isLocked);
    return context.write(next, isCurrent: current, requireReadableResult: true);
  });

  void _validate(SupportContextBlock block) {
    if (block.id != SupportRepo.assistantPermissionsId ||
        block.sessionId.isNotEmpty ||
        block.isActive ||
        block.startMessageId.isNotEmpty ||
        block.endMessageId.isNotEmpty) {
      throw StateError('Invalid global permissions identity.');
    }
    _requireUnlocked(block.isLocked);
  }
}
