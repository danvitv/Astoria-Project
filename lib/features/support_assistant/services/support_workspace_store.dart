import '../../../core/credentials/secret_redactor.dart';
import '../../../core/db/repositories/support_repo.dart';
import '../../../core/models/support_models.dart' as db;
import '../../../core/support/support_payload_cipher.dart';
import '../../../core/utils/id_generator.dart';
import '../models/support_workspace_models.dart';
import 'support_card_codec.dart';
import 'support_workspace_settings_codec.dart';

class SupportWorkspaceSnapshot {
  const SupportWorkspaceSnapshot(
    this.sessions,
    this.messages,
    this.settings, [
    this.settingsAvailability = const {},
  ]);
  final List<SupportSessionSummary> sessions;
  final Map<String, List<SupportMessageItem>> messages;
  final Map<String, SupportAssistantSettings> settings;
  final Map<String, SupportSettingsAvailability> settingsAvailability;
}

/// Repository adapter; all queries and transactions belong to SupportRepo.
class SupportWorkspaceStore {
  SupportWorkspaceStore(this.repo, this._redactor);
  final SupportRepo repo;
  final SecretRedactor Function() _redactor;
  static const _cards = SupportCardCodec();
  static const _settings = SupportWorkspaceSettingsCodec();
  int get _now => DateTime.now().toUtc().millisecondsSinceEpoch;

