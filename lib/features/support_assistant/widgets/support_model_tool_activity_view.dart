import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../models/support_model_tool_activity.dart';
import '../services/support_message_display_projection.dart';

/// Passive, local native-call progress, separate from the model's answer body.
/// The owning bubble gates this view by unlocked message, exact run and session.
class SupportModelToolActivityView extends StatelessWidget {
  const SupportModelToolActivityView({
    super.key,
    required this.activities,
    required this.display,
  });

  final List<SupportModelToolActivity> activities;
  final SupportMessageDisplayProjection display;

  @override
  Widget build(BuildContext context) {
    if (activities.isEmpty) return const SizedBox.shrink();
    final ordered = activities.toList()
      ..sort((a, b) => a.sequence.compareTo(b.sequence));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Ход работы',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: context.cs.onSurfaceVariant,
          ),
        ),
        for (final activity in ordered)
          Padding(
            key: ValueKey('support_tool_activity_${activity.sequence}'),
            padding: const EdgeInsets.only(top: 8),
            child: _ToolActivityRow(activity: activity, display: display),
          ),
      ],
    );
  }
}

class _ToolActivityRow extends StatelessWidget {
  const _ToolActivityRow({required this.activity, required this.display});

  final SupportModelToolActivity activity;
  final SupportMessageDisplayProjection display;

  @override
  Widget build(BuildContext context) {
    final color = activity.stage == SupportModelToolStage.failed
        ? context.cs.error
        : context.cs.onSurfaceVariant;
    // Reproject at paint time: a secret may be registered after native metadata
    // was captured. Never render the retained source label directly.
    final source = activity.sourceLabel == null
        ? ''
        : display.project(activity.sourceLabel!);
    final detail = activity.detail == null
        ? ''
        : display.project(activity.detail!);
    final secondaryStyle = TextStyle(
      fontSize: 12,
      height: 1.35,
      color: context.cs.onSurfaceVariant,
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 20),
          child: Text('${activity.sequence}.', style: secondaryStyle),
        ),
        const SizedBox(width: 4),
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(_icon, size: 16, color: color),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                display.project(activity.title),
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                  color: context.cs.onSurface,
                ),
              ),
              Text(_stageLabel, style: secondaryStyle.copyWith(color: color)),
              if (source.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(source, style: secondaryStyle),
                ),
              if (detail.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(detail, style: secondaryStyle),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // Keep the state visible even when label is replaced by a native explanation.
  String get _stageLabel => switch (activity.stage) {
    SupportModelToolStage.preparing => 'Подготовка вызова…',
    SupportModelToolStage.confirmation => 'Ожидание твоего согласия',
    SupportModelToolStage.executing => 'Выполнение…',
    SupportModelToolStage.completed => 'Завершено',
    SupportModelToolStage.failed => 'Не выполнено',
    SupportModelToolStage.stopped => 'Остановлено',
  };

  IconData get _icon => switch (activity.stage) {
    SupportModelToolStage.preparing => Icons.build_circle_outlined,
    SupportModelToolStage.confirmation => Icons.pan_tool_outlined,
    SupportModelToolStage.executing => Icons.play_circle_outline_rounded,
    SupportModelToolStage.completed => Icons.check_circle_outline_rounded,
    SupportModelToolStage.failed => Icons.error_outline_rounded,
    SupportModelToolStage.stopped => Icons.stop_circle_outlined,
  };
}
