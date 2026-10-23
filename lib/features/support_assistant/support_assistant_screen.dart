import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/shell/desktop/desktop_layout_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_scaffold.dart';
import '../../shared/widgets/glaze_error_block.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../../shared/widgets/sheet_view.dart';
import 'state/support_workspace_provider.dart';
import 'state/support_model_provider.dart';
import 'widgets/support_composer_bar.dart';
import 'widgets/support_message_list.dart';
import 'widgets/support_sessions_panel.dart';
import 'widgets/support_settings_panel.dart';
import 'widgets/support_model_screen_controller.dart';
import 'widgets/support_theme_entry.dart';
import 'widgets/support_provider_entry.dart';

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

  const SupportAssistantScreen({
    super.key,
    this.initialTopic,
    this.welcomeAvatar,
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
  bool _sheetOpen = false;

  @override
  void initState() {
    super.initState();
    _modelUi.addListener(_modelUiChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncTopicFromRoute());
  }

  void _modelUiChanged() {
    if (mounted) setState(() {});
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
        context.push('/menu/themes');
      case 'memory_books_setup':
        GlazeToast.show(
          context,
          'Memory Books настраиваются в нужной ролевой сессии. Переход к ним из ассистента пока недоступен; настройки не изменены.',
        );
      default:
        GlazeToast.show(context, 'Исполнитель этого действия пока недоступен.');
    }
  }

  @override
  Widget build(BuildContext context) {
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
        : _modelUi.bindView(bridge, _composerCtrl, workspace.activeSessionId);
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
        const SupportThemeEntry(),
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
              notice: const Padding(
                key: ValueKey('support_text_only_notice'),
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Модель отвечает только текстом после отдельного подтверждения '
                  'точного prompt. Выбор установленной темы, режим dark/light/system '
                  'и условный Undo доступны только через отдельное нативное '
                  'подтверждение. Подготовка профиля провайдера и отдельный '
                  'защищённый ввод ключа доступны в нативном окне провайдера; '
                  'они не выбирают активное подключение и не проверяют провайдера. '
                  'Memory, инструменты, DCP, '
                  'диагностика и экспорт отчётов '
                  'пока недоступны. Локальная помощь — отдельно, без сети.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              onQuickAction: _handleSetupCardAction,
              onApplyPlan: notifier.applyMutationPlan,
              onRollback: notifier.rollbackMutation,
              onSetupAction: _handleSetupCardAction,
            ),
          ),
          SupportComposerBar(
            controller: _composerCtrl,
            sessionId: workspace.activeSessionId,
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
            onNativeSend: emitter == null
                ? (_) => _modelUi.rejectNoModel()
                : (draft) => _modelUi.send(emitter, draft, context),
            onLocalHelp: notifier.sendLocalHelp,
            onStop: activeSend?.stop,
            onRunQuickDiagnostics: () =>
                _handleSetupCardAction('connection_diagnostics'),
          ),
        ],
      ),
    );
  }
}