  Future<SupportWorkspaceSnapshot> load() async {
    final sessions = await repo.getAllSessions();
    final messages = <String, List<SupportMessageItem>>{};
    final settings = <String, SupportAssistantSettings>{};
    final availability = <String, SupportSettingsAvailability>{};
    for (final session in sessions) {
      messages[session.id] = List.unmodifiable(
        (await repo.getMessagesForSession(session.id)).map(_message),
      );
      if (session.isLocked) {
        availability[session.id] = SupportSettingsAvailability.locked;
      } else {
        try {
          settings[session.id] = await settingsFor(session.id);
          availability[session.id] = SupportSettingsAvailability.available;
        } on SupportSettingsUnavailable catch (error) {
          availability[session.id] = error.availability;
        } catch (_) {
          availability[session.id] = SupportSettingsAvailability.unavailable;
        }
      }
    }
    return SupportWorkspaceSnapshot(
      List.unmodifiable(
        sessions.map(
          (s) => SupportSessionSummary(
            id: s.id,
            title: s.isLocked ? 'Зашифрованная сессия недоступна' : s.title,
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              s.createdAt,
              isUtc: true,
            ),
            updatedAt: DateTime.fromMillisecondsSinceEpoch(
              s.updatedAt,
              isUtc: true,
            ),
            pinned: s.pinned,
            mode: settings[s.id]?.mode ?? SupportAssistantMode.hybrid,
            activeApiConfigId: settings[s.id]?.apiConfigId,
            activeModelId: settings[s.id]?.modelId,
            isLocked: s.isLocked,
          ),
        ),
      ),
      Map.unmodifiable(messages),
      Map.unmodifiable(settings),
      Map.unmodifiable(availability),
    );
  }

  Future<String> create(String? title) async {
    final id = generateId();
    await repo.createSession(
      db.SupportSession(
        id: id,
        title: _redactor().redactText(
          title?.trim().isNotEmpty == true
              ? title!.trim()
              : 'Новая сессия с Асторией',
        ),
        createdAt: _now,
        updatedAt: _now,
      ),
    );
    return id;
  }

  Future<void> rename(String id, String title) async {
    if (title.trim().isEmpty) return;
    await repo.renameSession(
      sessionId: id,
      title: _redactor().redactText(title.trim()),
      updatedAt: _now,
    );
  }

  Future<void> togglePin(String id, {bool Function()? isCurrent}) async {
    final current = await repo.getSessionById(id);
    if (isCurrent?.call() == false) return;
    if (current == null) return;
    await repo.updateSessionMetadata(
      sessionId: id,
      pinned: !current.pinned,
      updatedAt: _now,
    );
  }

  Future<SupportAssistantSettings> settingsFor(String id) async =>
      _settings.decode(await repo.getContextBlockById(_settings.idFor(id)));

  /// Exact durable native recipient reader, never workspace history/cache.
  Future<SupportAssistantSettings?> readableSettingsFor(String id) async {
    try {
      final parent = await repo.getSessionById(id);
      if (parent == null || parent.isLocked) return null;
      final block = await repo.getContextBlockById(_settings.idFor(id));
      if (block != null &&
          (block.id != _settings.idFor(id) || block.sessionId != id)) {
        return null;
      }
      final settings = _settings.decode(block);
      final latest = await repo.getSessionById(id);
      return latest == null || latest.isLocked ? null : settings;
    } catch (_) {
      return null;
    }
  }

  Future<void> changeSettings(
    String id,
    SupportAssistantSettings Function(SupportAssistantSettings) change, {
    bool Function()? isCurrent,
  }) async {
    await _mutateSettings(id, (latest) {
      final next = change(_settings.decode(latest));
      if (isCurrent?.call() == false) return null;
      return _settings.encode(id, next, _now, _redactor());
    }, isCurrent: isCurrent);
  }

  /// Only readable malformed preferences can be reset; locked bytes stay intact.
  Future<void> recoverSettings(
    String id, {
    required bool confirmed,
    bool Function()? isCurrent,
  }) async {
    if (!confirmed) throw StateError('Recovery not confirmed');
    await _mutateSettings(id, (latest) {
      try {
        _settings.decode(latest);
        throw StateError('Settings do not need recovery');
      } on SupportSettingsUnavailable catch (error) {
        if (error.availability != SupportSettingsAvailability.corrupt) rethrow;
      }
      return _settings.encode(
        id,
        const SupportAssistantSettings(),
        _now,
        _redactor(),
      );
    }, isCurrent: isCurrent);
  }

  Future<void> _mutateSettings(
    String id,
    db.SupportContextBlock? Function(db.SupportContextBlock? latest) mutate, {
    bool Function()? isCurrent,
  }) async {
    try {
      await repo.mutateContextBlock(
        blockId: _settings.idFor(id),
        sessionId: id,
        mutate: mutate,
        isCurrent: isCurrent,
      );
    } on SupportCipherException {
      throw SupportSettingsUnavailable(SupportSettingsAvailability.locked);
    }
  }

  Future<void> deleteSession(String id) => repo.deleteSession(id);

  Future<SupportMessageItem> appendUser(String id, String text) => append(
    SupportMessageItem(
      id: generateId(),
      sessionId: id,
      role: SupportMessageRole.user,
      body: _redactor().redactText(text.trim()),
      createdAt: DateTime.now().toUtc(),
    ),
  );
  Future<SupportMessageItem> append(SupportMessageItem item) async {
    final durable = await repo.appendMessage(
      db.SupportMessage(
        id: item.id,
        sessionId: item.sessionId,
        role: item.role.name,
        body: _redactor().redactText(item.body),
        cardsJson: _cards.encode(item.cards),
        createdAt: item.createdAt.millisecondsSinceEpoch,
      ),
    );
    return _message(durable);
  }

  Future<void> deleteMessage(
    String sessionId,
    String id, {
    bool Function()? isCurrent,
  }) async {
    final message = await repo.getMessageById(id);
    if (isCurrent?.call() == false) return;
    if (message?.sessionId != sessionId) return;
    await repo.deleteMessage(id);
  }

  SupportMessageItem _message(db.SupportMessage m) => SupportMessageItem(
    id: m.id,
    sessionId: m.sessionId,
    role:
        SupportMessageRole.values.where((r) => r.name == m.role).firstOrNull ??
        SupportMessageRole.system,
    body: m.isLocked ? 'Зашифрованное сообщение недоступно' : m.body,
    cards: m.isLocked ? const [] : _cards.decode(m.cardsJson),
    createdAt: DateTime.fromMillisecondsSinceEpoch(m.createdAt, isUtc: true),
    isLocked: m.isLocked,
  );
}
