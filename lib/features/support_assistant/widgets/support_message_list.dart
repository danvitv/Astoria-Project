import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/credential_vault_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_action_button.dart';
import '../models/support_workspace_models.dart';
import '../services/support_message_display_projection.dart';
import '../state/support_model_run_view.dart';
import 'support_card_view.dart';
import 'support_plain_markdown.dart';

/// Native, current-policy passive chat feed for Astoria Assistant.
///
/// Renders every role's body as passive `*` / `**` text, separately from supplied
/// typed [SupportCardView] items, without WebView or per-row `BackdropFilter`.
class SupportMessageList extends ConsumerWidget {
  final List<SupportMessageItem> messages;
  final bool hasConfiguredModel;
  final ValueChanged<String> onQuickAction;
  final ValueChanged<String> onApplyPlan;
  final ValueChanged<String> onRollback;
  final ValueChanged<String>? onSetupAction;
  final ValueChanged<SupportGuidanceTarget>? onGuidance;
  final ValueChanged<SupportMessageItem>? onMessageMenu;
  final ValueChanged<SupportMessageItem>? onRegenerate;
  final double topPadding;
  final double bottomPadding;
  final SupportModelRunView run;
  final Widget? welcomeAvatar;
  final Widget? notice;

  const SupportMessageList({
    super.key,
    required this.messages,
    required this.hasConfiguredModel,
    required this.onQuickAction,
    required this.onApplyPlan,
    required this.onRollback,
    this.onSetupAction,
    this.onGuidance,
    this.onMessageMenu,
    this.onRegenerate,
    this.topPadding = 16,
    this.bottomPadding = 16,
    this.run = const SupportModelRunView(),
    this.welcomeAvatar,
    this.notice,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final display = SupportMessageDisplayProjection(
      redactor: ref.watch(secretRedactorProvider),
    );
    final showWelcome = messages.isEmpty || !hasConfiguredModel;
    final headerCount = showWelcome || notice != null ? 1 : 0;
    final totalCount = headerCount + messages.length;

    return ListView.builder(
      padding: EdgeInsets.fromLTRB(16, topPadding, 16, bottomPadding),
      itemCount: totalCount,
      itemBuilder: (context, index) {
        if (headerCount == 1 && index == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ?notice,
              if (showWelcome)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _AstoriaWelcomeBanner(
                    hasConfiguredModel: hasConfiguredModel,
                    onQuickAction: onQuickAction,
                    avatar: welcomeAvatar,
                  ),
                ),
            ],
          );
        }
        final message = messages[index - headerCount];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _SupportMessageBubble(
            key: ValueKey('support_message_${message.sessionId}_${message.id}'),
            message: message,
            display: display,
            run: run,
            onQuickAction: onQuickAction,
            onApplyPlan: onApplyPlan,
            onRollback: onRollback,
            onSetupAction: onSetupAction,
            onGuidance: onGuidance,
            onMessageMenu: onMessageMenu,
            onRegenerate:
                index - headerCount == messages.length - 1 &&
                    !message.isLocked &&
                    message.runId != null &&
                    message.role == SupportMessageRole.assistant &&
                    message.cards.isEmpty &&
                    const {
                      'complete',
                      'limited',
                      'stopped',
                      'error',
                    }.contains(message.status) &&
                    hasConfiguredModel &&
                    !run.busy
                ? onRegenerate
                : null,
          ),
        );
      },
    );
  }
}

class _AstoriaWelcomeBanner extends StatelessWidget {
  final bool hasConfiguredModel;
  final ValueChanged<String> onQuickAction;
  final Widget? avatar;

  const _AstoriaWelcomeBanner({
    required this.hasConfiguredModel,
    required this.onQuickAction,
    this.avatar,
  });

