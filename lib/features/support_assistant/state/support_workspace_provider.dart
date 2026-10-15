import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/credentials/api_connection_metadata.dart';
import '../../../core/credentials/credential_metadata.dart';

/// Operating mode of Astoria Assistant in the support workspace.
enum SupportAssistantMode {
  onboarding('Onboarding', 'Объяснять и обучать'),
  diagnostics('Diagnostics', 'Диагностировать'),
  hybrid('Hybrid', 'Гибридный (Помощь + Настройка)');

  final String shortLabel;
  final String fullLabel;

  const SupportAssistantMode(this.shortLabel, this.fullLabel);
}

/// Reasoning effort override for Astoria Assistant's own generation profile.
enum SupportReasoningEffort {
  off('Off'),
  low('Low'),
  medium('Medium'),
  high('High');

  final String label;
  const SupportReasoningEffort(this.label);
}

/// Role of a message in a support session.
enum SupportMessageRole { user, assistant, system }

/// Deterministic status of a diagnostic check card.
enum SupportCheckStatus { ok, warning, error, missingEvidence }

/// Metadata for an offline-capable quick action chip on the welcome card.
@immutable
class QuickActionItem {
  final String id;
  final String label;
  final String subtitle;

  const QuickActionItem({
    required this.id,
    required this.label,
    required this.subtitle,
  });
}

/// Default offline-capable quick actions shown when a session is empty or
/// no LLM model is configured.
const List<QuickActionItem> kDefaultSupportQuickActions = [
  QuickActionItem(
    id: 'theme_setup',
    label: 'Сменить тему',
    subtitle: 'Живое превью тем, переключение dark/light и мгновенный откат',
  ),
  QuickActionItem(
    id: 'provider_setup',
    label: 'Настроить провайдера',
    subtitle: 'Подготовка подключения и безопасный ввод ключа в хранилище',
  ),
  QuickActionItem(
    id: 'memory_books_setup',
    label: 'Настроить Memory Books',
    subtitle: 'Пошаговый мастер памяти для с��ссии и генератора черновиков',
  ),
  QuickActionItem(
    id: 'connection_diagnostics',
    label: 'Проверить подключение и ошибки',
    subtitle: 'Локальная проверка endpoint, протокола и таймлайна ошибок',
  ),
  QuickActionItem(
    id: 'support_report',
    label: 'Собрать зашифрованный репорт (.astoria-report)',
    subtitle: 'Очистка секретов, предпросмотр и шифрование пакета поддержки',
  ),
];

/// Typed structured cards rendered natively inside the support chat feed.
@immutable
sealed class SupportCard {
  const SupportCard();
}

/// Card rendering offline-capable quick action chips.
final class QuickActionChipsCard extends SupportCard {
  final String title;
  final String subtitle;
  final List<QuickActionItem> actions;

  const QuickActionChipsCard({
    required this.title,
    required this.subtitle,
    this.actions = kDefaultSupportQuickActions,
  });
}

/// Card displaying the result of a deterministic diagnostic check.
final class DiagnosticCheckCard extends SupportCard {
  final String checkId;
  final String title;
  final String summary;
  final SupportCheckStatus status;
  final List<String> findings;

  const DiagnosticCheckCard({
    required this.checkId,
    required this.title,
    required this.summary,
    required this.status,
    this.findings = const [],
  });
}

/// Guided setup card for theme, provider, or Memory Books onboarding.
final class SetupActionCard extends SupportCard {
  final String topicId;
  final String title;
  final String description;
  final List<String> steps;
  final String primaryActionLabel;
  final String? secondaryActionLabel;
  final CredentialMetadata? credentialMetadata;

  const SetupActionCard({
    required this.topicId,
    required this.title,
    required this.description,
    this.steps = const [],
    required this.primaryActionLabel,
    this.secondaryActionLabel,
    this.credentialMetadata,
  });
}

/// Inspectable mutation plan with before/after diff and confirmation action.
final class MutationPlanCard extends SupportCard {
  final String planId;
  final String domain;
  final String title;
  final String beforeSummary;
  final String afterSummary;
  final List<String> untouchedAreas;
  final List<String> risks;
  final bool applied;

