import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/glaze_text_field.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../state/support_workspace_provider.dart';

/// Left panel for Astoria Assistant: session list, search, `+ New Session`,
/// pin/delete controls, and a back button to `/characters`.
class SupportSessionsPanel extends ConsumerStatefulWidget {
  final bool collapsed;
  final VoidCallback? onSessionSelected;
  final VoidCallback? onBackToCharacters;

  const SupportSessionsPanel({
    super.key,
    this.collapsed = false,
    this.onSessionSelected,
    this.onBackToCharacters,
  });

  @override
  ConsumerState<SupportSessionsPanel> createState() =>
      _SupportSessionsPanelState();
}

class _SupportSessionsPanelState extends ConsumerState<SupportSessionsPanel> {
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _goBack(BuildContext context) {
    if (widget.onBackToCharacters != null) {
      widget.onBackToCharacters!();
      return;
    }
    context.go('/characters');
  }

  @override
  Widget build(BuildContext context) {
    final workspace = ref.watch(supportWorkspaceProvider);
    final notifier = ref.read(supportWorkspaceProvider.notifier);

    if (widget.collapsed) {
      return _CollapsedSessionsStrip(
        onBack: () => _goBack(context),
        onHistory: () => showModalBottomSheet<void>(
          context: context,
          useRootNavigator: true,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (sheetContext) => SheetView(
            title: 'История сессий Астории',
            showBack: true,
            onBack: () => Navigator.of(sheetContext).pop(),
            body: Builder(
              builder: (bodyContext) => Padding(
                padding: EdgeInsets.only(
                  top: MediaQuery.paddingOf(bodyContext).top,
                ),
                child: SupportSessionsPanel(
                  onSessionSelected: () => Navigator.of(sheetContext).pop(),
                  onBackToCharacters: () {
                    Navigator.of(sheetContext).pop();
                    _goBack(context);
                  },
                ),
              ),
            ),
          ),
        ),
        onNewSession: () {
          notifier.createNewSession();
          widget.onSessionSelected?.call();
        },
      );
    }

    final sessions = workspace.filteredSessions;

    return Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Row(
              children: [
                IconButton(
                  key: const ValueKey('support_sessions_back_btn'),
                  tooltip: 'Назад к персонажам',
                  icon: Icon(
                    Icons.arrow_back_ios_new_rounded,
                    size: 18,
                    color: context.cs.primary,
                  ),
                  onPressed: () => _goBack(context),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'История Астории',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: context.cs.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: GlazeActionButton(
              key: const ValueKey('support_new_session_btn'),
              icon: Icons.add_comment_rounded,
              label: '+ Новая сессия',
              tone: GlazeActionTone.primary,
              expand: true,
              onTap: () {
                notifier.createNewSession();
                widget.onSessionSelected?.call();
              },
            ),
          ),
          const SizedBox(height: 8),
          Divider(height: 1, color: context.cs.outlineVariant),
          GlazeTextField(
            key: const ValueKey('support_session_search_input'),
            controller: _searchCtrl,
            onChanged: notifier.setSessionSearchQuery,
            hint: 'Поиск по сессиям…',
            isDense: true,
          ),
          Divider(height: 1, color: context.cs.outlineVariant),
          Expanded(
            child: sessions.isEmpty
                ? Center(
                    child: Text(
                      'Сессии не найдены',
                      style: TextStyle(
                        fontSize: 13,
                        color: context.cs.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    itemCount: sessions.length,
                    itemBuilder: (context, index) {
                      final session = sessions[index];
                      return _SupportSessionRow(
                        session: session,
                        active: session.id == workspace.activeSessionId,
                        onSelect: () {
                          notifier.selectSession(session.id);
                          widget.onSessionSelected?.call();
                        },
                        onTogglePin: () =>
                            notifier.togglePinSession(session.id),
                        onDelete: () => notifier.deleteSession(session.id),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _CollapsedSessionsStrip extends StatelessWidget {
  final VoidCallback onBack;
  final VoidCallback onHistory;
  final VoidCallback onNewSession;

  const _CollapsedSessionsStrip({
    required this.onBack,
    required this.onHistory,
    required this.onNewSession,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Column(
        children: [
          const SizedBox(height: 8),
          IconButton(
            tooltip: 'К персонажам',
            icon: Icon(
              Icons.arrow_back_ios_new_rounded,
              size: 20,
              color: context.cs.primary,
            ),
            onPressed: onBack,
          ),
          IconButton(
            key: const ValueKey('support_collapsed_history_btn'),
            tooltip: 'История сессий',
            icon: const Icon(Icons.history_rounded, size: 20),
            onPressed: onHistory,
          ),
          IconButton(
            tooltip: '+ Новая сессия',
            icon: Icon(
              Icons.add_comment_rounded,
              size: 20,
              color: context.cs.primary,
            ),
            onPressed: onNewSession,
          ),
        ],
      ),
    );
  }
}

class _SupportSessionRow extends StatelessWidget {
  final SupportSessionSummary session;
  final bool active;
  final VoidCallback onSelect;
  final VoidCallback onTogglePin;
  final VoidCallback onDelete;

  const _SupportSessionRow({
    required this.session,
    required this.active,
    required this.onSelect,
    required this.onTogglePin,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('support_session_row_${session.id}'),
          borderRadius: BorderRadius.circular(12),
          onTap: onSelect,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: active
                  ? context.cs.primary.withValues(alpha: 0.16)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: active
                    ? context.cs.primary.withValues(alpha: 0.35)
                    : Colors.transparent,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    session.pinned
                        ? Icons.push_pin_rounded
                        : Icons.chat_bubble_outline_rounded,
                    size: 16,
                    color: active || session.pinned
                        ? context.cs.primary
                        : context.cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      session.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                        color: active
                            ? context.cs.onSurface
                            : context.cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  IconButton(
                    key: ValueKey('pin_session_${session.id}'),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    icon: Icon(
                      session.pinned
                          ? Icons.push_pin_rounded
                          : Icons.push_pin_outlined,
                      size: 15,
                      color: session.pinned
                          ? context.cs.primary
                          : context.cs.onSurfaceVariant,
                    ),
                    onPressed: onTogglePin,
                  ),
                  IconButton(
                    key: ValueKey('delete_session_${session.id}'),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    icon: Icon(
                      Icons.delete_outline_rounded,
                      size: 15,
                      color: context.cs.error,
                    ),
                    onPressed: onDelete,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
