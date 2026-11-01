import 'dart:convert';
import 'package:flutter/material.dart';

import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../../chat/widgets/memory_sheet.dart';
import '../services/memory_setup/memory_setup_service.dart';
import '../state/support_memory_setup_controller.dart';

class SupportMemorySetupSheet extends StatefulWidget {
  const SupportMemorySetupSheet({super.key, required this.service});
  final MemorySetupService service;
  @override
  State<SupportMemorySetupSheet> createState() => _MemorySetupSheetState();
}

class _MemorySetupSheetState extends State<SupportMemorySetupSheet> {
  late final c = SupportMemorySetupController(widget.service);
  bool _memoryOpen = false;
  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    c.dispose();
    super.dispose();
  }

  Widget _action(String label, VoidCallback? tap, {Key? key}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    child: GlazeActionButton(
      key: key,
      label: label,
      maxLabelLines: null,
      icon: Icons.chevron_right_rounded,
      expand: true,
      onTap: c.busy || _memoryOpen || !widget.service.current ? null : tap,
    ),
  );

  Future<void> _openMemoryBooks() async {
    final target = widget.service.activeTarget;
    if (_memoryOpen || target == null || !target.isActiveOwner) return;
    setState(() => _memoryOpen = true);
    try {
      await showModalBottomSheet<void>(
        context: context,
        useRootNavigator: true,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => MemorySheet(
          charId: target.characterId,
          initialTab: MemoryTab.books,
          expectedSessionId: target.sessionId,
          isOwnerCurrent: () => target.isActiveOwner,
        ),
      );
    } finally {
      if (mounted) setState(() => _memoryOpen = false);
    }
  }

  @override
  Widget build(BuildContext context) => SheetView(
    title: 'Мастер Memory Books',
    body: Builder(
      builder: (context) => ListView(
        padding: EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top + 12,
          bottom: MediaQuery.paddingOf(context).bottom + 24,
        ),
        children: [
          const MenuGroup(
            header: 'Три независимые области',
            items: [
              Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Сессионная книга, глобальная автоматика/vector gate и глобальный LLM-слот применяются отдельно. '
                  'Глобальные изменения затронут другие сессии; их книги не переписываются. '
                  'Генерация, Scan и Approve не запускаются этим мастером. Ключи вводятся только в обычных настройках подключений.',
                ),
              ),
            ],
          ),
          if (!widget.service.current)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Исходный владелец или доступ изменились. Закрой мастер и открой заново.',
              ),
            ),
          if (!c.selected) ...[
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Выбери реально загруженную, свободную ролевую сессию:',
              ),
            ),
            for (final owner in widget.service.targets)
              _action(
              owner.sessionId,
                () => c.selectTarget(owner),
              key: ValueKey('memory_setup_target_${owner.sessionId}'),
              ),
            if (widget.service.targets.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Нет принадлежащего приложению свободного chat owner. Открой нужный чат; мастер не создаёт подменный контроллер.',
                ),
              ),
          ] else if (!c.finished)
            ..._question()
          else
            ..._plans(),
          if (c.busy) const Center(child: CircularProgressIndicator()),
          if (c.status case final text?)
            Padding(padding: const EdgeInsets.all(16), child: Text(text)),
          if (c.readiness case final r?)
            MenuGroup(
              header: 'Готовность: локальные факты, не live-тест',
              items: [
                for (final text in r.steps)
                  Padding(padding: const EdgeInsets.all(16), child: Text(text)),
              ],
            ),
        ],
      ),
    ),
  );

  List<Widget> _question() {
    final a = c.answers;
    return [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Text('Вопрос ${c.question + 1} из 5'),
      ),
      switch (c.question) {
        0 => MenuGroup(
          header: 'Как создавать черновики? (глобально)',
          items: [
            for (final value in MemorySetupAutomation.values)
              _choice(
                value.name,
                switch (value) {
                  MemorySetupAutomation.manual => 'Вручную',
                  MemorySetupAutomation.emptyDrafts =>
                    'Автоматически пустые черновики',
                  MemorySetupAutomation.llmDrafts =>
                    'Автоматически LLM-черновики (могут быть платными)',
                },
                a.automation == value,
                () => c.update(a.copyWith(automation: value)),
              ),
          ],
        ),
        1 => MenuGroup(
          header: 'Профиль извлечения этой книги',
          description:
              'Deep = все доступные локальные возможности Balanced; без платного reranker.',
          items: [
            for (final value in MemorySetupProfile.values)
              _choice(
                value.name,
                switch (value) {
                  MemorySetupProfile.economy => 'Экономия / Fast',
                  MemorySetupProfile.balanced => 'Баланс / Balanced',
                  MemorySetupProfile.detail => 'Подробно / Deep',
                },
                a.profile == value,
                () => c.update(a.copyWith(profile: value)),
              ),
          ],
        ),
        2 => MenuGroup(
          header: 'Верхний лимит инъекции этой книги',
          description:
              'Фактический доступный бюджет запроса может быть меньше.',
          items: [
            for (final value in const [1024, 2048, 4096])
              _choice(
                '$value',
                '$value токенов',
                a.tokens == value,
                () => c.update(a.copyWith(tokens: value)),
              ),
          ],
        ),
        3 => MenuGroup(
          header: 'Источник LLM-черновиков (глобальный слот)',
          items: [
            if (c.connections.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Доверенные сохранённые метаданные недоступны. Этот глобальный план не будет доступен.',
                ),
              ),
            for (final value in c.connections)
              _choice(
                value.label,
                value.label,
                identical(a.connection, value),
                () => c.update(a.copyWith(connection: value)),
              ),
          ],
        ),
        _ => MenuGroup(
          header: 'Как искать память?',
          description:
              'Keyword остаётся локальным. Семантика отдельно требует глобального gate и рабочего embedding-подключения.',
          items: [
            _choice(
              'keyword',
              'Ключевые слова',
              !a.semantic,
              () => c.update(a.copyWith(semantic: false)),
            ),
            _choice(
              'semantic',
              'Ключевые слова + семантика (ещё не проверена)',
              a.semantic,
              () => c.update(a.copyWith(semantic: true)),
            ),
          ],
        ),
      },
      _action(
        c.question == 4 ? 'К независимым планам' : 'Далее',
        c.next,
        key: const ValueKey('memory_setup_next'),
      ),
      if (c.question > 0) _action('Назад', c.back),
    ];
  }

  Widget _choice(String id, String label, bool selected, VoidCallback onTap) =>
      MenuItem(
        key: ValueKey('memory_setup_choice_$id'),
        label: label,
        icon: selected
            ? Icons.check_circle_outline
            : Icons.radio_button_unchecked,
        onTap: () {
          if (!c.busy && widget.service.current) onTap();
        },
      );

  List<Widget> _plans() => [
    for (final scope in MemorySetupScope.values) ...[
      _action(
        switch (scope) {
          MemorySetupScope.session => 'Обзор: только выбранная книга (SQLite)',
          MemorySetupScope.automation =>
            'Обзор: глобальные автоматика и vector gate',
          MemorySetupScope.draftConnection =>
            'Обзор: глобальный слот LLM-черновиков',
        },
        () => c.prepare(scope),
        key: ValueKey('memory_setup_plan_${scope.name}'),
      ),
      if (c.receipts.containsKey(scope))
        _action(
          'Свежий обзор Undo: ${scope.name}',
          () => c.prepareUndo(scope),
          key: ValueKey('memory_setup_undo_${scope.name}'),
        ),
    ],
    if (c.review case final r?)
      MenuGroup(
        header: r.isUndo
            ? 'Точный Undo — отдельное согласие'
            : 'Точный план — отдельное согласие',
        description:
            'Применяется только ${r.scope.name}. Другие области не включены.',
        items: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              'ДО\n${const JsonEncoder.withIndent("  ").convert(r.before)}\n\nПОСЛЕ\n${const JsonEncoder.withIndent("  ").convert(r.after)}',
            ),
          ),
          _action(
            r.isUndo
                ? 'Подтвердить только этот Undo'
                : 'Подтвердить только этот план',
            r.current ? () => c.confirm(r) : null,
            key: const ValueKey('memory_setup_confirm'),
          ),
        ],
      ),
    _action(
      'Проверить локальную готовность (без сети)',
      c.checkReadiness,
      key: const ValueKey('memory_setup_readiness'),
    ),
    _action(
      'Открыть Memory Books выбранной активной сессии',
      _openMemoryBooks,
      key: const ValueKey('memory_setup_open_books'),
    ),
    _action('Изменить ответы', c.back),
  ];
}
