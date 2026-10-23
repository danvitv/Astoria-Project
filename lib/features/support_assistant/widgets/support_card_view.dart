import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../state/support_workspace_provider.dart';

/// Native typed cards. Unimplemented executors never advertise success.
class SupportCardView extends StatelessWidget {
  final SupportCard card;
  final ValueChanged<String>? onQuickAction;
  final ValueChanged<String>? onApplyPlan;
  final ValueChanged<String>? onRollback;
  final ValueChanged<String>? onSetupAction;
  final ValueChanged<SupportGuidanceTarget>? onGuidance;

  const SupportCardView({
    super.key,
    required this.card,
    this.onQuickAction,
    this.onApplyPlan,
    this.onRollback,
    this.onSetupAction,
    this.onGuidance,
  });

  @override
  Widget build(BuildContext context) {
    final children = switch (card) {
      final SupportGuidanceCard c => <Widget>[
        _title(context, c.target.title),
        Text(c.target.reason),
        const Text(
          'Ничего не включено автоматически. Настройка или разрешение '
          'подтверждаются отдельно в нативном окне.',
        ),
        _CardAction(
          key: ValueKey('support_guidance_${c.target.name}'),
          label: c.target.actionLabel,
          onTap: onGuidance == null ? null : () => onGuidance!(c.target),
        ),
      ],
      final QuickActionChipsCard c => <Widget>[
        _title(context, c.title),
        Text(c.subtitle),
        for (final item in c.actions)
          _CardAction(
            key: ValueKey('quick_action_${item.id}'),
            label: item.label,
            subtitle: item.subtitle,
            onTap: onQuickAction == null ? null : () => onQuickAction!(item.id),
          ),
      ],
      final DiagnosticCheckCard c => <Widget>[
        _title(context, c.title),
        Text('Статус: ${c.status.name}'),
        Text(c.summary),
        for (final finding in c.findings) Text('• $finding'),
        const Text('Метаданные не подтверждают успешный ответ провайдера.'),
      ],
      final SetupActionCard c => <Widget>[
        _title(context, _setupTitle(c.topicId)),
        const Text(
          'Откроются существующие настройки. Ассистент не применяет изменения автоматически.',
        ),
        if (c.credentialMetadata case final metadata?)
          Text(
            metadata.configured
                ? 'Ключ настроен (символов: ${metadata.characterCount})'
                : 'Ключ не задан',
          ),
        _CardAction(
          label: 'Открыть настройки',
          onTap: onSetupAction == null ? null : () => onSetupAction!(c.topicId),
        ),
      ],
      final MutationPlanCard c => <Widget>[
        _title(context, 'План изменений: ${c.title} (${c.domain})'),
        Text('Предложение — до: ${c.beforeSummary}'),
        Text('Предложение — после: ${c.afterSummary}'),
        const Text(
          'Эта текстовая карточка не разрешает изменений. Текущее состояние не проверено и не изменено. Выбор установленной темы доступен только в отдельном нативном окне.',
        ),
        _CardAction(
          key: ValueKey('apply_plan_${c.planId}'),
          label: 'Применение пока недоступно',
        ),
      ],
      final MutationAppliedCard c => <Widget>[
        _title(context, 'Запись о предложении (${c.domain})'),
        const Text(
          'Эта текстовая карточка не подтверждает изменение настроек и не содержит разрешения на Undo. Нативная история тем не восстанавливает право отката.',
        ),
        _CardAction(
          key: ValueKey('rollback_${c.journalId}'),
          label: 'Откат пока недоступен',
        ),
      ],
      SupportReportCard() => <Widget>[
        _title(context, '.astoria-report'),
        const Text(
          'Экспорт отчёта пока не реализован. Файл и диагностический снимок не созданы.',
        ),
      ],
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.cs.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.cs.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: DefaultTextStyle(
          style: TextStyle(fontSize: 12.5, color: context.cs.onSurfaceVariant),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final child in children)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: child,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _title(BuildContext context, String title) => Text(
    title,
    style: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w700,
      color: context.cs.onSurface,
    ),
  );

  String _setupTitle(String topic) => switch (topic) {
    'provider_setup' => 'Настройки API',
    'theme_setup' => 'Настройки оформления',
    'memory_books_setup' => 'Настройки памяти',
    _ => 'Настройки',
  };
}

/// Lightweight list action, deliberately without a blur pass per row.
class _CardAction extends StatelessWidget {
  final String label;
  final String? subtitle;
  final VoidCallback? onTap;

  const _CardAction({
    super.key,
    required this.label,
    this.subtitle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.cs.surface.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.cs.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(
                Icons.bolt_rounded,
                size: 18,
                color: onTap == null
                    ? context.cs.onSurfaceVariant
                    : context.cs.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: context.cs.onSurface,
                      ),
                    ),
                    if (subtitle != null) Text(subtitle!),
                  ],
                ),
              ),
              if (onTap != null)
                const Icon(Icons.chevron_right_rounded, size: 18),
            ],
          ),
        ),
      ),
    ),
  );
}