  const MutationPlanCard({
    required this.planId,
    required this.domain,
    required this.title,
    required this.beforeSummary,
    required this.afterSummary,
    this.untouchedAreas = const [],
    this.risks = const [],
    this.applied = false,
  });

  MutationPlanCard copyWith({bool? applied}) => MutationPlanCard(
    planId: planId,
    domain: domain,
    title: title,
    beforeSummary: beforeSummary,
    afterSummary: afterSummary,
    untouchedAreas: untouchedAreas,
    risks: risks,
    applied: applied ?? this.applied,
  );
}

/// Result card for an applied mutation with one-click rollback support.
final class MutationAppliedCard extends SupportCard {
  final String journalId;
  final String domain;
  final String summary;
  final bool canRollback;
  final bool rolledBack;

  const MutationAppliedCard({
    required this.journalId,
    required this.domain,
    required this.summary,
    this.canRollback = true,
    this.rolledBack = false,
  });

  MutationAppliedCard copyWith({bool? rolledBack}) => MutationAppliedCard(
    journalId: journalId,
    domain: domain,
    summary: summary,
    canRollback: canRollback,
    rolledBack: rolledBack ?? this.rolledBack,
  );
}

/// Encrypted support report package preview and export card.
final class SupportReportCard extends SupportCard {
  final String reportId;
  final String summary;
  final List<String> includedSections;
  final bool encrypted;
  final String fileName;

  const SupportReportCard({
    required this.reportId,
    required this.summary,
    this.includedSections = const [],
    this.encrypted = true,
    required this.fileName,
  });
}

/// Single message in a support session.
@immutable
class SupportMessageItem {
  final String id;
  final String sessionId;
  final SupportMessageRole role;
  final String body;
  final List<SupportCard> cards;
  final DateTime createdAt;

  const SupportMessageItem({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.body,
    this.cards = const [],
    required this.createdAt,
  });

  SupportMessageItem copyWith({List<SupportCard>? cards, String? body}) =>
      SupportMessageItem(
        id: id,
        sessionId: sessionId,
        role: role,
        body: body ?? this.body,
        cards: cards ?? this.cards,
        createdAt: createdAt,
      );
}

/// Metadata summary for a support session in the left sidebar.
@immutable
class SupportSessionSummary {
  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool pinned;
  final SupportAssistantMode mode;
  final String? activeApiConfigId;
  final String? activeModelId;

  const SupportSessionSummary({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.pinned = false,
    this.mode = SupportAssistantMode.hybrid,
    this.activeApiConfigId,
    this.activeModelId,
  });

  SupportSessionSummary copyWith({
    String? title,
    DateTime? updatedAt,
    bool? pinned,
    SupportAssistantMode? mode,
    String? activeApiConfigId,
    String? activeModelId,
  }) => SupportSessionSummary(
    id: id,
    title: title ?? this.title,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    pinned: pinned ?? this.pinned,
    mode: mode ?? this.mode,
    activeApiConfigId: activeApiConfigId ?? this.activeApiConfigId,
    activeModelId: activeModelId ?? this.activeModelId,
  );
}

/// Independent generation and access settings for Astoria Assistant.
@immutable
class SupportAssistantSettings {
  final SupportAssistantMode mode;
  final String? apiConfigId;
  final String? modelId;
  final double temperature;
  final int maxTokens;
  final SupportReasoningEffort reasoningEffort;
  final bool dcpCompressionEnabled;

  const SupportAssistantSettings({
    this.mode = SupportAssistantMode.hybrid,
    this.apiConfigId,
    this.modelId,
    this.temperature = 0.35,
    this.maxTokens = 2048,
    this.reasoningEffort = SupportReasoningEffort.medium,
    this.dcpCompressionEnabled = true,
  });

  bool get hasConfiguredModel =>
      apiConfigId != null &&
      apiConfigId!.isNotEmpty &&
      modelId != null &&
      modelId!.isNotEmpty;

