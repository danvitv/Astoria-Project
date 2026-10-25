import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/state/credential_vault_provider.dart';
import '../../shared/shell/desktop/desktop_layout_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_scaffold.dart';
import '../../shared/widgets/glaze_error_block.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/sheet_view.dart';
import '../settings/app_settings_provider.dart';
import 'state/support_workspace_provider.dart';
import 'state/support_model_provider.dart';
import 'widgets/support_composer_bar.dart';
import 'widgets/support_message_list.dart';
import 'widgets/support_sessions_panel.dart';
import 'widgets/support_settings_panel.dart';
import 'widgets/support_model_screen_controller.dart';
import 'services/app_control/backup/support_backup_native_ui.dart';
import 'widgets/support_theme_entry.dart';
import 'widgets/support_provider_entry.dart';
import 'widgets/support_guidance_sheet.dart';
import 'widgets/support_card_view.dart';
import 'widgets/support_send_settings_snapshot.dart';
import 'services/support_guidance_planner.dart';
import 'services/support_message_display_projection.dart';
import 'models/support_permission_scope.dart';
import 'state/support_native_provider.dart';

part 'support_screen_guidance.dart';

/// Center workspace screen for Astoria Assistant (`/support`).
///
/// On desktop (`>= 768px` unless `forceMobileLayout`), `DesktopShell` mounts
/// [SupportSessionsPanel] in the left sidebar and [SupportSettingsPanel] in the
/// right sidebar, so this screen renders only the center chat column without
/// nesting a second 3-column shell.
///
/// On mobile (`< 768px` or `forceMobileLayout`), this screen provides header
/// actions to open [SupportSessionsPanel] and [SupportSettingsPanel] in native
/// Glaze sheets (`SheetView`).
class SupportAssistantScreen extends ConsumerStatefulWidget {
  final String? initialTopic;

  /// Optional presentation-only avatar; no effect on native send authority.
  final Widget? welcomeAvatar;

  /// Framework SaveFile seam only; never a snapshot/source or approval override.
  final SupportBackupFileDialog backupFileDialog;

  const SupportAssistantScreen({
    super.key,
    this.initialTopic,
    this.welcomeAvatar,
    this.backupFileDialog = const SupportBackupPlatformFileDialog(),
  });

  @override
  ConsumerState<SupportAssistantScreen> createState() =>
      _SupportAssistantScreenState();
}

