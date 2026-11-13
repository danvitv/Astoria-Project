import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/card_evolution_worker_provider.dart';
import 'chat_status_card_shell.dart';

/// Review preparation is visible/cancellable without impersonating foreground
/// Ledger status or disabling chat input. Cancel targets the exact durable job.
class CardEvolutionBackgroundCard extends ConsumerStatefulWidget {
  const CardEvolutionBackgroundCard({super.key, required this.sessionId});
  final String? sessionId;
  @override
  ConsumerState<CardEvolutionBackgroundCard> createState() =>
      _CardEvolutionBackgroundCardState();
}

class _CardEvolutionBackgroundCardState
    extends ConsumerState<CardEvolutionBackgroundCard> {
  String? _dismissed;

  @override
  Widget build(BuildContext context) {
    final sessionId = widget.sessionId;
    if (sessionId == null) return const SizedBox.shrink();
    final jobs =
        ref.watch(cardEvolutionJobsProvider(sessionId)).value ?? const [];
    if (jobs.isEmpty) return const SizedBox.shrink();
    final job =
        jobs.where((job) => job.status == 'running').firstOrNull ??
        jobs.where((job) => job.status == 'pending').firstOrNull ??
        jobs.first;
    final active = job.status == 'pending' || job.status == 'running';
    if (!active && _dismissed == job.id) return const SizedBox.shrink();
    final failed = job.status == 'failed' || job.status == 'stale';
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: ChatStatusCardShell(
        label: 'background_evolution_${job.status}'.tr(),
        icon: failed ? Icons.error_outline : Icons.auto_fix_high_outlined,
        accent: failed
            ? Theme.of(context).colorScheme.error
            : Theme.of(context).colorScheme.primary,
        showSpinner: job.status == 'running',
        action: IconButton(
          icon: Icon(
            active ? Icons.stop_circle_outlined : Icons.close,
            size: 18,
          ),
          tooltip:
              (active
                      ? 'background_evolution_cancel'
                      : 'background_evolution_hide')
                  .tr(),
          visualDensity: VisualDensity.compact,
          onPressed: active
              ? () async {
                  await ref
                      .read(cardEvolutionBackgroundProvider)
                      .cancel(job.id);
                }
              : () => setState(() => _dismissed = job.id),
        ),
      ),
    );
  }
}
