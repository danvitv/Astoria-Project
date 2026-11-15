import 'dart:async';

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
  String? _autoDismissScheduledFor;
  Timer? _autoDismiss;

  @override
  void dispose() {
    _autoDismiss?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sessionId = widget.sessionId;
    if (sessionId == null) return const SizedBox.shrink();
    final jobs =
        ref.watch(cardEvolutionJobsProvider(sessionId)).value ?? const [];
    if (jobs.isEmpty) {
      _cancelAutoDismiss();
      return const SizedBox.shrink();
    }
    final job =
        jobs.where((job) => job.status == 'running').firstOrNull ??
        jobs.where((job) => job.status == 'pending').firstOrNull ??
        jobs.first;
    final active = job.status == 'pending' || job.status == 'running';
    if (!active && _dismissed == job.id) return const SizedBox.shrink();
    final failed = job.status == 'failed' || job.status == 'stale';
    final completed = job.status == 'completed';
    if (completed) {
      _scheduleAutoDismiss(job.id);
    } else {
      _cancelAutoDismiss();
    }
    return ChatStatusCardShell(
      // A reservation may only check cadence and do no model work. Without
      // worker stage information, do not claim proposals are being written.
      label: active || completed
          ? 'Card Evolution'
          : 'background_evolution_${job.status}'.tr(),
      icon: failed
          ? Icons.error_outline
          : completed
          ? Icons.check_circle_outline
          : Icons.auto_fix_high_outlined,
      accent: failed
          ? Theme.of(context).colorScheme.error
          : Theme.of(context).colorScheme.primary,
      showSpinner: job.status == 'running',
      action: IconButton(
        icon: Icon(active ? Icons.stop_circle_outlined : Icons.close, size: 18),
        tooltip:
            (active
                    ? 'background_evolution_cancel'
                    : 'background_evolution_hide')
                .tr(),
        visualDensity: VisualDensity.compact,
        onPressed: active
            ? () async {
                await ref.read(cardEvolutionBackgroundProvider).cancel(job.id);
              }
            : () => _dismiss(job.id),
      ),
    );
  }

  void _scheduleAutoDismiss(String jobId) {
    if (_autoDismissScheduledFor == jobId) return;
    _autoDismiss?.cancel();
    _autoDismissScheduledFor = jobId;
    _autoDismiss = Timer(const Duration(milliseconds: 2500), () {
      if (!mounted) return;
      _dismiss(jobId);
    });
  }

  void _cancelAutoDismiss() {
    _autoDismiss?.cancel();
    _autoDismiss = null;
    _autoDismissScheduledFor = null;
  }

  void _dismiss(String jobId) {
    _cancelAutoDismiss();
    if (mounted) setState(() => _dismissed = jobId);
  }
}
