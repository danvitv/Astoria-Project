import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../../shared/theme/app_colors.dart';
import '../state/support_workspace_provider.dart';
import 'support_card_view.dart';

/// Pure Dart native chat feed for Astoria Assistant.
///
/// Renders lightweight `*` / `**` Markdown and typed [SupportCardView] items
/// without WebView or per-row `BackdropFilter`.
class SupportMessageList extends StatelessWidget {
  final List<SupportMessageItem> messages;
  final bool hasConfiguredModel;
  final ValueChanged<String> onQuickAction;
  final ValueChanged<String> onApplyPlan;
  final ValueChanged<String> onRollback;
  final ValueChanged<String>? onSetupAction;
  final double topPadding;
  final double bottomPadding;

  const SupportMessageList({
    super.key,
    required this.messages,
    required this.hasConfiguredModel,
    required this.onQuickAction,
    required this.onApplyPlan,
    required this.onRollback,
    this.onSetupAction,
    this.topPadding = 16,
    this.bottomPadding = 16,
  });

  @override
  Widget build(BuildContext context) {
    final showWelcome = messages.isEmpty || !hasConfiguredModel;
    final headerCount = showWelcome ? 1 : 0;
    final totalCount = headerCount + messages.length;

    return ListView.builder(
      padding: EdgeInsets.fromLTRB(16, topPadding, 16, bottomPadding),
      itemCount: totalCount,
      itemBuilder: (context, index) {
        if (showWelcome && index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: _AstoriaWelcomeBanner(
              hasConfiguredModel: hasConfiguredModel,
              onQuickAction: onQuickAction,
            ),
          );
        }
        final message = messages[index - headerCount];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _SupportMessageBubble(
            message: message,
            onQuickAction: onQuickAction,
            onApplyPlan: onApplyPlan,
            onRollback: onRollback,
            onSetupAction: onSetupAction,
          ),
        );
      },
    );
  }
}

class _AstoriaWelcomeBanner extends StatelessWidget {
  final bool hasConfiguredModel;
  final ValueChanged<String> onQuickAction;

  const _AstoriaWelcomeBanner({
    required this.hasConfiguredModel,
    required this.onQuickAction,
  });

  @override
  Widget build(BuildContext context) {
    final welcomeCard = QuickActionChipsCard(
      title: 'Астория Ассистент',
      subtitle:
          'История сессий хранится зашифрованной. Ответы LLM, инструменты диагностики, исправления и экспорт отчёта пока не реализованы. Настройки можно открыть ниже; ролевые профили не меняются.',
      actions: const [
        QuickActionItem(
          id: 'theme_setup',
          label: 'Сменить тему',
          subtitle: 'Открыть существующие настройки оформления',
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
          label: 'О диагностике',
          subtitle: 'Исполнитель проверок пока недоступен',
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
                child: Image.asset(
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
                    ? 'Профиль выбран; ответы LLM пока недоступны'
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
  final ValueChanged<String> onQuickAction;
  final ValueChanged<String> onApplyPlan;
  final ValueChanged<String> onRollback;
  final ValueChanged<String>? onSetupAction;

  const _SupportMessageBubble({
    required this.message,
    required this.onQuickAction,
    required this.onApplyPlan,
    required this.onRollback,
    this.onSetupAction,
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
                    Text(
                      isUser ? 'Ты' : 'Астория',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: context.cs.primary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                GptMarkdown(
                  message.body,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.4,
                    color: context.cs.onSurface,
                  ),
                ),
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
}
