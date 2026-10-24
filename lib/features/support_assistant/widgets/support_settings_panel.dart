import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/credentials/api_connection_metadata.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/glaze_tab_bar.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../state/support_workspace_provider.dart';
import '../models/support_permission_preferences.dart';
import 'support_settings_focus.dart';
import 'support_settings_pickers.dart';
import 'support_settings_unavailable.dart';
import 'support_settings_start_session.dart';
import 'support_privacy_group.dart';

/// Right panel for Astoria Assistant: mode selector (`Onboarding / Diagnostics / Hybrid`),
/// independent API connection & model selector using safe `CredentialMetadata`
/// (`configured` + `characterCount` runes, never raw keys), sampling/reasoning
/// overrides, and quick diagnostic actions.
class SupportSettingsPanel extends ConsumerWidget {
  final bool collapsed;
  final VoidCallback? onActionTriggered;
  final SupportSettingsFocus focus;
  final SupportPermission? focusedPermission;
  final bool Function()? isOriginalUiCurrent;

  const SupportSettingsPanel({
    super.key,
    this.collapsed = false,
    this.onActionTriggered,
    this.focus = SupportSettingsFocus.all,
    this.focusedPermission,
    this.isOriginalUiCurrent,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workspace = ref.watch(supportWorkspaceProvider);
    final notifier = ref.read(supportWorkspaceProvider.notifier);
    if (isOriginalUiCurrent?.call() == false) {
      return const Center(
        child: Text('Предложение устарело. Открой его заново.'),
      );
    }
    final intent = notifier.captureSettingsIntent(
      isOriginalUiCurrent: isOriginalUiCurrent,
    );
    final settings = workspace.settings;
    final connections =
        focus.includes(SupportSettingsFocus.connection) ||
            focus.includes(SupportSettingsFocus.model)
        ? ref.watch(supportConnectionsProvider)
        : const <ApiConnectionMetadata>[];

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
    if (workspace.activeSessionId.isEmpty) {
      return SupportSettingsStartSession(
        enabled: !workspace.isLoading && !workspace.isBusy,
      );
    }

    final activeConnection = connections
        .where((c) => c.connectionId == settings.apiConfigId)
        .firstOrNull;

    return Material(
      type: MaterialType.transparency,
      child: ListView(
        padding: const EdgeInsets.only(top: 12, bottom: 24),
        children: [
          if (focus.includes(SupportSettingsFocus.mode))
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
                    key: const ValueKey('support_settings_mode'),
                    style: GlazeTabBarStyle.underline,
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
                    onChanged: (idx) => intent == null
                        ? null
                        : notifier.setMode(
                            SupportAssistantMode.values[idx],
                            intent: intent,
                          ),
                  ),
                ],
              ),
            ),
          if (focus.hasModelSettings)
            MenuGroup(
              header: 'Профиль Астории (текст по явному подтверждению)',
              description: 'support_privacy_chooser_not_consent'.tr(),
              items: [
                if (focus.includes(SupportSettingsFocus.connection))
                  MenuSelectorItem(
                    key: const ValueKey('support_connection_selector'),
                    label: 'API',
                    currentValue:
                        activeConnection?.displayName ??
                        'Не выбрано (Автономный режим)',
                    onTap: () => intent == null
                        ? null
                        : SupportSettingsPickers.connection(
                            context,
                            notifier,
                            connections,
                            intent: intent,
                          ),
                  ),
                if (focus.includes(SupportSettingsFocus.connection) ||
                    focus.includes(SupportSettingsFocus.model))
                  MenuSelectorItem(
                    key: const ValueKey('support_model_selector'),
                    label: 'Модель',
                    currentValue:
                        (settings.modelId != null &&
                            settings.modelId!.isNotEmpty)
                        ? settings.modelId!
                        : 'Не выбрана',
                    onTap: () => intent == null
                        ? null
                        : SupportSettingsPickers.model(
                            context,
                            notifier,
                            activeConnection,
                            settings,
                            intent: intent,
                            connections: connections,
                          ),
                  ),
                if (focus.includes(SupportSettingsFocus.temperature))
                  MenuRangeItem(
                    key: const ValueKey('support_settings_temperature'),
                    label: 'Temperature',
                    value: settings.temperature,
                    min: 0.0,
                    max: 1.5,
                    divisions: 30,
                    decimalPlaces: 2,
                    onChanged: (value) => intent == null
                        ? null
                        : notifier.setTemperature(value, intent: intent),
                  ),
                if (focus.includes(SupportSettingsFocus.maxTokens))
                  MenuRangeItem(
                    key: const ValueKey('support_settings_max_tokens'),
                    label: 'Лимит ответа, токены',
                    value: settings.maxTokens.toDouble(),
                    min: 256,
                    max: 8192,
                    divisions: 31,
                    decimalPlaces: 0,
                    onChanged: (v) => intent == null
                        ? null
                        : notifier.setMaxTokens(v.round(), intent: intent),
                  ),
                if (focus.includes(SupportSettingsFocus.reasoning))
                  MenuSelectorItem(
                    key: const ValueKey('support_reasoning_selector'),
                    label: 'Reason',
                    currentValue: settings.reasoningEffort.label,
                    onTap: () => intent == null
                        ? null
                        : SupportSettingsPickers.reasoning(
                            context,
                            notifier,
                            intent: intent,
                          ),
                  ),
                if (focus.includes(SupportSettingsFocus.dcp))
                  MenuSwitchItem(
                    key: const ValueKey('support_settings_dcp'),
                    label: 'Предпочтение сжатия контекста (DCP)',
                    description:
                        'Предпочтение сохраняется; runtime сжатия пока недоступен',
                    value: settings.dcpCompressionEnabled,
                    onChanged: (value) => intent == null
                        ? null
                        : notifier.setDcpCompression(value, intent: intent),
                  ),
              ],
            ),
          if (focus.includes(SupportSettingsFocus.privacy))
            SupportPrivacyGroup(focusedPermission: focusedPermission),
          if (focus == SupportSettingsFocus.all)
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
