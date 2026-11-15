import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glaze_action_button.dart';

/// One durable package row in the session queue — status, source count,
/// machine-readable failure cause, and the attempt number after retries.
class MemoryConsolidationQueueItem {
  const MemoryConsolidationQueueItem({
    required this.jobId,
    required this.status,
    required this.index,
    this.sourceCount = 0,
    this.lastError,
    this.attemptCount = 0,
  });

  final String jobId;
  final String status;
  final int index;
  final int sourceCount;
  final String? lastError;
  final int attemptCount;
}

/// Compact queue of durable consolidation packages for one session.
///
/// Every package is visible with its state and localized cause; actions are
/// offered per row and only for the states where they are safe. Internal
/// job ids stay hidden — rows are numbered by package order.
class MemoryConsolidationStatus extends StatelessWidget {
  const MemoryConsolidationStatus({
    super.key,
    required this.items,
    this.completedCount = 0,
    this.onReview,
    this.onRetry,
    this.onRebuild,
    this.onCopyDiagnostics,
    this.onCancel,
  });

  final List<MemoryConsolidationQueueItem> items;
  final int completedCount;
  final void Function(String jobId)? onReview;
  final void Function(String jobId)? onRetry;
  final void Function(String jobId)? onRebuild;
  final void Function(String jobId)? onCopyDiagnostics;
  final void Function(String jobId)? onCancel;

  static String? _statusLabel(String status) => switch (status) {
    'pending' => 'memory_consolidation_queue_status_pending'.tr(),
    'running' => 'memory_consolidation_queue_status_running'.tr(),
    'review_pending' => 'memory_consolidation_queue_status_review'.tr(),
    'failed' => 'memory_consolidation_queue_status_failed'.tr(),
    'cancelled' => 'memory_consolidation_queue_status_cancelled'.tr(),
    'completed' => 'memory_consolidation_queue_status_completed'.tr(),
    _ => null,
  };

  /// Durable machine reasons → localized explanations. Unknown reasons stay
  /// hidden rather than leaking internal strings into the UI.
  static String? _reasonLabel(String? reason) => switch (reason) {
    'cancelled_by_user' => 'memory_consolidation_reason_user'.tr(),
    'rejected_by_user' => 'memory_consolidation_reason_rejected'.tr(),
    'source_context_changed' =>
      'memory_consolidation_reason_source_changed'.tr(),
    'mode_disabled' => 'memory_consolidation_reason_mode'.tr(),
    'context_changed' => 'memory_consolidation_reason_context'.tr(),
    'worker_stopped' => 'memory_consolidation_reason_worker'.tr(),
    'item_failed' ||
    'package_generation_failed' => 'memory_consolidation_reason_model'.tr(),
    'source_pack_exceeds_context_budget' =>
      'memory_consolidation_reason_budget'.tr(),
    _ => null,
  };

  Widget _rowAction(MemoryConsolidationQueueItem item) => switch (item.status) {
    'review_pending' => GlazeActionButton(
      key: ValueKey('package-review-${item.jobId}'),
      icon: Icons.fact_check_outlined,
      label: 'memory_consolidation_queue_review'.tr(),
      onTap: onReview == null ? null : () => onReview!(item.jobId),
    ),
    'failed' => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onCopyDiagnostics != null)
          IconButton(
            key: ValueKey('package-diagnostics-${item.jobId}'),
            tooltip: 'memory_consolidation_queue_diagnostics'.tr(),
            icon: const Icon(Icons.bug_report_outlined, size: 18),
            onPressed: () => onCopyDiagnostics!(item.jobId),
          ),
        GlazeActionButton(
          key: ValueKey('package-retry-${item.jobId}'),
          icon: Icons.refresh_rounded,
          label: 'memory_consolidation_queue_retry'.tr(),
          onTap: onRetry == null ? null : () => onRetry!(item.jobId),
        ),
      ],
    ),
    'cancelled' when item.lastError == 'cancelled_by_user' => GlazeActionButton(
      key: ValueKey('package-restart-${item.jobId}'),
      icon: Icons.restart_alt_rounded,
      label: 'memory_consolidation_queue_restart'.tr(),
      onTap: onRetry == null ? null : () => onRetry!(item.jobId),
    ),
    'cancelled' when item.lastError == 'source_context_changed' =>
      GlazeActionButton(
        key: ValueKey('package-rebuild-${item.jobId}'),
        icon: Icons.replay_rounded,
        label: 'memory_consolidation_queue_rebuild'.tr(),
        onTap: onRebuild == null ? null : () => onRebuild!(item.jobId),
      ),
    'pending' || 'running' => GlazeActionButton(
      key: ValueKey('package-cancel-${item.jobId}'),
      tone: GlazeActionTone.neutral,
      icon: Icons.close_rounded,
      label: 'memory_consolidation_queue_cancel'.tr(),
      onTap: onCancel == null ? null : () => onCancel!(item.jobId),
    ),
    _ => const SizedBox.shrink(),
  };

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty && completedCount == 0) return const SizedBox.shrink();
    final hasRepeatedFailure = items.any(
      (item) => item.status == 'failed' && item.attemptCount >= 2,
    );
    final trailing = <Widget>[
      for (final item in items)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'memory_consolidation_queue_row'.tr(
                        namedArgs: {
                          'index': '${item.index}',
                          'count': '${item.sourceCount}',
                        },
                      ),
                      style: TextStyle(
                        fontSize: 12,
                        color: context.cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                            _statusLabel(item.status),
                            if (item.status == 'failed' &&
                                item.attemptCount >= 2)
                              'memory_consolidation_queue_attempt'.tr(
                                namedArgs: {'count': '${item.attemptCount}'},
                              ),
                            _reasonLabel(item.lastError),
                          ]
                          .whereType<String>()
                          .where((t) => t.isNotEmpty)
                          .join(' · '),
                      style: TextStyle(
                        fontSize: 11,
                        color: context.cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _rowAction(item),
            ],
          ),
        ),
      if (completedCount > 0)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            'memory_consolidation_queue_completed'.tr(
              namedArgs: {'count': '$completedCount'},
            ),
            style: TextStyle(fontSize: 11, color: context.cs.onSurfaceVariant),
          ),
        ),
      if (hasRepeatedFailure)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'memory_consolidation_queue_model_hint'.tr(),
            style: TextStyle(fontSize: 11, color: context.cs.onSurfaceVariant),
          ),
        ),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              'memory_consolidation_queue_title'.tr(),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: context.cs.onSurface,
              ),
            ),
          ),
          ...trailing,
        ],
      ),
    );
  }
}
