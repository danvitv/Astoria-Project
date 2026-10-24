import 'package:flutter/material.dart';

import '../../../core/credentials/api_connection_metadata.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../state/support_workspace_provider.dart';
import 'support_model_selection_form.dart';

/// Safe metadata-only pickers; no request or credential read is performed.
class SupportSettingsPickers {
  static void connection(
    BuildContext context,
    SupportWorkspaceNotifier notifier,
    List<ApiConnectionMetadata> connections, {
    required SupportWorkspaceSettingsIntent intent,
  }) {
    if (!intent.isCurrent) return;
    final confirmation = _SettingsPickerConfirmation(intent);
    GlazeBottomSheet.show<void>(
      context,
      title: 'Подключение Астории',
      itemCount: connections.length + 1,
      itemBuilder: (pickerContext, index) {
        final route = ModalRoute.of<void>(pickerContext);
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
    );
  }

  static void model(
    BuildContext context,
    SupportWorkspaceNotifier notifier,
    ApiConnectionMetadata? connection,
    SupportAssistantSettings settings, {
    required SupportWorkspaceSettingsIntent intent,
    List<ApiConnectionMetadata> connections = const [],
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
            models: _knownModels(connection, connections, settings.modelId),
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

  /// Only already projected, locally saved IDs; never a provider catalog probe.
  static List<String> _knownModels(
    ApiConnectionMetadata? connection,
    List<ApiConnectionMetadata> connections,
    String? current,
  ) {
    final models = <String>{};
    void add(String? model) {
      if (model != null &&
          model.isNotEmpty &&
          model.length <= 256 &&
          RegExp(r'^[A-Za-z0-9_.:/-]+$').hasMatch(model)) {
        models.add(model);
      }
    }

    add(current);
    add(connection?.model);
    if (connection != null) {
      for (final saved in connections.take(256)) {
        if (saved.endpoint == connection.endpoint &&
            saved.protocol == connection.protocol &&
            saved.providerId == connection.providerId &&
            saved.mode == connection.mode) {
          add(saved.model);
        }
      }
    }
    return List.unmodifiable(models.toList()..sort());
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

  void confirm(
    BuildContext context,
    ModalRoute<void>? route,
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
