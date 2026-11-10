import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glaze_action_button.dart';

/// Compact user-facing state for one durable consolidation package.
///
/// It deliberately exposes no job identity or execution control beyond the
/// actions that are safe for the current durable state.
class MemoryConsolidationStatus extends StatelessWidget {
  const MemoryConsolidationStatus({
    super.key,
    required this.status,
    this.onReview,
    this.onRetry,
    this.onCancel,
  });

  final String? status;
  final VoidCallback? onReview;
  final VoidCallback? onRetry;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final action = switch (status) {
      'review_pending' => GlazeActionButton(
        key: const ValueKey('package-review'),
        icon: Icons.fact_check_outlined,
        label: 'memory_consolidation_package_review'.tr(),
        onTap: onReview,
      ),
      'failed' => GlazeActionButton(
        key: const ValueKey('package-retry'),
        icon: Icons.refresh_rounded,
        label: 'memory_consolidation_package_retry'.tr(),
        onTap: onRetry,
      ),
      'pending' || 'running' => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              'memory_consolidation_package_processing'.tr(),
              style: TextStyle(
                fontSize: 12,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ),
          GlazeActionButton(
            key: const ValueKey('package-cancel'),
            tone: GlazeActionTone.neutral,
            icon: Icons.close_rounded,
            label: 'memory_consolidation_package_cancel'.tr(),
            onTap: onCancel,
          ),
        ],
      ),
      _ => const SizedBox.shrink(),
    };
    return Padding(
      padding: EdgeInsets.only(bottom: status == null ? 0 : 8),
      child: action,
    );
  }
}