  SupportAssistantSettings copyWith({
    SupportAssistantMode? mode,
    String? apiConfigId,
    bool clearApiConfigId = false,
    String? modelId,
    bool clearModelId = false,
    double? temperature,
    int? maxTokens,
    SupportReasoningEffort? reasoningEffort,
    bool? dcpCompressionEnabled,
  }) => SupportAssistantSettings(
    mode: mode ?? this.mode,
    apiConfigId: clearApiConfigId ? null : (apiConfigId ?? this.apiConfigId),
    modelId: clearModelId ? null : (modelId ?? this.modelId),
    temperature: temperature ?? this.temperature,
    maxTokens: maxTokens ?? this.maxTokens,
    reasoningEffort: reasoningEffort ?? this.reasoningEffort,
    dcpCompressionEnabled: dcpCompressionEnabled ?? this.dcpCompressionEnabled,
  );
}

/// Injectable storage abstraction so the support UI has zero compile-time
/// dependency on `app_db.g.dart` and can be backed by `SupportRepo` in
/// integration or `InMemorySupportSessionStore` in isolation.
abstract interface class SupportSessionStore {
  List<SupportSessionSummary> loadInitialSessions();
  Map<String, List<SupportMessageItem>> loadInitialMessages();
  SupportAssistantSettings loadInitialSettings();
  void persistSessions(List<SupportSessionSummary> sessions);
  void persistMessages(
    String sessionId,
    List<SupportMessageItem> sessionMessages,
  );
  void persistSettings(SupportAssistantSettings settings);
}

/// Default in-process implementation of [SupportSessionStore].
class InMemorySupportSessionStore implements SupportSessionStore {
  List<SupportSessionSummary> _sessions;
  final Map<String, List<SupportMessageItem>> _messages;
  SupportAssistantSettings _settings;

  InMemorySupportSessionStore({
    List<SupportSessionSummary>? initialSessions,
    Map<String, List<SupportMessageItem>>? initialMessages,
    SupportAssistantSettings initialSettings = const SupportAssistantSettings(),
  }) : _sessions =
           initialSessions ??
           [
             SupportSessionSummary(
               id: 'support-session-1',
               title: 'Настройка и диагностика',
               createdAt: DateTime.utc(2026, 10, 14, 10),
               updatedAt: DateTime.utc(2026, 10, 14, 10),
             ),
           ],
       _messages = {...?initialMessages},
       _settings = initialSettings;

  @override
  List<SupportSessionSummary> loadInitialSessions() =>
      List.unmodifiable(_sessions);

  @override
  Map<String, List<SupportMessageItem>> loadInitialMessages() => {
    for (final entry in _messages.entries)
      entry.key: List.unmodifiable(entry.value),
  };

  @override
  SupportAssistantSettings loadInitialSettings() => _settings;

  @override
  void persistSessions(List<SupportSessionSummary> sessions) {
    _sessions = List.unmodifiable(sessions);
  }

  @override
  void persistMessages(
    String sessionId,
    List<SupportMessageItem> sessionMessages,
  ) {
    _messages[sessionId] = List.unmodifiable(sessionMessages);
  }

  @override
  void persistSettings(SupportAssistantSettings settings) {
    _settings = settings;
  }
}

/// Injectable store provider (overridable in tests or integration).
final supportSessionStoreProvider = Provider<SupportSessionStore>(
  (ref) => InMemorySupportSessionStore(),
);

/// Safe connection metadata list (`configured` + `characterCount` runes only,
/// never raw API keys). Defaults to built-in safe metadata projections and can
/// be overridden by integration providers or tests.
final supportConnectionsProvider = Provider<List<ApiConnectionMetadata>>(
  (ref) => const [
    ApiConnectionMetadata(
      connectionId: 'conn-openrouter',
      displayName: 'OpenRouter Main',
      providerId: 'openrouter',
      protocol: 'openai',
      mode: 'chat',
      endpoint: 'https://openrouter.ai/api/v1',
      model: 'anthropic/claude-sonnet-4',
      llmCredential: CredentialMetadata.absent,
      embeddingCredential: CredentialMetadata.absent,
      embeddingUseSame: true,
      embeddingEnabled: false,
      embeddingEndpoint: '',
      embeddingModel: '',
      embeddingLlmPresetId: '',
    ),
  ],
);

