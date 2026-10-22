import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/glaze_tab_bar.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../state/support_workspace_provider.dart';
import 'support_settings_pickers.dart';
import 'support_settings_unavailable.dart';
import 'support_privacy_group.dart';

/// Right panel for Astoria Assistant: mode selector (`Onboarding / Diagnostics / Hybrid`),
/// independent API connection & model selector using safe `CredentialMetadata`
/// (`configured` + `characterCount` runes, never raw keys), sampling/reasoning
/// overrides, and quick diagnostic actions.
class SupportSettingsPanel extends ConsumerWidget {
  final bool collapsed;
  final VoidCallback? onActionTriggered;

  const SupportSettingsPanel({
    super.key,
    this.collapsed = false,
    this.onActionTriggered,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workspace = ref.watch(supportWorkspaceProvider);
    final settings = workspace.settings;
    final connections = ref.watch(supportConnectionsProvider);
    final notifier = ref.read(supportWorkspaceProvider.notifier);

    if (collapsed) {
      return _CollapsedSettingsStrip(
        onSettings: () => showModalBottomSheet<void>(
          context: context,
          useRootNavigator: true,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (sheetContext) => SheetView(
            title: 'Настройки Астории',
            showBack: true,
            onBack: () => Navigator.of(sheetContext).pop(),
            body: Builder(
              builder: (bodyContext) => Padding(
                padding: EdgeInsets.only(
                  top: MediaQuery.paddingOf(bodyContext).top,
                ),
                child: SupportSettingsPanel(
                  onActionTriggered: () {
                    Navigator.of(sheetContext).pop();
                    onActionTriggered?.call();
                  },
                ),
              ),
            ),
          ),
        ),
        onDiagnostics: () {
          GlazeToast.show(context, 'Исполнитель диагностики пока недоступен.');
          onActionTriggered?.call();
        },
        onReport: () {
          GlazeToast.show(context, 'Экспорт отчёта пока недоступен.');
          onActionTriggered?.call();
        },
      );
    }

    if (!workspace.settingsAvailable) {
      return const SupportSettingsUnavailableView();
    }

    final activeConnection = connections
        .where((c) => c.connectionId == settings.apiConfigId)
        .firstOrNull;

    return Material(
      type: MaterialType.transparency,
      child: ListView(
        padding: const EdgeInsets.only(top: 12, bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Режим Астории',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: context.cs.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                GlazeTabBar(
                  tabs: [
                    for (final mode in SupportAssistantMode.values)
                      GlazeTabItem(
                        label: mode.shortLabel,
                        icon: switch (mode) {
                          SupportAssistantMode.onboarding =>
                            Icons.school_outlined,
                          SupportAssistantMode.diagnostics =>
                            Icons.troubleshoot_rounded,
                          SupportAssistantMode.hybrid =>
                            Icons.auto_awesome_rounded,
                        },
                      ),
                  ],
                  activeIndex: SupportAssistantMode.values.indexOf(
                    settings.mode,
                  ),
                  onChanged: (idx) =>
                      notifier.setMode(SupportAssistantMode.values[idx]),
                ),
              ],
            ),
          ),
          MenuGroup(
            header: 'Профиль Астории (запуск LLM пока недоступен)',
            description: 'support_privacy_chooser_not_consent'.tr(),
            items: [
              MenuSelectorItem(
                key: const ValueKey('support_connection_selector'),
                label: 'API',
                currentValue:
                    activeConnection?.displayName ??
                    'Не выбрано (Автономный режим)',
                onTap: () => SupportSettingsPickers.connection(
                  context,
                  notifier,
                  connections,
                ),
              ),
              MenuSelectorItem(
                key: const ValueKey('support_model_selector'),
                label: 'Модель',
                currentValue:
                    (settings.modelId != null && settings.modelId!.isNotEmpty)
                    ? settings.modelId!
                    : 'Не выбрана',
                onTap: () => SupportSettingsPickers.model(
                  context,
                  notifier,
                  activeConnection,
                  settings,
                ),
              ),
              MenuRangeItem(
                label: 'Temperature',
                value: settings.temperature,
                min: 0.0,
                max: 1.5,
                divisions: 30,
                decimalPlaces: 2,
                onChanged: notifier.setTemperature,
              ),
              MenuRangeItem(
                label: 'Max Tokens',
                value: settings.maxTokens.toDouble(),
                min: 256,
                max: 8192,
                divisions: 31,
                decimalPlaces: 0,
                onChanged: (v) => notifier.setMaxTokens(v.round()),
              ),
              MenuSelectorItem(
                key: const ValueKey('support_reasoning_selector'),
                label: 'Reason',
                currentValue: settings.reasoningEffort.label,
                onTap: () =>
                    SupportSettingsPickers.reasoning(context, notifier),
              ),
              MenuSwitchItem(
                label: 'Предпочтение сжатия контекста (DCP)',
                description:
                    'Предпочтение сохраняется; runtime сжатия пока недоступен',
                value: settings.dcpCompressionEnabled,
                onChanged: notifier.setDcpCompression,
              ),
            ],
          ),
          const SupportPrivacyGroup(),
          MenuGroup(
            header: 'Быстрая диагностика и действия',
            items: [
              MenuItem(
                key: const ValueKey('support_panel_diag_action'),
                icon: Icons.network_check_rounded,
                label: 'О диагностике подключения',
                subtitle: 'Исполнитель проверок пока недоступен',
                onTap: () {
                  GlazeToast.show(
                    context,
                    'Исполнитель диагностики пока недоступен.',
                  );
                  onActionTriggered?.call();
                },
              ),
              MenuItem(
                key: const ValueKey('support_panel_report_action'),
                icon: Icons.enhanced_encryption_rounded,
                label: 'О .astoria-report',
                subtitle: 'Экспорт отчёта пока не реализован',
                onTap: () {
                  GlazeToast.show(context, 'Экспорт отчёта пока недоступен.');
                  onActionTriggered?.call();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CollapsedSettingsStrip extends StatelessWidget {
  final VoidCallback onSettings;
  final VoidCallback onDiagnostics;
  final VoidCallback onReport;

  const _CollapsedSettingsStrip({
    required this.onSettings,
    required this.onDiagnostics,
    required this.onReport,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Column(
        children: [
          const SizedBox(height: 8),
          IconButton(
            key: const ValueKey('support_collapsed_settings_btn'),
            tooltip: 'Настройки Астории',
            icon: Icon(Icons.tune_rounded, size: 20, color: context.cs.primary),
            onPressed: onSettings,
          ),
          IconButton(
            tooltip: 'Диагностика подключения',
            icon: Icon(
              Icons.network_check_rounded,
              size: 20,
              color: context.cs.primary,
            ),
            onPressed: onDiagnostics,
          ),
          IconButton(
            tooltip: 'О .astoria-report (экспорт пока недоступен)',
            icon: Icon(
              Icons.enhanced_encryption_rounded,
              size: 20,
              color: context.cs.primary,
            ),
            onPressed: onReport,
          ),
        ],
      ),
    );
  }
}
