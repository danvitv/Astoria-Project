import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_error_block.dart';
import '../state/support_workspace_provider.dart';
import 'support_surface_layout.dart';

/// Recovery is a deliberate confirmed preference reset, not ciphertext repair.
class SupportSettingsUnavailableView extends ConsumerWidget {
  const SupportSettingsUnavailableView({
    super.key,
    this.collapsed = false,
    this.sheetHosted = false,
  });
  final bool collapsed;
  final bool sheetHosted;

  Future<void> _confirm(BuildContext context, WidgetRef ref, String id) async {
    final notifier = ref.read(supportWorkspaceProvider.notifier);
    final session = ref.read(supportWorkspaceProvider).activeSession;
    final confirmed = await GlazeBottomSheet.show<bool>(
      context,
      title: 'Сбросить настройки сессии?',
      bigInfo: const BottomSheetBigInfo(
        icon: Icons.restart_alt_rounded,
        description:
            'Повреждённые настройки будут заменены значениями по умолчанию. История сохранится. Заблокированные зашифрованные данные не заменяются.',
      ),
      items: [
        BottomSheetItem(
          label: 'Сбросить настройки',
          isDestructive: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(true),
        ),
        BottomSheetItem(
          label: 'Отмена',
          onTap: () => Navigator.of(context, rootNavigator: true).pop(false),
        ),
      ],
    );
    if (!context.mounted || confirmed != true) return;
    if (!identical(ref.read(supportWorkspaceProvider).activeSession, session)) {
      return;
    }
    await notifier.recoverSettings(sessionId: id, confirmed: true);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workspace = ref.watch(supportWorkspaceProvider);
    if (collapsed) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: Icon(Icons.lock_outline_rounded),
      );
    }
    final message = switch (workspace.settingsAvailability) {
      SupportSettingsAvailability.locked =>
        'Зашифрованные настройки заблокированы. Сброс недоступен: исходные данные сохранены.',
      SupportSettingsAvailability.corrupt =>
        'Настройки повреждены или имеют неподдерживаемый формат. Отправка и изменения заблокированы.',
      _ =>
        'Не удалось прочитать настройки. Повтори загрузку; значения по умолчанию не применены.',
    };
    return Material(
      type: MaterialType.transparency,
      child: ListView(
        padding: supportSurfacePadding(
          context,
          sheetHosted: sheetHosted,
          horizontal: 16,
        ),
        children: [
          GlazeErrorBlock(message: message, label: 'Настройки недоступны'),
          if (workspace.error != null) ...[
            const SizedBox(height: 12),
            GlazeErrorBlock(message: workspace.error!, label: 'Астория'),
          ],
          const SizedBox(height: 12),
          GlazeActionButton(
            key: const ValueKey('support_settings_retry'),
            icon: Icons.refresh_rounded,
            label: 'Повторить загрузку',
            busy: workspace.isBusy || workspace.isLoading,
            expand: true,
            onTap: () => ref.read(supportWorkspaceProvider.notifier).refresh(),
          ),
          if (workspace.settingsAvailability ==
              SupportSettingsAvailability.corrupt) ...[
            const SizedBox(height: 12),
            GlazeActionButton(
              key: const ValueKey('support_settings_recover'),
              icon: Icons.restart_alt_rounded,
              label: 'Сбросить настройки…',
              tone: GlazeActionTone.destructive,
              expand: true,
              busy: workspace.isBusy || workspace.isLoading,
              onTap: () => _confirm(context, ref, workspace.activeSessionId),
            ),
          ],
        ],
      ),
    );
  }
}