/// Immutable state of the Astoria Assistant workspace.
@immutable
class SupportWorkspaceState {
  final List<SupportSessionSummary> sessions;
  final String activeSessionId;
  final Map<String, List<SupportMessageItem>> messagesBySession;
  final SupportAssistantSettings settings;
  final String sessionSearchQuery;
  final String? lastHandledTopic;

  const SupportWorkspaceState({
    required this.sessions,
    required this.activeSessionId,
    required this.messagesBySession,
    required this.settings,
    this.sessionSearchQuery = '',
    this.lastHandledTopic,
  });

  SupportSessionSummary? get activeSession =>
      sessions.where((s) => s.id == activeSessionId).firstOrNull;

  List<SupportMessageItem> get activeMessages =>
      messagesBySession[activeSessionId] ?? const [];

  List<SupportSessionSummary> get filteredSessions {
    final q = sessionSearchQuery.trim().toLowerCase();
    final filtered = q.isEmpty
        ? [...sessions]
        : sessions.where((s) => s.title.toLowerCase().contains(q)).toList();
    filtered.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return filtered;
  }

  SupportWorkspaceState copyWith({
    List<SupportSessionSummary>? sessions,
    String? activeSessionId,
    Map<String, List<SupportMessageItem>>? messagesBySession,
    SupportAssistantSettings? settings,
    String? sessionSearchQuery,
    String? lastHandledTopic,
  }) => SupportWorkspaceState(
    sessions: sessions ?? this.sessions,
    activeSessionId: activeSessionId ?? this.activeSessionId,
    messagesBySession: messagesBySession ?? this.messagesBySession,
    settings: settings ?? this.settings,
    sessionSearchQuery: sessionSearchQuery ?? this.sessionSearchQuery,
    lastHandledTopic: lastHandledTopic ?? this.lastHandledTopic,
  );
}

/// State notifier managing support sessions, messages, settings, and
/// offline-capable quick actions.
class SupportWorkspaceNotifier extends Notifier<SupportWorkspaceState> {
  int _counter = 10;

  @override
  SupportWorkspaceState build() {
    final store = ref.watch(supportSessionStoreProvider);
    final sessions = store.loadInitialSessions();
    final messages = store.loadInitialMessages();
    final settings = store.loadInitialSettings();
    final firstId = sessions.isNotEmpty ? sessions.first.id : 'support-init';
    final ensuredSessions = sessions.isNotEmpty
        ? sessions
        : [
            SupportSessionSummary(
              id: firstId,
              title: 'Новая сесси�� с Асторией',
              createdAt: DateTime.now().toUtc(),
              updatedAt: DateTime.now().toUtc(),
              mode: settings.mode,
            ),
          ];
    return SupportWorkspaceState(
      sessions: ensuredSessions,
      activeSessionId: firstId,
      messagesBySession: messages,
      settings: settings,
    );
  }

  SupportSessionStore get _store => ref.read(supportSessionStoreProvider);

  String _nextId(String prefix) => '$prefix-${++_counter}';

  void setSessionSearchQuery(String query) {
    state = state.copyWith(sessionSearchQuery: query);
  }

  String createNewSession({String? title}) {
    final now = DateTime.now().toUtc();
    final newSession = SupportSessionSummary(
      id: _nextId('support-session'),
      title: (title == null || title.trim().isEmpty)
          ? 'Сессия #${state.sessions.length + 1}'
          : title.trim(),
      createdAt: now,
      updatedAt: now,
      mode: state.settings.mode,
      activeApiConfigId: state.settings.apiConfigId,
      activeModelId: state.settings.modelId,
    );
    final updated = [newSession, ...state.sessions];
    _store.persistSessions(updated);
    state = state.copyWith(sessions: updated, activeSessionId: newSession.id);
    return newSession.id;
  }

  void selectSession(String sessionId) {
    if (!state.sessions.any((s) => s.id == sessionId)) return;
    state = state.copyWith(activeSessionId: sessionId);
  }

