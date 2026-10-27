part of 'support_assistant_screen.dart';

extension _ScreenMessageActions on _SupportAssistantScreenState {
  Future<void> _openMessageMenu(SupportMessageItem message) async {
    if (_sheetOpen || !mounted) return;
    final lifetime = _messageMenuLifetime;
    final notifier = ref.read(supportWorkspaceProvider.notifier);
    final intent = notifier.captureMessageDeletion(
      message,
      isOriginalUiCurrent: () =>
          mounted && identical(lifetime, _messageMenuLifetime),
    );
    if (intent == null) return;
    final redactor = ref.read(secretRedactorProvider);
    final redaction = ref.read(secretRedactionCoordinatorProvider);
    final display = SupportMessageDisplayProjection(redactor: redactor);
    final workspace = ref.read(supportWorkspaceProvider);
    final run =
        workspace.settingsAvailable && workspace.settings.hasConfiguredModel
        ? ref.read(supportModelRunViewProvider)
        : const SupportModelRunView();
    final originalModel =
        workspace.settingsAvailable && workspace.settings.hasConfiguredModel
        ? ref.read(supportModelUiBridgeProvider)
        : null;
    bool editCurrent() => intent.isCurrent && originalModel?.view.busy != true;
    final shown = supportDisplayedMessageText(message, display, run);
    final copyable =
        !message.isLocked &&
        shown.isNotEmpty &&
        shown != SupportMessageDisplayProjection.tooLong &&
        shown != SupportMessageDisplayProjection.unavailable;
    final editable =
        message.role == SupportMessageRole.user &&
        !workspace.activeMessages.any(
          (m) =>
              m.role == SupportMessageRole.assistant &&
              m.runId != null &&
              !m.createdAt.isBefore(message.createdAt),
        ) &&
        !run.busy &&
        !message.isLocked &&
        message.status == 'complete' &&
        message.cards.isEmpty &&
        shown == message.body &&
        shown.length <= 8192;
    final navigator = Navigator.of(context, rootNavigator: true);
    _setSheetOpen(true);
    try {
      String? action;
      await GlazeBottomSheet.show<void>(
        context,
        title: message.role == SupportMessageRole.user
            ? 'Твоё сообщение'
            : 'Сообщение Астории',
        items: [
          if (copyable)
            BottomSheetItem(
              label: 'Копировать',
              icon: Icons.copy_rounded,
              onTap: () {
                if (intent.isCurrent) action = 'copy';
                navigator.pop();
              },
            ),
          if (editable)
            BottomSheetItem(
              label: 'Изменить сообщение',
              icon: Icons.edit_outlined,
              onTap: () {
                if (intent.isCurrent) action = 'edit';
                navigator.pop();
              },
            ),
          BottomSheetItem(
            label: 'Удалить сообщение',
            icon: Icons.delete_outline_rounded,
            isDestructive: true,
            onTap: () {
              if (intent.isCurrent) action = 'delete';
              navigator.pop();
            },
          ),
        ],
      );
      if (!mounted || !intent.isCurrent) return;
      if (action == 'copy') {
        // Reapply the CURRENT policy to the originally displayed text; a newly
        // registered secret must not reach the clipboard through an old menu.
        final currentDisplay = SupportMessageDisplayProjection(
          redactor: redaction.redactor,
        );
        final safe = currentDisplay.project(shown);
        if (!intent.isCurrent ||
            safe == SupportMessageDisplayProjection.tooLong ||
            safe == SupportMessageDisplayProjection.unavailable) {
          return;
        }
        try {
          await Clipboard.setData(ClipboardData(text: safe));
        } catch (_) {
          if (mounted && intent.isCurrent) {
            GlazeToast.show(context, 'Не удалось скопировать сообщение.');
          }
          return;
        }
        if (mounted && intent.isCurrent) {
          GlazeToast.show(context, 'Сообщение скопировано');
        }
      } else if (action == 'edit') {
        if (!editCurrent()) return;
        final body = await showSupportUserMessageEditor(
          context,
          initialText: shown,
          isCurrent: editCurrent,
        );
        if (!mounted || body == null || !editCurrent()) return;
        final saved = await notifier.editUserMessage(
          message,
          body,
          intent: intent,
        );
        if (!mounted || !identical(lifetime, _messageMenuLifetime)) return;
        if (!saved && intent.isCurrent) {
          GlazeToast.show(
            context,
            'Не удалось сохранить правку. Обнови историю.',
          );
        }
      } else if (action == 'delete') {
        await _confirmMessageDeletion(message, intent, notifier, lifetime);
      }
    } finally {
      if (mounted) _setSheetOpen(false);
    }
  }

  Future<void> _confirmMessageDeletion(
    SupportMessageItem message,
    SupportMessageDeletionIntent intent,
    SupportWorkspaceNotifier notifier,
    Object lifetime,
  ) async {
    if (!mounted || !intent.isCurrent) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    var confirmed = false;
    await GlazeBottomSheet.show<void>(
      context,
      title: 'Удалить это сообщение?',
      bigInfo: const BottomSheetBigInfo(
        icon: Icons.delete_outline_rounded,
        description:
            'Удалится только выбранное сообщение из чата Астории. '
            'Остальные сообщения останутся. Связанный активный ответ будет остановлен. '
            'Это не отменяет уже выполненные действия и не удаляет данные ролевых чатов. '
            'Если сообщение входит в старую сводку или связано с другим ответом, '
            'для продолжения может потребоваться новый чат.',
      ),
      items: [
        BottomSheetItem(
          label: 'Удалить',
          icon: Icons.delete_outline_rounded,
          isDestructive: true,
          onTap: () {
            confirmed = intent.isCurrent;
            navigator.pop();
          },
        ),
        BottomSheetItem(
          label: 'Отмена',
          icon: Icons.close_rounded,
          onTap: () => navigator.pop(),
        ),
      ],
    );
    if (!mounted || !confirmed || !intent.isCurrent) return;
    final deleted = await notifier.deleteMessage(message.id, intent: intent);
    if (!mounted || !identical(lifetime, _messageMenuLifetime)) return;
    if (!deleted && intent.isCurrent) {
      GlazeToast.show(context, 'Не удалось удалить сообщение. Обнови историю.');
    }
  }
}
