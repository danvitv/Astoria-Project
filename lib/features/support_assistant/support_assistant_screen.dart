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
import 'widgets/support_composer_bar.dart';
import 'widgets/support_message_list.dart';
import 'widgets/support_sessions_panel.dart';
import 'widgets/support_settings_panel.dart';

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

  const SupportAssistantScreen({super.key, this.initialTopic});

  @override
  ConsumerState<SupportAssistantScreen> createState() =>
      _SupportAssistantScreenState();
}

class _SupportAssistantScreenState
    extends ConsumerState<SupportAssistantScreen> {
  final TextEditingController _composerCtrl = TextEditingController();
  bool _sheetOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncTopicFromRoute());
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
          body: Padding(
            padding: EdgeInsets.only(top: MediaQuery.paddingOf(sheetCtx).top),
            child: SupportSessionsPanel(
              onSessionSelected: () => Navigator.of(sheetCtx).pop(),
              onBackToCharacters: () {
                Navigator.of(sheetCtx).pop();
                _navigateBackToCharacters();
              },
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
          body: Padding(
            padding: EdgeInsets.only(top: MediaQuery.paddingOf(sheetCtx).top),
            child: SupportSettingsPanel(
              onActionTriggered: () => Navigator.of(sheetCtx).pop(),
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
        context.push('/tools/api');
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
    final activeTitle = workspace.activeSession?.title ?? 'Астория Ассистент';

    return GlazeScaffold(
      title: activeTitle,
      showBack: true,
      onBack: _navigateBackToCharacters,
      showBackground: !isDesktop,
      flushHeader: isDesktop,
      actions: [
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
          Expanded(
            child: SupportMessageList(
              messages: workspace.activeMessages,
              hasConfiguredModel: workspace.settings.hasConfiguredModel,
              onQuickAction: _handleSetupCardAction,
              onApplyPlan: notifier.applyMutationPlan,
              onRollback: notifier.rollbackMutation,
              onSetupAction: _handleSetupCardAction,
            ),
          ),
          SupportComposerBar(
            controller: _composerCtrl,
            sessionId: workspace.activeSessionId,
            busy: workspace.isBusy || workspace.isLoading,
            available:
                workspace.settingsAvailable &&
                workspace.activeSessionId.isNotEmpty,
            onSend: notifier.sendUserMessage,
            onRunQuickDiagnostics: () =>
                _handleSetupCardAction('connection_diagnostics'),
          ),
        ],
      ),
    );
  }
}
