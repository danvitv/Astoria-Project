import '../../../core/credentials/secret_redactor.dart';
import '../../../core/db/repositories/support_repo.dart';
import '../../../core/models/support_models.dart' as db;
import '../../../core/utils/id_generator.dart';
import '../models/support_workspace_models.dart';
import 'support_card_codec.dart';
import 'support_workspace_settings_codec.dart';

class SupportWorkspaceSnapshot {
  const SupportWorkspaceSnapshot(this.sessions, this.messages, this.settings);
  final List<SupportSessionSummary> sessions;
  final Map<String, List<SupportMessageItem>> messages;
  final Map<String, SupportAssistantSettings> settings;
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
    for (final session in sessions) {
      messages[session.id] = List.unmodifiable(
        (await repo.getMessagesForSession(session.id)).map(_message),
      );
      if (!session.isLocked) {
        try {
          settings[session.id] = await settingsFor(session.id);
        } on StateError {
          settings[session.id] = const SupportAssistantSettings();
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

  Future<void> togglePin(String id) async {
    final current = await repo.getSessionById(id);
    if (current == null) return;
    await repo.updateSessionMetadata(
      sessionId: id,
      pinned: !current.pinned,
      updatedAt: _now,
    );
  }

  Future<SupportAssistantSettings> settingsFor(String id) async =>
      _settings.decode(await repo.getContextBlockById(_settings.idFor(id)));
  Future<void> changeSettings(
    String id,
    SupportAssistantSettings Function(SupportAssistantSettings) change,
  ) async {
    final session = await repo.getSessionById(id);
    if (session == null || session.isLocked) {
      throw StateError('Session unavailable');
    }
    final next = change(await settingsFor(id));
    await repo.putContextBlock(_settings.encode(id, next, _now, _redactor()));
  }

  Future<void> appendUser(String id, String text) => append(
    SupportMessageItem(
      id: generateId(),
      sessionId: id,
      role: SupportMessageRole.user,
      body: _redactor().redactText(text.trim()),
      createdAt: DateTime.now().toUtc(),
    ),
  );
  Future<void> append(SupportMessageItem item) async {
    await repo.appendMessage(
      db.SupportMessage(
        id: item.id,
        sessionId: item.sessionId,
        role: item.role.name,
        body: _redactor().redactText(item.body),
        cardsJson: _cards.encode(item.cards),
        createdAt: item.createdAt.millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> deleteMessage(String sessionId, String id) async {
    final message = await repo.getMessageById(id);
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
