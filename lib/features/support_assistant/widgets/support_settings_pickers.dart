import 'package:flutter/material.dart';

import '../../../core/credentials/api_connection_metadata.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/menu_group.dart';
import '../state/support_workspace_provider.dart';

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
  }) {
    if (!intent.isCurrent) return;
    final confirmation = _SettingsPickerConfirmation(intent);
    GlazeBottomSheet.show<void>(
      context,
      title: 'Модель Астории',
      child: Builder(
        builder: (pickerContext) {
          final route = ModalRoute.of<void>(pickerContext);
          return _ManualModelForm(
            initialModel: settings.modelId ?? '',
            connectionModel: connection?.model,
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

class _ManualModelForm extends StatefulWidget {
  final String initialModel;
  final String? connectionModel;
  final ValueChanged<String?> onSelect;

  const _ManualModelForm({
    required this.initialModel,
    this.connectionModel,
    required this.onSelect,
  });

  @override
  State<_ManualModelForm> createState() => _ManualModelFormState();
}

class _ManualModelFormState extends State<_ManualModelForm> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialModel,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MenuGroup(
    header: 'Выбор модели',
    description:
        'Укажи идентификатор из настроек провайдера. Список моделей и доступность здесь не запрашиваются. Выбор не разрешает отправку: получатель и каждый точный текстовый prompt подтверждаются отдельно.',
    items: [
      if (widget.connectionModel case final model? when model.isNotEmpty)
        MenuItem(
          label: model,
          subtitle: 'Модель выбранного подключения',
          onTap: () => widget.onSelect(model),
        ),
      MenuFieldItem(label: 'Идентификатор модели', controller: _controller),
      MenuItem(
        label: 'Сохранить идентификатор',
        onTap: () => widget.onSelect(_controller.text.trim()),
      ),
      MenuItem(label: 'Без модели', onTap: () => widget.onSelect(null)),
    ],
  );
}
