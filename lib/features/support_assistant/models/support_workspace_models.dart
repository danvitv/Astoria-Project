import 'package:flutter/foundation.dart';
import '../../../core/credentials/credential_metadata.dart';

enum SupportAssistantMode {
  onboarding('Onboarding', 'Объяснять и обучать'),
  diagnostics('Diagnostics', 'Диагностировать'),
  hybrid('Hybrid', 'Гибридный (Помощь + Настройка)');

  const SupportAssistantMode(this.shortLabel, this.fullLabel);
  final String shortLabel;
  final String fullLabel;
}

enum SupportReasoningEffort {
  off('Off'),
  low('Low'),
  medium('Medium'),
  high('High');

  const SupportReasoningEffort(this.label);
  final String label;
}

enum SupportMessageRole { user, assistant, system }

enum SupportMessageActivity { inactive, interrupted }

enum SupportCheckStatus { ok, warning, error, missingEvidence }

enum SupportSettingsAvailability { available, unavailable, locked, corrupt }

@immutable
class QuickActionItem {
  const QuickActionItem({
    required this.id,
    required this.label,
    required this.subtitle,
  });
  final String id, label, subtitle;
}

const kDefaultSupportQuickActions = [
  QuickActionItem(
    id: 'theme_setup',
    label: 'Сменить тему',
    subtitle: 'Инструкция по настройкам оформления',
  ),
  QuickActionItem(
    id: 'provider_setup',
    label: 'Настроить провайдера',
    subtitle: 'Инструкция по безопасному вводу ключа',
  ),
  QuickActionItem(
    id: 'memory_books_setup',
    label: 'Настроить Memory Books',
    subtitle: 'Инструкция по настройкам памяти',
  ),
  QuickActionItem(
    id: 'connection_diagnostics',
    label: 'Проверить метаданные подключения',
    subtitle: 'Без сетевого запроса',
  ),
  QuickActionItem(
    id: 'support_report',
    label: 'О репорте поддержки',
    subtitle: 'Экспорт пока недоступен',
  ),
];

@immutable
sealed class SupportCard {
  const SupportCard();
}

final class QuickActionChipsCard extends SupportCard {
  const QuickActionChipsCard({
    required this.title,
    required this.subtitle,
    this.actions = kDefaultSupportQuickActions,
  });
  final String title, subtitle;
  final List<QuickActionItem> actions;
}

final class DiagnosticCheckCard extends SupportCard {
  const DiagnosticCheckCard({
    required this.checkId,
    required this.title,
    required this.summary,
    required this.status,
    this.findings = const [],
  });
  final String checkId, title, summary;
  final SupportCheckStatus status;
  final List<String> findings;
}

final class SetupActionCard extends SupportCard {
  const SetupActionCard({
    required this.topicId,
    required this.title,
    required this.description,
    this.steps = const [],
    required this.primaryActionLabel,
    this.secondaryActionLabel,
    this.credentialMetadata,
  });
  final String topicId, title, description, primaryActionLabel;
  final String? secondaryActionLabel;
  final List<String> steps;
  final CredentialMetadata? credentialMetadata;
}

final class MutationPlanCard extends SupportCard {
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
  final String planId, domain, title, beforeSummary, afterSummary;
  final List<String> untouchedAreas, risks;
  final bool applied;
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

final class MutationAppliedCard extends SupportCard {
  const MutationAppliedCard({
    required this.journalId,
    required this.domain,
    required this.summary,
    this.canRollback = false,
    this.rolledBack = false,
  });
  final String journalId, domain, summary;
  final bool canRollback, rolledBack;
  MutationAppliedCard copyWith({bool? rolledBack}) => MutationAppliedCard(
    journalId: journalId,
    domain: domain,
    summary: summary,
    canRollback: canRollback,
    rolledBack: rolledBack ?? this.rolledBack,
  );
}

final class SupportReportCard extends SupportCard {
  const SupportReportCard({
    required this.reportId,
    required this.summary,
    this.includedSections = const [],
    this.encrypted = false,
    required this.fileName,
  });
  final String reportId, summary, fileName;
  final List<String> includedSections;
  final bool encrypted;
}

@immutable
class SupportMessageItem {
  const SupportMessageItem({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.body,
    this.cards = const [],
    required this.createdAt,
    this.isLocked = false,
    this.runId,
    this.status = 'complete',
  });
  final String id, sessionId, body;

  /// Durable native metadata ONLY, never encrypted provenance or tool authority.
  final String? runId;
  final String status;
  final SupportMessageRole role;
  final List<SupportCard> cards;
  final DateTime createdAt;
  final bool isLocked;

  /// No restored row is a live request. Activity belongs to the owning run view.
  SupportMessageActivity get activity =>
      const {
        'preparing',
        'pending',
        'running',
        'waiting',
        'activity',
        'settling',
      }.contains(status)
      ? SupportMessageActivity.interrupted
      : SupportMessageActivity.inactive;
  String get statusLabel => isLocked
      ? 'Зашифрованное сообщение недоступно'
      : switch (status) {
          'preparing' ||
          'pending' ||
          'running' ||
          'waiting' ||
          'activity' ||
          'settling' =>
            'Ответ прерван; автоматическая повторная отправка отключена.',
          'stopped' => 'Отправка остановлена.',
          'error' => 'Не удалось получить полный ответ.',
          'limited' => 'Ответ ограничен.',
          'complete' => '',
          _ => 'Состояние сохранённого ответа недоступно.',
        };
  SupportMessageItem copyWith({
    List<SupportCard>? cards,
    String? body,
    String? status,
  }) => SupportMessageItem(
    id: id,
    sessionId: sessionId,
    role: role,
    body: body ?? this.body,
    cards: cards ?? this.cards,
    createdAt: createdAt,
    isLocked: isLocked,
    runId: runId,
    status: status ?? this.status,
  );
}

@immutable
class SupportSessionSummary {
  const SupportSessionSummary({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.pinned = false,
    this.mode = SupportAssistantMode.hybrid,
    this.activeApiConfigId,
    this.activeModelId,
    this.isLocked = false,
  });
  final String id, title;
  final DateTime createdAt, updatedAt;
  final bool pinned, isLocked;
  final SupportAssistantMode mode;
  final String? activeApiConfigId, activeModelId;
}

@immutable
class SupportAssistantSettings {
  const SupportAssistantSettings({
    this.mode = SupportAssistantMode.hybrid,
    this.apiConfigId,
    this.modelId,
    this.temperature = 0.35,
    this.maxTokens = 2048,
    this.reasoningEffort = SupportReasoningEffort.medium,
    this.dcpCompressionEnabled = true,
  });
  final SupportAssistantMode mode;
  final String? apiConfigId, modelId;
  final double temperature;
  final int maxTokens;
  final SupportReasoningEffort reasoningEffort;
  final bool dcpCompressionEnabled;
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
    apiConfigId: clearApiConfigId ? null : apiConfigId ?? this.apiConfigId,
    modelId: clearModelId ? null : modelId ?? this.modelId,
    temperature: temperature ?? this.temperature,
    maxTokens: maxTokens ?? this.maxTokens,
    reasoningEffort: reasoningEffort ?? this.reasoningEffort,
    dcpCompressionEnabled: dcpCompressionEnabled ?? this.dcpCompressionEnabled,
  );
}
