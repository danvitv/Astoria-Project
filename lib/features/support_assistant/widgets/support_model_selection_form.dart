import 'package:flutter/material.dart';

import '../../../shared/widgets/menu_group.dart';

/// Choosing a local option edits the draft, not settings or provider authority.
class SupportModelSelectionForm extends StatefulWidget {
  const SupportModelSelectionForm({
    super.key,
    required this.initialModel,
    required this.models,
    required this.isCurrent,
    required this.onSelect,
  });

  final String initialModel;
  final List<String> models;
  final bool Function() isCurrent;
  final ValueChanged<String?> onSelect;

  @override
  State<SupportModelSelectionForm> createState() => _ModelSelectionState();
}

class _ModelSelectionState extends State<SupportModelSelectionForm> {
  late final _controller = TextEditingController(text: widget.initialModel);
  bool _expanded = false, _retired = false;

  bool get _current => mounted && !_retired && widget.isCurrent() && !_retired;

  void _toggle() {
    if (!_current) {
      return;
    }
    setState(() => _expanded = !_expanded);
  }

  void _choose(String model) {
    if (!_current) {
      return;
    }
    _expanded = false;
    _controller.text = model;
    if (_current) {
      setState(() {});
    }
  }

  void _save(String? model) {
    if (_current) {
      widget.onSelect(model);
    }
  }

  @override
  void deactivate() {
    _retired = true;
    super.deactivate();
  }

  @override
  void dispose() {
    _retired = true;
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !_current,
    child: MenuGroup(
      header: 'Выбор модели',
      description:
          'Список содержит уже сохранённые модели этого подключения, не каталог '
          'провайдера. Доступность не проверяется. Отправка модели и каждый точный '
          'prompt подтверждаются отдельно.',
      items: [
        MenuSelectorItem(
          key: const ValueKey('support_model_dropdown'),
          label: 'Сохранённые модели',
          currentValue: _controller.text.isEmpty
              ? 'Не выбрана'
              : _controller.text,
          onTap: _toggle,
        ),
        if (_expanded && widget.models.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Сохранённых моделей нет. Укажи идентификатор ниже.'),
          ),
        if (_expanded)
          for (final model in widget.models)
            MenuItem(
              key: ValueKey('support_model_option_$model'),
              label: model,
              onTap: () => _choose(model),
            ),
        MenuFieldItem(
          key: const ValueKey('support_model_manual_id'),
          label: 'Идентификатор модели',
          helper: 'Если нужной модели нет в списке, введи её ID вручную.',
          controller: _controller,
          onChanged: (_) {
            if (_current) {
              setState(() {});
            }
          },
        ),
        MenuItem(
          label: 'Сохранить идентификатор',
          onTap: () => _save(_controller.text.trim()),
        ),
        MenuItem(label: 'Без модели', onTap: () => _save(null)),
      ],
    ),
  );
}