  @override
  Widget build(BuildContext context) {
    final welcomeCard = QuickActionChipsCard(
      title: 'Астория Ассистент',
      subtitle:
          'Астория предлагает нужные настройки и разрешения прямо в чате. '
          'Выбор сессии — область доступа, а не автоматическое разрешение. '
          '«Отправить» сразу передаёт вопрос и видимый текущий диалог выбранной модели. '
          'Тема и подключение настраиваются в отдельных нативных окнах. '
          'Диагностику можно обсудить без выбора игровой сессии. '
          'Автоматический сбор диагностических данных, Memory, инструменты, '
          'Ручной компакт и автоматическое управление контекстом DCP доступны; экспорт пока недоступен.',
      actions: const [
        QuickActionItem(
          id: 'theme_setup',
          label: 'Сменить тему',
          subtitle: 'Получить предложение и точный нативный план',
        ),
        QuickActionItem(
          id: 'provider_setup',
          label: 'Настроить провайдера',
          subtitle: 'Открыть доверенные нативные настройки API',
        ),
        QuickActionItem(
          id: 'memory_books_setup',
          label: 'Настройки памяти',
          subtitle: 'Где настроить Memory Books в ролевой сессии',
        ),
        QuickActionItem(
          id: 'connection_diagnostics',
          label: 'Начать диагностику',
          subtitle: 'Снимок настроек и список последних сессий',
        ),
        QuickActionItem(
          id: 'support_report',
          label: 'О .astoria-report',
          subtitle: 'Экспорт отчёта пока недоступен',
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            ClipOval(
              child: SizedBox(
                width: 40,
                height: 40,
                child:
                    avatar ??
                    Image.asset(
                      'assets/logos/astoria-sticker.png',
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Image.asset(
                        'assets/logos/astoria.png',
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Icon(
                          Icons.support_agent_rounded,
                          size: 24,
                          color: context.cs.primary,
                        ),
                      ),
                    ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                hasConfiguredModel
                    ? 'Профиль выбран; «Отправить» сразу отправляет модели'
                    : 'История и переходы к настройкам',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: context.cs.primary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SupportCardView(card: welcomeCard, onQuickAction: onQuickAction),
      ],
    );
  }
}

class _SupportMessageBubble extends StatelessWidget {
  final SupportMessageItem message;
  final SupportMessageDisplayProjection display;
  final ValueChanged<String> onQuickAction;
  final ValueChanged<String> onApplyPlan;
  final ValueChanged<String> onRollback;
  final ValueChanged<String>? onSetupAction;
  final ValueChanged<SupportGuidanceTarget>? onGuidance;
  final ValueChanged<SupportMessageItem>? onMessageMenu;
  final ValueChanged<SupportMessageItem>? onRegenerate;
  final SupportModelRunView run;

  const _SupportMessageBubble({
    super.key,
    required this.message,
    required this.display,
    required this.onQuickAction,
    required this.onApplyPlan,
    required this.onRollback,
    this.onSetupAction,
    this.onGuidance,
    this.onMessageMenu,
    this.onRegenerate,
    required this.run,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == SupportMessageRole.user;
    final bgColor = isUser
        ? context.cs.primary.withValues(alpha: 0.18)
        : context.cs.surfaceContainerHighest.withValues(alpha: 0.48);
    final borderColor = isUser
        ? context.cs.primary.withValues(alpha: 0.35)
        : context.cs.outlineVariant;
    final status =
        !message.isLocked &&
            message.activity == SupportMessageActivity.interrupted &&
            run.isActiveRun(message.runId, message.sessionId)
        ? run.label
        : message.statusLabel;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isUser
                          ? Icons.person_outline_rounded
                          : Icons.auto_awesome_rounded,
                      size: 14,
                      color: context.cs.primary,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        isUser ? 'Ты' : 'Астория',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: context.cs.primary,
                        ),
                      ),
                    ),
                    if (onMessageMenu != null &&
                        (message.role == SupportMessageRole.user ||
                            message.role == SupportMessageRole.assistant)) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        key: ValueKey('support_message_menu_${message.id}'),
                        tooltip: 'Действия с сообщением',
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          Icons.more_horiz_rounded,
                          size: 18,
                          color: context.cs.onSurfaceVariant,
                        ),
                        onPressed: () => onMessageMenu!(message),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                if (status.isNotEmpty)
                  Padding(
                    key: ValueKey('support_message_status_${message.id}'),
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      status,
                      style: TextStyle(
                        fontSize: 12,
                        color: context.cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                SupportPlainMarkdown(
                  text: _bodyText,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.4,
                    color: context.cs.onSurface,
                  ),
                ),
                if (onRegenerate != null) ...[
                  const SizedBox(height: 10),
                  GlazeActionButton(
                    key: ValueKey('support_regenerate_${message.id}'),
                    label: 'Перегенерировать ответ',
                    icon: Icons.refresh_rounded,
                    onTap: () => onRegenerate!(message),
                  ),
                ],
                if (message.cards.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  for (final card in message.cards)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: SupportCardView(
                        card: card,
                        onQuickAction: onQuickAction,
                        onApplyPlan: onApplyPlan,
                        onRollback: onRollback,
                        onSetupAction: onSetupAction,
                        onGuidance: onGuidance,
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  String get _bodyText {
    final safe = display.project(message.body);
    if (message.isLocked ||
        message.role != SupportMessageRole.assistant ||
        message.status != 'error' ||
        safe.trim().isNotEmpty) {
      return safe;
    }
    final reason = run.settledDiagnostic(message.runId, message.sessionId);
    return reason.isNotEmpty
        ? reason
        : 'Модель не вернула текст ответа. Причина для сохранённого сообщения '
              'недоступна. Можно перегенерировать последний ответ; действия приложения '
              'при этом не повторяются.';
  }
}