class _SupportAssistantScreenState
    extends ConsumerState<SupportAssistantScreen> {
  final TextEditingController _composerCtrl = TextEditingController();
  final SupportModelScreenController _modelUi = SupportModelScreenController();
  final _providerEntry = GlobalKey<SupportProviderEntryState>();
  final _themeEntry = GlobalKey<SupportThemeEntryState>();
  List<SupportGuidanceTarget> _guidance = const [];
  SupportComposerDraft? _guidanceDraft;
  String? _guidanceSession;
  Object? _guidanceController;
  int? _guidanceLifetime;
  bool _guidancePersistent = false, _guidanceBlocking = true;
  bool _showSendSnapshot = false;
  bool _sheetOpen = false;
  Object _messageMenuLifetime = Object();

  @override
  void deactivate() {
    _messageMenuLifetime = Object();
    super.deactivate();
  }

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
    final navigator = Navigator.of(context, rootNavigator: true);
    _sheetOpen = true;
    try {
      var deleteRequested = false;
      await GlazeBottomSheet.show<void>(
        context,
        title: message.role == SupportMessageRole.user
            ? 'Твоё сообщение'
            : 'Сообщение Астории',
        items: [
          BottomSheetItem(
            label: 'Удалить сообщение',
            icon: Icons.delete_outline_rounded,
            isDestructive: true,
            onTap: () {
              deleteRequested = intent.isCurrent;
              navigator.pop();
            },
          ),
        ],
      );
      if (!mounted || !deleteRequested || !intent.isCurrent) return;
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
      // Successful deletion intentionally retires the selected-row predicate.
      if (!mounted || !identical(lifetime, _messageMenuLifetime)) return;
      if (!deleted && intent.isCurrent) {
        GlazeToast.show(
          context,
          'Не удалось удалить сообщение. Обнови историю.',
        );
      }
    } finally {
      _sheetOpen = false;
    }
  }

  @override
  void initState() {
    super.initState();
    _modelUi.addListener(_modelUiChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncTopicFromRoute());
  }

  void _modelUiChanged() {
    if (mounted) setState(() {});
  }

  void _publishGuidance(
    List<SupportGuidanceTarget> targets,
    SupportComposerDraft? draft,
    String session, {
    bool blocking = true,
  }) {
    setState(() {
      _guidance = targets;
      _guidanceDraft = draft;
      _guidanceSession = session;
      final controller = ref.read(supportNativeConsentControllerProvider);
      _guidanceController = controller;
      _guidanceLifetime = controller.runtime.lifetime;
      _guidancePersistent = draft == null;
      _guidanceBlocking = blocking;
      _showSendSnapshot = true;
    });
  }

  void _retainGuidance() {
    setState(() => _guidancePersistent = true);
  }

  void _clearSendGuidance() {
    setState(() {
      _guidance = const [];
      _showSendSnapshot = false;
    });
  }

  @override
  void didUpdateWidget(covariant SupportAssistantScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTopic != widget.initialTopic) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _syncTopicFromRoute(),
      );
    }
  }

  void _syncTopicFromRoute() {
    if (!mounted) return;
    var topic = widget.initialTopic;
    if (topic == null || topic.isEmpty) {
      try {
        topic = GoRouterState.of(context).uri.queryParameters['topic'];
      } catch (_) {
        topic = null;
      }
    }
    if (topic != null && topic.isNotEmpty) {
      ref.read(supportWorkspaceProvider.notifier).applyInitialTopic(topic);
    }
  }

  @override
  void dispose() {
    _modelUi.removeListener(_modelUiChanged);
    _modelUi.dispose();
    _composerCtrl.dispose();
    super.dispose();
  }

  void _navigateBackToCharacters() {
    try {
      context.go('/characters');
    } catch (_) {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _openSessionsSheet() async {
    if (_sheetOpen || !mounted) return;
    _sheetOpen = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        useRootNavigator: true,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (sheetCtx) => SheetView(
          title: 'История сессий Астории',
          showBack: true,
          onBack: () => Navigator.of(sheetCtx).pop(),
          startExpanded: false,
          body: Builder(
            builder: (bodyContext) => Padding(
              padding: EdgeInsets.only(
                top: MediaQuery.paddingOf(bodyContext).top,
              ),
              child: SupportSessionsPanel(
                onSessionSelected: () => Navigator.of(sheetCtx).pop(),
                onBackToCharacters: () {
                  Navigator.of(sheetCtx).pop();
                  _navigateBackToCharacters();
                },
              ),
            ),
          ),
        ),
      );
    } finally {
      _sheetOpen = false;
    }
  }

  Future<void> _openSettingsSheet() async {
    if (_sheetOpen || !mounted) return;
    _sheetOpen = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        useRootNavigator: true,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (sheetCtx) => SheetView(
          title: 'Настройки Астории',
          showBack: true,
          onBack: () => Navigator.of(sheetCtx).pop(),
          startExpanded: false,
          body: Builder(
            builder: (bodyContext) => Padding(
              padding: EdgeInsets.only(
                top: MediaQuery.paddingOf(bodyContext).top,
              ),
              child: SupportSettingsPanel(
                onActionTriggered: () => Navigator.of(sheetCtx).pop(),
              ),
            ),
          ),
        ),
      );
    } finally {
      _sheetOpen = false;
    }
  }

  void _handleSetupCardAction(String topicId) {
    switch (topicId) {
      case 'provider_setup':
        _providerEntry.currentState?.open();
      case 'theme_setup':
        _themeEntry.currentState?.open();
      case 'memory_books_setup':
        GlazeToast.show(
          context,
          'Memory Books настраиваются в нужной ролевой сессии. Переход к ним из ассистента пока недоступен; настройки не изменены.',
        );
      case 'connection_diagnostics':
      case 'diagnostics':
        final workspace = ref.read(supportWorkspaceProvider);
        if (!workspace.settingsAvailable ||
            workspace.activeSessionId.isEmpty ||
            workspace.isBusy ||
            _modelUi.active != null) {
          return;
        }
        // A native start button is not a fabricated user message or a data grant.
        // Show the current snapshot/catalog invitation without writing history.
        _publishGuidance(
          const [SupportGuidanceTarget.gameSession],
          null,
          workspace.activeSessionId,
          blocking: false,
        );
      default:
        GlazeToast.show(context, 'Исполнитель этого действия пока недоступен.');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Runtime consent changes also expire idle emitters. Rebuild the displayed
    // composer so the NEXT explicit Send binds a fresh owner, never an old draft.
    ref.watch(supportNativeViewProvider);
    // Match the feed's current-policy body projection. Watching this snapshot
    // also refreshes idle emitters when policy changes but stored bodies do not.
    // Active original sends retain their existing snapshot and custody fences.
    final display = SupportMessageDisplayProjection(
      redactor: ref.watch(secretRedactorProvider),
    );
    final enterToSend = ref.watch(
      appSettingsProvider.select(
        (settings) => settings.asData?.value.enterToSend ?? false,
      ),
    );
    final isDesktop = isDesktopLayout(context);
    final workspace = ref.watch(supportWorkspaceProvider);
    final notifier = ref.read(supportWorkspaceProvider.notifier);
    final modelEnabled =
        workspace.settingsAvailable && workspace.settings.hasConfiguredModel;
    final bridge = modelEnabled
        ? ref.watch(supportModelUiBridgeProvider)
        : null;
    final run = modelEnabled
        ? ref.watch(supportModelRunViewProvider)
        : const SupportModelRunView();
    final emitter = bridge == null
        ? null
        : _modelUi.bindView(
            bridge,
            _composerCtrl,
            workspace.activeSessionId,
            nativeContext: context,
            backupFileDialog: widget.backupFileDialog,
            visibleConversation: [
              for (final message in workspace.activeMessages)
                if ((message.role == SupportMessageRole.user ||
                        message.role == SupportMessageRole.assistant) &&
                    const [
                      'complete',
                      'limited',
                      'stopped',
                      'error',
                    ].contains(message.status))
                  SupportModelConversationMessage(
                    id: message.id,
                    role: message.role.name,
                    text: display.project(message.body),
                  ),
            ],
          );
    if (bridge == null) _modelUi.retireView();
    final activeSend = _modelUi.active;
    final activeTitle = workspace.activeSession?.title ?? 'Астория Ассистент';

    return GlazeScaffold(
      title: activeTitle,
      showBack: true,
      onBack: _navigateBackToCharacters,
      showBackground: !isDesktop,
      flushHeader: isDesktop,
      actions: [
        SupportThemeEntry(key: _themeEntry),
        SupportProviderEntry(
          key: _providerEntry,
          onOpenPermissions: _openSettingsSheet,
        ),
        if (!isDesktop) ...[
          IconButton(
            key: const ValueKey('mobile_open_sessions_btn'),
            tooltip: 'История сессий',
            icon: Icon(
              Icons.history_rounded,
              size: 22,
              color: context.cs.primary,
            ),
            onPressed: _openSessionsSheet,
          ),
          IconButton(
            key: const ValueKey('mobile_open_settings_btn'),
            tooltip: 'Настройки Астории',
            icon: Icon(Icons.tune_rounded, size: 22, color: context.cs.primary),
            onPressed: _openSettingsSheet,
          ),
        ] else
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(
              child: Text(
                workspace.settingsAvailable
                    ? workspace.settings.mode.shortLabel
                    : 'Настройки недоступны',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: context.cs.primary,
                ),
              ),
            ),
          ),
      ],
      body: Column(
        children: [
          if (workspace.error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: GlazeErrorBlock(
                message: workspace.error!,
                label: 'Астория',
              ),
            ),
          if (!workspace.settingsAvailable)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Настройки сессии недоступны. Отправка заблокирована; открой настройки Астории.',
              ),
            ),
          if (run.label.isNotEmpty ||
              _modelUi.refusal != SupportModelRefusal.none)
            Padding(
              key: const ValueKey('support_model_run_status'),
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                _modelUi.refusal != SupportModelRefusal.none
                    ? _modelUi.refusal.label
                    : run.label,
              ),
            ),
          Expanded(
            child: SupportMessageList(
              messages: workspace.activeMessages,
              hasConfiguredModel: workspace.settings.hasConfiguredModel,
              run: run,
              welcomeAvatar: widget.welcomeAvatar,
              // Full capability copy scrolls with the feed instead of crowding
              // out the composer on narrow screens with large text.
              notice: Column(
                children: [
                  const Padding(
                    key: ValueKey('support_text_only_notice'),
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      '«Отправить» и Enter (если включён в общих настройках) сразу '
                      'отправляют вопрос и видимый текущий диалог выбранной модели. '
                      'Другие чаты и приватные источники требуют отдельных разрешений. '
                      'При нативном подключении модель может читать и менять безопасные '
                      'настройки интерфейса, энергосбережение и установленную тему без '
                      'повторного подтверждения отправки. Метаданные подключений доступны '
                      'без ключей; создание и ограниченные изменения профиля требуют точного '
                      'нативного подтверждения. Переход по разделам не изменяет их данные. '
                      'Защищённый ввод ключа остаётся отдельным нативным действием. '
                      'Диагностику можно обсудить без выбора игровой сессии. '
                      'Подключены конечные операции карточек, персон, лора, обычных и Studio-пресетов, '
                      'настроек Memory и отключения блока расширения с точным подтверждением. '
                      'Доступны метаданные сессий и диагностики, ограниченная проверка всех зарегистрированных '
                      'таблиц БД, выбранные скалярные исправления и условный Undo по сохранённой квитанции. '
                      'Collector/Ledger требуют существующего безопасного владельца сессии; спящие цели '
                      'могут быть недоступны. Проверка записанных хешей внутренняя, не оценка правды текста. '
                      'Чтение приватных тел, сборка каталога без отдельного разрешения, произвольное удаление, '
                      'каноническая перепись истории, экспорт и универсальное восстановление БД не подключены. '
                      'Компакт сжимает старый контекст выбранной моделью, не удаляя историю. '
                      'DCP автоматически запускает компакт при давлении на контекст; '
                      'внутри одного запроса также убирает точные дубли метаданных инструментов. '
                      'Между запросами сохраняются ответы, но не скрытый журнал инструментов. '
                      'счётчик показывает только токены из ответа провайдера. '
                      'Локальная помощь — отдельно, без сети.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  ..._pendingGuidance(workspace.activeSessionId),
                ],
              ),
              onQuickAction: _handleSetupCardAction,
              onApplyPlan: notifier.applyMutationPlan,
              onRollback: notifier.rollbackMutation,
              onSetupAction: _handleSetupCardAction,
              onGuidance: _openGuidance,
              onMessageMenu: _openMessageMenu,
            ),
          ),
          SupportComposerBar(
            controller: _composerCtrl,
            sessionId: workspace.activeSessionId,
            enterToSend: enterToSend,
            busy:
                workspace.isBusy ||
                workspace.isLoading ||
                run.busy ||
                activeSend != null,
            available:
                workspace.settingsAvailable &&
                workspace.activeSessionId.isNotEmpty,
            onSend: notifier.sendUserMessage,
            nativeOwner: emitter,
            onNativeSend: (draft) =>
                _sendWithGuidance(emitter, draft, workspace.activeSessionId),
            onLocalHelp: notifier.sendLocalHelp,
            onStop: activeSend?.stop,
            onCompact: emitter == null ? null : () => _modelUi.compact(emitter),
            usage: run.sessionId == workspace.activeSessionId
                ? run.usage
                : null,
            usageIsCompaction:
                run.sessionId == workspace.activeSessionId && run.isCompaction,
            onRunQuickDiagnostics: () =>
                _handleSetupCardAction('connection_diagnostics'),
          ),
        ],
      ),
    );
  }
}
