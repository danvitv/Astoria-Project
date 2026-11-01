part of 'support_report_sheet.dart';

class _SupportReportPreviewBody extends StatelessWidget {
  const _SupportReportPreviewBody({
    required this.state,
    required this.selectionMessage,
    required this.onExclude,
    required this.onIncludeCurrent,
    required this.onIncludeGame,
    required this.onSafe,
  });
  final SupportReportUiState state;
  final String? selectionMessage;
  final void Function(String)? onExclude;
  final VoidCallback? onIncludeCurrent, onIncludeGame, onSafe;

  @override
  Widget build(BuildContext context) {
    final preview = state.preview;
    return SingleChildScrollView(
      key: const ValueKey('support_report_scroll'),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const MenuGroup(
            header: 'Только локальный файл',
            items: [
              Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'По умолчанию — безопасная диагностика без названий и текстов. '
                  'Никакой автоматической отправки, загрузки или передачи в Discord. '
                  'Сохранение — отдельное одноразовое действие через системный выбор файла.\n\n'
                  'До допуска сохранения байты репорта не записываются, но системный '
                  'выбор может создать пустой документ. Его удаление при отмене не гарантируется. Уже принятое '
                  'системой сохранение отменой не отзывается.\n\n'
                  'Если ты добавишь названия, историю и комментарии и поделишься файлом, '
                  'разработчик получит именно включённые тексты. Секреты исключаются. '
                  'Просмотр ниже — весь JSON, который будет зашифрован, не краткое описание. '
                  'Это ограниченный снимок schema 139; пропуски и усечение явно указаны, '
                  'а не обещание выгрузить всю историческую переписку.',
                ),
              ),
            ],
          ),
          if (state.message != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                state.message!,
                key: const ValueKey('support_report_message'),
              ),
            ),
          if (selectionMessage != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(selectionMessage!),
            ),
          if (state.busy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Подготовка или системное сохранение… Можно закрыть окно.',
              ),
            ),
          if (!state.finished)
            MenuGroup(
              header: 'Необязательное личное содержимое',
              items: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      GlazeActionButton(
                        key: const ValueKey('support_report_include_current'),
                        expand: true,
                        icon: Icons.chat_outlined,
                        label:
                            'Добавить текущий чат Астории: название, историю и комментарии',
                        maxLabelLines: null,
                        onTap: onIncludeCurrent,
                      ),
                      const SizedBox(height: 8),
                      GlazeActionButton(
                        key: const ValueKey('support_report_include_game'),
                        expand: true,
                        icon: Icons.games_outlined,
                        label:
                            'Выбрать одну игровую сессию: название и историю',
                        maxLabelLines: null,
                        onTap: onIncludeGame,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          if (preview != null && !preview.recipientConfigured)
            const MenuGroup(
              header: 'Сохранение недоступно: ключ получателя не настроен',
              items: [
                Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'В сборке нет публичного descriptor получателя. Оператор создаёт пару '
                    'ключей локальным CLI; приватная часть остаётся только у него. '
                    'Для включения сохранения нужно добавить публичный descriptor '
                    'в assets/support_report/recipient.json и пересобрать приложение. '
                    'Не присылай приватный ключ в чат. Пока можно просмотреть и исключить блоки; файл не создан.',
                  ),
                ),
              ],
            ),
          if (preview != null && !state.saveSupported)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'На этой платформе системное сохранение репорта пока недоступно. Файл не создан.',
              ),
            ),
          if (state.removed.isNotEmpty)
            MenuGroup(
              header: 'Исключены вместе с зависимыми блоками',
              items: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    state.removed.join('\n'),
                    key: const ValueKey('support_report_removed'),
                  ),
                ),
              ],
            ),
          if (preview != null) ...[
            MenuGroup(
              header: 'Все включённые блоки',
              items: [
                for (final block in preview.blocks)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '${block.title} · ${block.personal ? 'личное содержимое' : 'диагностика'}',
                        ),
                        if (block.dependencies.isNotEmpty)
                          Text('Зависит от: ${block.dependencies.join(', ')}'),
                        GlazeActionButton(
                          key: ValueKey('support_report_exclude_${block.id}'),
                          icon: Icons.remove_circle_outline,
                          label: 'Исключить блок и всё производное',
                          maxLabelLines: null,
                          onTap:
                              state.busy ||
                                  onExclude == null ||
                                  preview.isRetired
                              ? null
                              : () => onExclude!(block.id),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            if (preview.omissions.isNotEmpty)
              MenuGroup(
                header: 'Пропуски и ограничения',
                items: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(preview.omissions.join('\n')),
                  ),
                ],
              ),
            MenuGroup(
              header: 'Полное точное содержимое',
              items: [
                // Passive Text only: no Markdown, links, callbacks or networking.
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    preview.payloadJson,
                    key: const ValueKey('support_report_payload'),
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                  ),
                ),
              ],
            ),
          ],
          Padding(
            padding: const EdgeInsets.all(16),
            child: GlazeActionButton(
              key: const ValueKey('support_report_prepare_safe'),
              expand: true,
              icon: Icons.refresh,
              label: 'Новый снимок: только безопасная диагностика',
              maxLabelLines: null,
              onTap: onSafe,
            ),
          ),
        ],
      ),
    );
  }
}