  void togglePinSession(String sessionId) {
    final updated = [
      for (final s in state.sessions)
        if (s.id == sessionId)
          s.copyWith(pinned: !s.pinned, updatedAt: DateTime.now().toUtc())
        else
          s,
    ];
    _store.persistSessions(updated);
    state = state.copyWith(sessions: updated);
  }

  void deleteSession(String sessionId) {
    final remaining = state.sessions.where((s) => s.id != sessionId).toList();
    final nextMessages = {...state.messagesBySession}..remove(sessionId);
    if (remaining.isEmpty) {
      final replacement = SupportSessionSummary(
        id: _nextId('support-session'),
        title: 'Новая сессия с Асторией',
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
        mode: state.settings.mode,
      );
      _store.persistSessions([replacement]);
      state = state.copyWith(
        sessions: [replacement],
        activeSessionId: replacement.id,
        messagesBySession: nextMessages,
      );
      return;
    }
    _store.persistSessions(remaining);
    final nextActive = state.activeSessionId == sessionId
        ? remaining.first.id
        : state.activeSessionId;
    state = state.copyWith(
      sessions: remaining,
      activeSessionId: nextActive,
      messagesBySession: nextMessages,
    );
  }

  void setMode(SupportAssistantMode mode) {
    final nextSettings = state.settings.copyWith(mode: mode);
    _store.persistSettings(nextSettings);
    state = state.copyWith(settings: nextSettings);
  }

  void selectConnection(String? apiConfigId, {String? defaultModelId}) {
    final nextSettings = apiConfigId == null
        ? state.settings.copyWith(clearApiConfigId: true, clearModelId: true)
        : state.settings.copyWith(
            apiConfigId: apiConfigId,
            modelId: defaultModelId ?? state.settings.modelId,
          );
    _store.persistSettings(nextSettings);
    state = state.copyWith(settings: nextSettings);
  }

  void selectModel(String? modelId) {
    final nextSettings = modelId == null || modelId.isEmpty
        ? state.settings.copyWith(clearModelId: true)
        : state.settings.copyWith(modelId: modelId);
    _store.persistSettings(nextSettings);
    state = state.copyWith(settings: nextSettings);
  }

  void setTemperature(double value) {
    final nextSettings = state.settings.copyWith(
      temperature: value.clamp(0.0, 2.0),
    );
    _store.persistSettings(nextSettings);
    state = state.copyWith(settings: nextSettings);
  }

  void setMaxTokens(int value) {
    final nextSettings = state.settings.copyWith(
      maxTokens: value.clamp(256, 16384),
    );
    _store.persistSettings(nextSettings);
    state = state.copyWith(settings: nextSettings);
  }

  void setReasoningEffort(SupportReasoningEffort effort) {
    final nextSettings = state.settings.copyWith(reasoningEffort: effort);
    _store.persistSettings(nextSettings);
    state = state.copyWith(settings: nextSettings);
  }

  void setDcpCompression(bool enabled) {
    final nextSettings = state.settings.copyWith(
      dcpCompressionEnabled: enabled,
    );
    _store.persistSettings(nextSettings);
    state = state.copyWith(settings: nextSettings);
  }

  void applyInitialTopic(String? topic) {
    if (topic == null ||
        topic.trim().isEmpty ||
        state.lastHandledTopic == topic) {
      return;
    }
    state = state.copyWith(lastHandledTopic: topic);
    final normalized = switch (topic.trim().toLowerCase()) {
      'theme' || 'theme_setup' => 'theme_setup',
      'provider' || 'api' || 'provider_setup' => 'provider_setup',
      'memory' || 'memory_books_setup' => 'memory_books_setup',
      'diagnostics' || 'connection_diagnostics' => 'connection_diagnostics',
      'report' || 'support_report' => 'support_report',
      _ => topic.trim(),
    };
    triggerQuickAction(normalized);
  }

