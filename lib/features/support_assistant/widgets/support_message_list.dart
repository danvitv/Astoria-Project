import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/credential_vault_provider.dart';
import '../../../shared/theme/app_colors.dart';
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
  final double topPadding;
  final double bottomPadding;
  final SupportModelRunView run;
  final Widget? welcomeAvatar;

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
    this.run = const SupportModelRunView(),
    this.welcomeAvatar,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final display = SupportMessageDisplayProjection(
      redactor: ref.watch(secretRedactorProvider),
    );
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
              avatar: welcomeAvatar,
            ),
          );
        }
        final message = messages[index - headerCount];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _SupportMessageBubble(
            message: message,
            display: display,
            run: run,
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
          'История сессий хранится зашифрованной. Модель отвечает только текстом после подтверждения получателя и точного prompt. Инструменты, исправления, Undo, DCP, диагностика и экспорт отчёта пока недоступны. Ролевые профили не меняются.',
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
                    ? 'Профиль выбран; каждый запрос требует подтверждения'
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
  final SupportModelRunView run;

  const _SupportMessageBubble({
    required this.message,
    required this.display,
    required this.onQuickAction,
    required this.onApplyPlan,
    required this.onRollback,
    this.onSetupAction,
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
                  text: display.project(message.body),
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
