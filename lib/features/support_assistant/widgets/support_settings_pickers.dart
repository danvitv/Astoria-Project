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
    List<ApiConnectionMetadata> connections,
  ) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'Подключение Астории',
      items: [
        BottomSheetItem(
          label: 'Не выбрано',
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            notifier.selectConnection(null);
          },
        ),
        for (final connection in connections)
          BottomSheetItem(
            label: connection.displayName,
            hint: connection.configured
                ? 'Ключ: ${connection.characterCount} симв. • ${connection.protocol}'
                : 'Ключ не задан • ${connection.protocol}',
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              notifier.selectConnection(
                connection.connectionId,
                defaultModelId: connection.model,
              );
            },
          ),
      ],
    );
  }

  static void model(
    BuildContext context,
    SupportWorkspaceNotifier notifier,
    ApiConnectionMetadata? connection,
    SupportAssistantSettings settings,
  ) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'Модель Астории',
      child: _ManualModelForm(
        initialModel: settings.modelId ?? '',
        connectionModel: connection?.model,
        onSelect: (model) {
          Navigator.of(context, rootNavigator: true).pop();
          notifier.selectModel(model);
        },
      ),
    );
  }

  static void reasoning(
    BuildContext context,
    SupportWorkspaceNotifier notifier,
  ) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'Reasoning Effort',
      items: [
        for (final effort in SupportReasoningEffort.values)
          BottomSheetItem(
            label: effort.label,
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              notifier.setReasoningEffort(effort);
            },
          ),
      ],
    );
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