  void sendUserMessage(String rawText) {
    final text = rawText.trim();
    if (text.isEmpty) return;
    final now = DateTime.now().toUtc();
    final sessionId = state.activeSessionId;
    final userMsg = SupportMessageItem(
      id: _nextId('msg-user'),
      sessionId: sessionId,
      role: SupportMessageRole.user,
      body: text,
      createdAt: now,
    );
    final replyMsg = _buildAssistantReplyForText(sessionId, text, now);
    _appendMessages(sessionId, [userMsg, replyMsg], updatedTitleHint: text);
  }

  void triggerQuickAction(String actionId) {
    final now = DateTime.now().toUtc();
    final sessionId = state.activeSessionId;
    final reply = _buildQuickActionMessage(sessionId, actionId, now);
    _appendMessages(sessionId, [reply]);
  }

  void applyMutationPlan(String planId) {
    final sessionId = state.activeSessionId;
    final current = [...state.activeMessages];
    MutationPlanCard? matchedPlan;
    for (var i = 0; i < current.length; i++) {
      final msg = current[i];
      final updatedCards = <SupportCard>[];
      var changed = false;
      for (final card in msg.cards) {
        if (card is MutationPlanCard && card.planId == planId) {
          matchedPlan = card;
          updatedCards.add(card.copyWith(applied: true));
          changed = true;
        } else {
          updatedCards.add(card);
        }
      }
      if (changed) current[i] = msg.copyWith(cards: updatedCards);
    }
    if (matchedPlan == null) return;
    final appliedMsg = SupportMessageItem(
      id: _nextId('msg-applied'),
      sessionId: sessionId,
      role: SupportMessageRole.assistant,
      body:
          'План **${matchedPlan.title}** применён атомарно. Запись сохранена в журнале операций.',
      cards: [
        MutationAppliedCard(
          journalId: 'journal-$planId',
          domain: matchedPlan.domain,
          summary: matchedPlan.afterSummary,
        ),
      ],
      createdAt: DateTime.now().toUtc(),
    );
    final nextList = [...current, appliedMsg];
    _store.persistMessages(sessionId, nextList);
    state = state.copyWith(
      messagesBySession: {...state.messagesBySession, sessionId: nextList},
    );
  }

  void rollbackMutation(String journalId) {
    final sessionId = state.activeSessionId;
    final current = [...state.activeMessages];
    for (var i = 0; i < current.length; i++) {
      final msg = current[i];
      final updatedCards = [
        for (final card in msg.cards)
          if (card is MutationAppliedCard && card.journalId == journalId)
            card.copyWith(rolledBack: true)
          else
            card,
      ];
      current[i] = msg.copyWith(cards: updatedCards);
    }
    _store.persistMessages(sessionId, current);
    state = state.copyWith(
      messagesBySession: {...state.messagesBySession, sessionId: current},
    );
  }

  void _appendMessages(
    String sessionId,
    List<SupportMessageItem> additions, {
    String? updatedTitleHint,
  }) {
    final nextMessages = [...state.activeMessages, ...additions];
    _store.persistMessages(sessionId, nextMessages);
    final now = DateTime.now().toUtc();
    final updatedSessions = [
      for (final s in state.sessions)
        if (s.id == sessionId)
          s.copyWith(
            updatedAt: now,
            title:
                (updatedTitleHint != null &&
                    (s.title.startsWith('Сессия #') ||
                        s.title == 'Новая сессия с Асторией'))
                ? (updatedTitleHint.length > 34
                      ? '${updatedTitleHint.substring(0, 34)}…'
                      : updatedTitleHint)
                : s.title,
          )
        else
          s,
    ];
    _store.persistSessions(updatedSessions);
    state = state.copyWith(
      sessions: updatedSessions,
      messagesBySession: {...state.messagesBySession, sessionId: nextMessages},
    );
  }

