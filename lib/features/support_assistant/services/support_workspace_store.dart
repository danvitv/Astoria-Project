import '../../../core/credentials/secret_redactor.dart';
import '../../../core/db/repositories/support_repo.dart';
import '../../../core/models/support_models.dart' as db;
import '../../../core/support/support_payload_cipher.dart';
import '../../../core/utils/id_generator.dart';
import '../models/support_workspace_models.dart';
import '../models/support_model_provenance.dart';
import 'support_card_codec.dart';
import 'support_model_provenance_codec.dart';
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

  Future<SupportWorkspaceSnapshot> load({
    bool globalSettings = false,
    String? preferredSessionId,
    bool Function()? isCurrent,
  }) async {
    final sessions = await repo.getAllSessions();
    if (isCurrent?.call() == false) throw StateError('Workspace retired.');
    final messages = <String, List<SupportMessageItem>>{};
    final settings = <String, SupportAssistantSettings>{};
    final availability = <String, SupportSettingsAvailability>{};
    SupportAssistantSettings? profile;
    var profileAvailability = SupportSettingsAvailability.available;
    if (globalSettings) {
      try {
        final candidates = [
          if (sessions.any((s) => s.id == preferredSessionId))
            preferredSessionId!,
          for (final s in sessions)
            if (s.id != preferredSessionId) s.id,
        ];
        final block = await repo.initializeAssistantSettings(
          legacySessionIds: candidates,
          create: (legacy) =>
              _settings.migrateGlobal(legacy, _now, _redactor()),
          isCurrent: isCurrent ?? () => true,
        );
        if (isCurrent?.call() == false || block == null) {
          throw StateError('Workspace retired.');
        }
        profile = _settings.decode(block);
      } on SupportSettingsUnavailable catch (error) {
        profileAvailability = error.availability;
      } on SupportCipherException {
        profileAvailability = SupportSettingsAvailability.locked;
      } catch (_) {
        profileAvailability = SupportSettingsAvailability.unavailable;
      }
      if (profile != null) settings[''] = profile;
      availability[''] = profileAvailability;
    }
    for (final session in sessions) {
      messages[session.id] = List.unmodifiable(
        (await repo.getMessagesForSession(session.id)).map(_message),
      );
      if (globalSettings) {
        if (profile != null) settings[session.id] = profile;
        availability[session.id] = profileAvailability;
      } else if (session.isLocked) {
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

  Future<SupportAssistantSettings> settingsFor(String id) async {
    final global = await repo.getContextBlockById(_settings.globalId);
    return _settings.decode(
      global ?? await repo.getContextBlockById(_settings.idFor(id)),
    );
  }

  /// Exact durable native recipient reader, never workspace history/cache.
  Future<SupportAssistantSettings?> readableSettingsFor(String id) async {
    try {
      final parent = await repo.getSessionById(id);
      if (parent == null || parent.isLocked) return null;
      final global = await repo.getContextBlockById(_settings.globalId);
      final block =
          global ?? await repo.getContextBlockById(_settings.idFor(id));
      if (block != null &&
          (global != null
              ? block.id != _settings.globalId || block.sessionId.isNotEmpty
              : block.id != _settings.idFor(id) || block.sessionId != id)) {
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

  Future<void> changeGlobalSettings(
    SupportAssistantSettings Function(SupportAssistantSettings) change, {
    required bool Function() isCurrent,
  }) => repo.mutateAssistantSettings(
    mutate: (latest) {
      final next = change(_settings.decode(latest));
      return isCurrent()
          ? _settings.encodeGlobal(next, _now, _redactor())
          : null;
    },
    isCurrent: isCurrent,
  );

  Future<void> recoverGlobalSettings({required bool Function() isCurrent}) =>
      repo.mutateAssistantSettings(
        mutate: (latest) {
          try {
            _settings.decode(latest);
            throw StateError('Settings do not need recovery');
          } on SupportSettingsUnavailable catch (error) {
            if (error.availability != SupportSettingsAvailability.corrupt)
              rethrow;
          }
          return _settings.encodeGlobal(
            const SupportAssistantSettings(),
            _now,
            _redactor(),
          );
        },
        isCurrent: isCurrent,
      );

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

  /// Native action-enabled deletion consumes J's atomic durable boolean. Never
  /// fall back to legacy deletion when evidence is unavailable or unresolved.
  Future<bool> deleteSessionIfMutationsSettled(
    String id, {
    required bool Function() isCurrent,
  }) =>
      repo.deleteSessionIfMutationsSettled(sessionId: id, isCurrent: isCurrent);

  Future<SupportMessageItem> appendUser(String id, String text) => append(
    SupportMessageItem(
      id: generateId(),
      sessionId: id,
      role: SupportMessageRole.user,
      body: _redactor().redactText(text.trim()),
      createdAt: DateTime.now().toUtc(),
    ),
  );

  /// Actual composer USER origin for a future fixed native local reply. Empty
  /// cards and a native run are required by the existing exact-origin port.
  Future<SupportMessageItem> appendNativeLocalUser(
    String id,
    String text, {
    required String runId,
    required bool Function() isCurrent,
  }) async {
    final redactor = _redactor();
    final durable = await repo.appendCurrentUser(
      message: db.SupportMessage(
        id: generateId(),
        sessionId: id,
        role: 'user',
        body: redactor.redactText(text.trim()),
        runId: runId,
        createdAt: _now,
      ),
      isCurrent: () => isCurrent() && identical(redactor, _redactor()),
    );
    if (durable == null) throw StateError('Local input unavailable');
    return _message(
      durable,
    ); // Already committed, even if UI retired meanwhile.
  }

  /// Native fixed response; NEVER called for restored/model/provider prose.
  /// Missing native USER custody is a refusal, not a legacy append fallback.
  Future<SupportMessageItem> appendNativeLocalReply(
    SupportMessageItem item, {
    required SupportMessageItem originatingUser,
    required bool Function() isCurrent,
  }) async {
    final runId = originatingUser.runId;
    if (runId == null ||
        originatingUser.role != SupportMessageRole.user ||
        originatingUser.sessionId != item.sessionId ||
        item.role != SupportMessageRole.assistant) {
      throw StateError('Local origin unavailable');
    }
    final recipe = SupportModelProvenance(
      supportSessionId: item.sessionId,
      replyMessageId: item.id,
      runId: runId,
      currentUserMessageId: originatingUser.id,
      originalRanges: const [],
      directReplies: const [],
    );
    final redactor = _redactor();
    for (final id in [item.sessionId, item.id, runId, originatingUser.id]) {
      if (redactor.redactText(id) != id) {
        throw StateError('Local origin unavailable');
      }
    }
    final encoded = SupportModelProvenanceCodec.encodeForEncryptedStorage(
      recipe,
    );
    final durable = await repo.appendNativeLocalReply(
      message: db.SupportMessage(
        id: item.id,
        sessionId: item.sessionId,
        role: 'assistant',
        body: redactor.redactText(item.body),
        cardsJson: item.cards.isEmpty ? '' : _cards.encode(item.cards),
        runId: runId,
        status: item.status,
        createdAt: item.createdAt.millisecondsSinceEpoch,
      ),
      originatingUser: db.SupportMessage(
        id: originatingUser.id,
        sessionId: originatingUser.sessionId,
        role: 'user',
        body: originatingUser.body,
        runId: runId,
        status: originatingUser.status,
        createdAt: originatingUser.createdAt.millisecondsSinceEpoch,
        isLocked: originatingUser.isLocked,
      ),
      provenanceJson: encoded,
      isCurrent: () => isCurrent() && identical(redactor, _redactor()),
    );
    if (durable == null) throw StateError('Local reply unavailable');
    return _message(durable);
  }

  Future<SupportMessageItem> append(SupportMessageItem item) async {
    final durable = await repo.appendMessage(
      db.SupportMessage(
        id: item.id,
        sessionId: item.sessionId,
        role: item.role.name,
        body: _redactor().redactText(item.body),
        cardsJson: _cards.encode(item.cards),
        runId: item.runId,
        status: item.status,
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
    if (message == null || message.sessionId != sessionId) return;
    await repo.deleteCurrentMessage(
      sessionId: sessionId,
      messageId: id,
      createdAt: message.createdAt,
      role: message.role,
      runId: message.runId,
      isCurrent: isCurrent ?? () => true,
    );
  }

  Future<bool> deleteSelectedMessage(
    SupportMessageItem message, {
    required bool Function() isCurrent,
  }) => repo.deleteCurrentMessage(
    sessionId: message.sessionId,
    messageId: message.id,
    createdAt: message.createdAt.millisecondsSinceEpoch,
    role: message.role.name,
    runId: message.runId,
    isCurrent: isCurrent,
  );

  Future<SupportMessageItem?> editSelectedUserMessage(
    SupportMessageItem message,
    String body, {
    required bool Function() isCurrent,
  }) async {
    final redactor = _redactor();
    bool current() => isCurrent() && identical(redactor, _redactor());
    if (!current() ||
        message.isLocked ||
        message.role != SupportMessageRole.user ||
        message.status != 'complete' ||
        message.cards.isNotEmpty ||
        body.trim().isEmpty ||
        body.length > 8192 ||
        redactor.redactText(message.body) != message.body)
      return null;
    final observation = await repo.readUserForEditing(
      expectedUser: db.SupportMessage(
        id: message.id,
        sessionId: message.sessionId,
        role: 'user',
        body: message.body,
        runId: message.runId,
        status: message.status,
        createdAt: message.createdAt.millisecondsSinceEpoch,
      ),
      isCurrent: current,
    );
    if (observation == null || !current()) return null;
    final saved = await repo.editUserMessage(
      expected: observation,
      body: redactor.redactText(body),
      isCurrent: current,
    );
    return saved == null ? null : _message(saved);
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
    runId: m.runId,
    status: m.status,
  );
}
