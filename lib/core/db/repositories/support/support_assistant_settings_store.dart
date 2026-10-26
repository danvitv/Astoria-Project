part of '../support_repo.dart';

extension on _SupportContextStore {
  _SupportAssistantSettingsStore get assistantSettings =>
      _SupportAssistantSettingsStore(this);
}

/// Fixed singleton only: no caller-selected parentless context or body access.
final class _SupportAssistantSettingsStore {
  _SupportAssistantSettingsStore(this.context);
  final _SupportContextStore context;

  Future<SupportContextBlock?> initialize(
    List<String> legacySessionIds,
    SupportContextBlock Function(SupportContextBlock?) create,
    bool Function() current,
  ) => context.db.transaction(() async {
    if (!current()) return null;
    final existing = await context.get(SupportRepo.assistantSettingsId);
    if (!current()) return null;
    if (existing != null) {
      _validate(existing);
      return existing;
    }
    SupportContextBlock? legacy;
    for (final sessionId in legacySessionIds) {
      if (sessionId.isEmpty)
        throw StateError('Invalid legacy settings parent.');
      final found = await context.get('workspace-settings-v1:$sessionId');
      if (!current()) return null;
      if (found == null) continue;
      _requireSameSession(found.sessionId, sessionId);
      await context.sessions.requireParent(sessionId);
      if (!current()) return null;
      _requireUnlocked(found.isLocked);
      legacy = found;
      break;
    }
    final next = create(legacy);
    if (!current()) return null;
    _validate(next);
    return context.write(next, isCurrent: current, requireReadableResult: true);
  });

  Future<SupportContextBlock?> mutate(
    SupportContextBlock? Function(SupportContextBlock?) change,
    bool Function() current,
  ) => context.db.transaction(() async {
    if (!current()) return null;
    final latest = await context.get(SupportRepo.assistantSettingsId);
    if (!current()) return null;
    if (latest != null) _validate(latest);
    final next = change(latest);
    if (next == null || !current()) return null;
    _validate(next);
    return context.write(next, isCurrent: current, requireReadableResult: true);
  });

  void _validate(SupportContextBlock block) {
    if (block.id != SupportRepo.assistantSettingsId ||
        block.sessionId.isNotEmpty ||
        block.startMessageId.isNotEmpty ||
        block.endMessageId.isNotEmpty ||
        block.isActive) {
      throw StateError('Invalid Astoria profile identity.');
    }
    _requireUnlocked(block.isLocked);
  }
}
