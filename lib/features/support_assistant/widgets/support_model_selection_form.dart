import 'package:flutter/material.dart';
import 'package:dio/dio.dart';

import '../../../shared/widgets/menu_group.dart';

typedef SupportProviderModelLoader =
    Future<List<String>> Function({
      required bool Function() isCurrent,
      required CancelToken cancelToken,
    });

/// Choosing a provider option edits the draft, not settings or authority.
class SupportModelSelectionForm extends StatefulWidget {
  const SupportModelSelectionForm({
    super.key,
    required this.initialModel,
    required this.models,
    required this.isCurrent,
    required this.onSelect,
    this.loadModels,
  });

  final String initialModel;
  final List<String> models;
  final bool Function() isCurrent;
  final ValueChanged<String?> onSelect;
  final SupportProviderModelLoader? loadModels;

  @override
  State<SupportModelSelectionForm> createState() => _ModelSelectionState();
}

class _ModelSelectionState extends State<SupportModelSelectionForm> {
  late final _controller = TextEditingController(text: widget.initialModel);
  bool _expanded = false, _retired = false, _loading = false, _failed = false;
  late List<String> _models = widget.loadModels == null
      ? widget.models
      : const [];
  final _cancel = CancelToken();

  @override
  void initState() {
    super.initState();
    if (widget.loadModels != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  Future<void> _load() async {
    final loader = widget.loadModels;
    if (!_current || _loading || loader == null) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final models = await loader(
        isCurrent: () => _current,
        cancelToken: _cancel,
      );
      if (!_current) return;
      setState(() => _models = models);
    } catch (_) {
      if (_current) setState(() => _failed = true);
    } finally {
      if (_current) setState(() => _loading = false);
    }
  }

  bool get _current => mounted && !_retired && widget.isCurrent() && !_retired;

  void _toggle() {
    if (!_current) {
      return;
    }
    setState(() => _expanded = !_expanded);
    if (_failed) _load();
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
    _cancel.cancel();
    super.deactivate();
  }

  @override
  void dispose() {
    _retired = true;
    _cancel.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !_current,
    child: MenuGroup(
      header: 'Выбор модели',
      description:
          'Модели загружаются с выбранного провайдера. Открытие списка не отправляет '
          'prompt и не запускает генерацию. Отправка каждого точного prompt '
          'подтверждается отдельно.',
      items: [
        MenuSelectorItem(
          key: const ValueKey('support_model_dropdown'),
          label: 'Модели провайдера',
          currentValue: _controller.text.isEmpty
              ? 'Не выбрана'
              : _controller.text,
          onTap: _toggle,
        ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Загрузка моделей…'),
          ),
        if (_failed)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Не удалось загрузить модели. Нажми на список для повтора.',
            ),
          ),
        if (_expanded && !_loading && !_failed && _models.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Список моделей пуст. Укажи идентификатор ниже.'),
          ),
        if (_expanded)
          for (final model in _models)
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
