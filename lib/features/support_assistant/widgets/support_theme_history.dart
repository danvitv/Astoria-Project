import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../state/support_theme_provider.dart';
import 'support_theme_controls.dart';
import 'support_theme_screen_controller.dart';

/// Read-time journal facts, not current SQLite/theme state or executable Undo.
class SupportThemeHistory extends StatelessWidget {
  const SupportThemeHistory({super.key, required this.controller});
  final SupportThemeScreenController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller, original = controller.intent;
    final views = [
      for (final page in c.pages)
        c.current && original != null ? original.history(page) : null,
    ];
    final next = views.isEmpty ? null : views.last?.nextCursor;
    return Column(
      key: const ValueKey('support_theme_history'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('support_theme_history_notice'.tr()),
        SupportThemeButton(
          key: const ValueKey('support_theme_history_refresh'),
          label: 'support_theme_history_refresh'.tr(),
          onTap: c.current && original != null && !c.busy
              ? () => c.discover()
              : null,
        ),
        if (c.historyRequested && views.isEmpty && !c.busy)
          Text('support_theme_history_unavailable'.tr()),
        for (final view in views)
          if (view == null ||
              view.availability == SupportThemeHistoryAvailability.unavailable)
            Text('support_theme_history_unavailable'.tr())
          else if (view.entries.isEmpty)
            Text('support_theme_history_empty'.tr())
          else
            for (final entry in view.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      (entry.state == SupportThemeRecoveryState.unavailable
                              ? 'support_theme_history_unavailable_row'
                              : 'support_theme_history_${entry.state.name}')
                          .tr(),
                    ),
                    if (entry.operationId case final id?)
                      Text('support_theme_operation'.tr(args: [id])),
                    if (entry.status case final status?)
                      Text('support_theme_status'.tr(args: [status.value])),
                    if (entry.before case final before?)
                      SupportThemeValueBlock(
                        value: before,
                        heading: 'support_theme_before'.tr(),
                      ),
                    if (entry.after case final after?)
                      SupportThemeValueBlock(
                        value: after,
                        heading: 'support_theme_after'.tr(),
                      ),
                  ],
                ),
              ),
        if (next != null)
          SupportThemeButton(
            key: const ValueKey('support_theme_history_next'),
            label: 'support_theme_history_next'.tr(),
            onTap: c.current && !c.busy ? () => c.discover(cursor: next) : null,
          ),
      ],
    );
  }
}