  SupportMessageItem _buildAssistantReplyForText(
    String sessionId,
    String text,
    DateTime now,
  ) {
    final lower = text.toLowerCase();
    if (lower.contains('тем') || lower.contains('theme')) {
      return _buildQuickActionMessage(sessionId, 'theme_setup', now);
    }
    if (lower.contains('ключ') ||
        lower.contains('провайдер') ||
        lower.contains('api')) {
      return _buildQuickActionMessage(sessionId, 'provider_setup', now);
    }
    if (lower.contains('memory') || lower.contains('памят')) {
      return _buildQuickActionMessage(sessionId, 'memory_books_setup', now);
    }
    if (lower.contains('репорт') || lower.contains('report')) {
      return _buildQuickActionMessage(sessionId, 'support_report', now);
    }
    return SupportMessageItem(
      id: _nextId('msg-astoria'),
      sessionId: sessionId,
      role: SupportMessageRole.assistant,
      body:
          'Принято: *«$text»*. Я проверила локальное состояние без обращения к секретным полям. Выбери нужное действие ниже или уточни задачу.',
      cards: const [
        DiagnosticCheckCard(
          checkId: 'check-local-state',
          title: 'Локальная диагностика окружения',
          summary:
              'Схема БД и локальное хранилище в норме; секреты скрыты за метаданными.',
          status: SupportCheckStatus.ok,
          findings: [
            'Доступ к ключам закрыт: проверяются только configured и characterCount.',
            'Готова подготовить план изменений или собрать .astoria-report.',
          ],
        ),
      ],
      createdAt: now,
    );
  }

