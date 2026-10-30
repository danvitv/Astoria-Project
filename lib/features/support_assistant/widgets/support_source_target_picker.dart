import 'package:flutter/material.dart';

import '../../../shared/widgets/glaze_action_button.dart';
import '../models/support_model_tool_ui_ports.dart';

/// One original sheet, with exact host-issued pages retained for local Back.
class SupportSourceTargetPicker extends StatefulWidget {
  const SupportSourceTargetPicker({
    super.key,
    required this.request,
    required this.isCurrent,
    required this.onInvalid,
    required this.onSelected,
  });
  final SupportSourceTargetSelectionRequest request;
  final bool Function() isCurrent;
  final VoidCallback onInvalid;
  final ValueChanged<SupportSourceTargetCandidate> onSelected;

  @override
  State<SupportSourceTargetPicker> createState() =>
      _SupportSourceTargetPickerState();
}

class _SupportSourceTargetPickerState extends State<SupportSourceTargetPicker> {
  late final _pages = [widget.request.initialPage];
  final _scroll = ScrollController();
  int _index = 0;
  bool _loading = false, _failed = false;
  bool get _current => mounted && widget.isCurrent() && widget.request.current;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _show(int index) {
    if (!_current) {
      widget.onInvalid();
      return;
    }
    setState(() => _index = index);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _next() async {
    if (_loading || !_current) return;
    if (_index + 1 < _pages.length) {
      _show(_index + 1);
      return;
    }
    final load = widget.request.loadNext;
    if (load == null || !_pages[_index].hasNext || _failed) return;
    setState(() => _loading = true);
    try {
      final page = await load(_pages[_index]);
      if (!_current) {
        if (mounted) widget.onInvalid();
        return;
      }
      if (page == null || page.candidates.length > 16) {
        setState(() => _failed = true);
        return;
      }
      _pages.add(page);
      _show(_index + 1);
    } catch (_) {
      if (!_current) {
        if (mounted) widget.onInvalid();
        return;
      }
      setState(() => _failed = true);
    } finally {
      if (_current) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = _pages[_index];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            key: const ValueKey('support_tool_confirmation_preview'),
            controller: _scroll,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Названия и даты остаются на этом экране. Выбор возвращает только ссылку на источник; чтение и передача модели требуют отдельного согласия.',
                ),
                const SizedBox(height: 12),
                if (page.candidates.isEmpty)
                  const Text(
                    'На этой странице нет подходящих сохранённых источников.',
                  ),
                for (var i = 0; i < page.candidates.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: GlazeActionButton(
                      key: ValueKey('support_source_target_$i'),
                      label:
                          '${page.candidates[i].label}\n${page.candidates[i].hint}',
                      maxLabelLines: null,
                      icon: Icons.source_outlined,
                      onTap: _loading
                          ? null
                          : () {
                              if (!_current) {
                                widget.onInvalid();
                                return;
                              }
                              widget.onSelected(page.candidates[i]);
                            },
                    ),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            children: [
              Text(
                'Страница ${_index + 1} · показана только проверенная часть каталога',
              ),
              if (_failed)
                const Text(
                  'Дальнейшая загрузка недоступна: достигнут предел навигации или источник не прошёл проверку. Можно вернуться или отменить выбор.',
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: GlazeActionButton(
                      key: const ValueKey('support_source_previous'),
                      label: 'Назад',
                      icon: Icons.chevron_left,
                      onTap: !_loading && _index > 0
                          ? () => _show(_index - 1)
                          : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GlazeActionButton(
                      key: const ValueKey('support_source_next'),
                      label: 'Далее',
                      icon: Icons.chevron_right,
                      busy: _loading,
                      onTap:
                          !_loading &&
                              (_index + 1 < _pages.length ||
                                  (!_failed && page.hasNext))
                          ? _next
                          : null,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
