import 'package:flutter/material.dart';

import '../../../core/credentials/api_connection_metadata.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../state/support_workspace_provider.dart';
import 'support_model_selection_form.dart';

/// Settings writes retain their original native display and final confirmation.
class SupportSettingsPickers {
  static void connection(
    BuildContext context,
    SupportWorkspaceNotifier notifier,
    List<ApiConnectionMetadata> connections, {
    required SupportWorkspaceSettingsIntent intent,
    VoidCallback? onAdd,
  }) {
    if (!intent.isCurrent) return;
    final confirmation = _SettingsPickerConfirmation(intent);
    GlazeBottomSheet.show<bool>(
      context,
      title: 'Подключение Астории',
      itemCount: connections.length + 1 + (onAdd == null ? 0 : 1),
      itemBuilder: (pickerContext, index) {
        final route = ModalRoute.of<bool>(pickerContext);
        if (index == connections.length + 1) {
          return BottomSheetItem(
            label: 'Добавить провайдера',
            icon: Icons.add_rounded,
            onTap: () => confirmation.closeForNavigation(pickerContext, route),
          );
        }
        final connection = index == 0 ? null : connections[index - 1];
        return BottomSheetItem(
          label: connection?.displayName ?? 'Не выбрано',
          hint: connection == null
              ? null
              : connection.configured
              ? 'Ключ: ${connection.characterCount} симв. • ${connection.protocol}'
              : 'Ключ не задан • ${connection.protocol}',
          onTap: () => confirmation.confirm(
            pickerContext,
            route,
            () => notifier.selectConnection(
              connection?.connectionId,
              defaultModelId: connection?.model,
              intent: intent,
            ),
          ),
        );
      },
    ).then((add) {
      // The picker has popped. Never rediscover its route from a closed context.
      if (add == true && intent.isCurrent) onAdd?.call();
    });
  }

  static void model(
    BuildContext context,
    SupportWorkspaceNotifier notifier,
    ApiConnectionMetadata? connection,
    SupportAssistantSettings settings, {
    required SupportWorkspaceSettingsIntent intent,
    SupportProviderModelLoader? loadModels,
  }) {
    if (!intent.isCurrent) return;
    final confirmation = _SettingsPickerConfirmation(intent);
    GlazeBottomSheet.show<void>(
      context,
      title: 'Модель Астории',
      child: Builder(
        builder: (pickerContext) {
          final route = ModalRoute.of<void>(pickerContext);
          return SupportModelSelectionForm(
            initialModel: settings.modelId ?? '',
            models: const [],
            loadModels: loadModels,
            isCurrent: () => intent.isCurrent && route?.isCurrent == true,
            onSelect: (model) => confirmation.confirm(
              pickerContext,
              route,
              () => notifier.selectModel(model, intent: intent),
            ),
          );
        },
      ),
    );
  }

  static void reasoning(
    BuildContext context,
    SupportWorkspaceNotifier notifier, {
    required SupportWorkspaceSettingsIntent intent,
  }) {
    if (!intent.isCurrent) return;
    final confirmation = _SettingsPickerConfirmation(intent);
    GlazeBottomSheet.show<void>(
      context,
      title: 'Reasoning Effort',
      itemCount: SupportReasoningEffort.values.length,
      itemBuilder: (pickerContext, index) {
        final route = ModalRoute.of<void>(pickerContext);
        final effort = SupportReasoningEffort.values[index];
        return BottomSheetItem(
          label: effort.label,
          onTap: () => confirmation.confirm(
            pickerContext,
            route,
            () => notifier.setReasoningEffort(effort, intent: intent),
          ),
        );
      },
    );
  }
}

/// Validate the original top modal BEFORE starting the original settings job.
/// Closing this picker is not retirement of its parent's already-admitted job.
final class _SettingsPickerConfirmation {
  _SettingsPickerConfirmation(this.intent);
  final SupportWorkspaceSettingsIntent intent;
  bool _used = false;

  void closeForNavigation(BuildContext context, ModalRoute<dynamic>? route) {
    if (_used ||
        !context.mounted ||
        route?.isCurrent != true ||
        !intent.isCurrent ||
        !context.mounted ||
        route?.isCurrent != true) {
      return;
    }
    _used = true;
    Navigator.of(context).pop(true);
  }

  void confirm(
    BuildContext context,
    ModalRoute<dynamic>? route,
    Future<bool> Function() save,
  ) {
    if (_used ||
        !context.mounted ||
        route?.isCurrent != true ||
        !intent.isCurrent ||
        !context.mounted ||
        route?.isCurrent != true) {
      return;
    }
    _used = true;
    save();
    if (context.mounted && route?.isCurrent == true) {
      Navigator.of(context).pop();
    }
  }
}