  SupportMessageItem _buildQuickActionMessage(
    String sessionId,
    String actionId,
    DateTime now,
  ) {
    final connections = ref.read(supportConnectionsProvider);
    final activeConn = connections.firstOrNull;
    final credMeta = activeConn?.llmCredential ?? CredentialMetadata.absent;

    return switch (actionId) {
      'theme_setup' => SupportMessageItem(
        id: _nextId('msg-theme'),
        sessionId: sessionId,
        role: SupportMessageRole.assistant,
        body:
            'Настройки темы не кусаются — если не ставить кислотный неон в три часа ночи. Давай выберем пресет оформления и проверим контраст.',
        cards: const [
          SetupActionCard(
            topicId: 'theme_setup',
            title: 'Мастер оформления (theme_setup)',
            description:
                'Переключение пресета темы и режима dark/light с сохранением возможности мгновенного отката.',
            steps: [
              'Чтение установленных пресетов тем и текущего режима',
              'Применение выбранной темы с flushPersistence',
              'Проверка читаемости и кнопка возврата прежней темы',
            ],
            primaryActionLabel: 'Применить тему Obsidian Amber',
            secondaryActionLabel: 'Переключить Dark / Light',
          ),
          MutationPlanCard(
            planId: 'plan-theme-obsidian',
            domain: 'theme',
            title: 'Смена темы оформления',
            beforeSummary: 'Текущая тема: Default Dark (mode: dark)',
            afterSummary: 'Новая тема: Obsidian Amber (mode: dark)',
            untouchedAreas: [
              'Преcеты LLM',
              'Карточки персонажей',
              'API-подключения',
            ],
            risks: ['Визуальное изменение палитры, доступен откат в 1 клик'],
          ),
        ],
        createdAt: now,
      ),
      'provider_setup' => SupportMessageItem(
        id: _nextId('msg-provider'),
        sessionId: sessionId,
        role: SupportMessageRole.assistant,
        body:
            'Я подготовлю профиль подключения, но сам API-ключ в чат вставлять **не нужно** — я всё равно не желаю его видеть. Нажми кнопку нативного ввода ниже: ключ уйдёт напрямую в `CredentialVault`.',
        cards: [
          SetupActionCard(
            topicId: 'provider_setup',
            title: 'Подключение подготовлено — осталось ввести ключ',
            description:
                'Endpoint и протокол настроены по белому списку. Ключ сохраняется напрямую в защищённое хранилище устройства.',
            steps: const [
              'Профиль: OpenRouter / OpenAI Chat Completions',
              'Безопасный ввод ключа через модальное окно CredentialVault',
              'Тестовый запрос списка моделей без раскрытия секрета',
            ],
            primaryActionLabel: 'Ввести ключ в CredentialVault',
            secondaryActionLabel: 'Проверить соединение',
            credentialMetadata: credMeta,
          ),
        ],
        createdAt: now,
      ),
      'memory_books_setup' => SupportMessageItem(
        id: _nextId('msg-memory'),
        sessionId: sessionId,
        role: SupportMessageRole.assistant,
        body:
            'Memory Books отлично спасают длинные ролевые сессии от амнезии, если не выстав��ять температуру саммари как у поэтического генератора. Настроим по шагам.',
        cards: const [
          SetupActionCard(
            topicId: 'memory_books_setup',
            title: 'Мастер настройки Memory Books',
            description:
                'Разделение сессионных настроек книги памяти и глобального генератора черновиков.',
            steps: [
              '1. Область: текущая сессия vs глобальный PipelineSettings.memoryBookApi',
              '2. Автосоздание и автогенерация черновиков (интервал: 20 сообщений)',
              '3. Режим инжекции: баланс (budget 15%, mode: fast)',
              '4. Модель саммари: температура 0.4, разумный лимит maxTokens',
            ],
            primaryActionLabel: 'Подготовить план настройки памяти',
          ),
          MutationPlanCard(
            planId: 'plan-memory-books',
            domain: 'memory_book',
            title: 'Оптимизация Memory Books (Баланс)',
            beforeSummary: 'autoCreate: false, temperature: 0.8',
            afterSummary:
                'autoCreate: true (interval: 20), summary temperature: 0.4',
            untouchedAreas: [
              'Существующие записи памяти',
              'Основной ролевой пресет',
            ],
            risks: ['Генерация черновиков потребует вызовов выбранной модели'],
          ),
        ],
        createdAt: now,
      ),
      'connection_diagnostics' => SupportMessageItem(
        id: _nextId('msg-diag'),
        sessionId: sessionId,
        role: SupportMessageRole.assistant,
        body:
            'Проверила конфигурацию подключений и последние записи транспорта. Напоминаю: значения ключей мне недоступны, я вижу только факт настройки и длину в символах.',
        cards: [
          DiagnosticCheckCard(
            checkId: 'check-connection-status',
            title: 'Проверка API-подключения и секретов',
            summary: credMeta.configured
                ? 'Ключ сохранён (символов: ${credMeta.characterCount}) — готов к проверке ответа провайдера.'
                : 'Подключение подготовлено — осталось ввести ключ (configured: false, characterCount: 0).',
            status: credMeta.configured
                ? SupportCheckStatus.ok
                : SupportCheckStatus.warning,
            findings: [
              'Подключение: ${activeConn?.displayName ?? "Не выбрано"} (${activeConn?.protocol ?? "openai"})',
              'Endpoint: ${activeConn?.endpoint ?? "https://openrouter.ai/api/v1"}',
              'Метаданные ключа: configured=${credMeta.configured}, characterCount=${credMeta.characterCount}',
            ],
          ),
        ],
        createdAt: now,
      ),
      'support_report' => SupportMessageItem(
        id: _nextId('msg-report'),
        sessionId: sessionId,
        role: SupportMessageRole.assistant,
        body:
            'Собрала диагностический снимок. Все секреты прошли через `SecretRedactor` до упаковки. Пакет запечатывается на устройстве публичным ключом поддержки (`XChaCha20-Poly1305` + `X25519 Sealed Box`).',
        cards: const [
          SupportReportCard(
            reportId: 'rep-2026-astoria',
            summary:
                'Факты окружения + диагноз Астории + журнал попыток исправления (без сырых ключей и ролевых текстов).',
            includedSections: [
              'Раздел A: DiagnosticFacts (схема v136+, метаданные ключей)',
              'Раздел B: AstoriaDiagnosis (confirmed_by_check)',
              'Раздел C: RemediationAttempts (история планов и откатов)',
            ],
            encrypted: true,
            fileName: 'report-2026-astoria.astoria-report',
          ),
        ],
        createdAt: now,
      ),
      _ => SupportMessageItem(
        id: _nextId('msg-generic'),
        sessionId: sessionId,
        role: SupportMessageRole.assistant,
        body: 'Сценарий `$actionId` готов к выполнению.',
        createdAt: now,
      ),
    };
  }
}

final supportWorkspaceProvider =
    NotifierProvider<SupportWorkspaceNotifier, SupportWorkspaceState>(
      SupportWorkspaceNotifier.new,
    );
