import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/glaze_spinner.dart';
import '../../../shared/widgets/glaze_tab_bar.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../../../core/constants/support_assistant_availability.dart';
import '../../support_assistant/support_assistant_screen.dart';
import '../chat_provider.dart';
import 'memory/memory_books_controls.dart';
import 'memory/memory_books_toolbar.dart';
import 'memory/memory_tab_store.dart';
import 'memory_books_tab.dart';
import 'summary_settings_sheet.dart';
import 'summary_tab.dart';

/// Tabs of the Memory sheet, in display order.
enum MemoryTab { summary, books }

/// Single home for everything session memory: the chat summary and the memory
/// books, behind one segmented control. Replaces the two separate Quick Access
/// entries that used to open them.
class MemorySheet extends ConsumerStatefulWidget {
  final String charId;

  /// Tab to open on. When null the sheet restores the tab it was closed on
  /// (see [MemoryTabStore]).
  final MemoryTab? initialTab;

  /// Optional native navigation binding. Check before watching chatProvider so
  /// a retired owner cannot bootstrap a replacement chat through this sheet.
  final String? expectedSessionId;
  final bool Function()? isOwnerCurrent;

  const MemorySheet({
    super.key,
    required this.charId,
    this.initialTab,
    this.expectedSessionId,
    this.isOwnerCurrent,
  });

  @override
  ConsumerState<MemorySheet> createState() => _MemorySheetState();
}

class _MemorySheetState extends ConsumerState<MemorySheet> {
  static const MemoryTabStore _tabStore = MemoryTabStore.memorySheet;

  /// Null until the remembered tab has been read back. The body shows a
  /// spinner until then rather than opening on Summary and jumping — which
  /// would also mount a tab the user never asked for.
  MemoryTab? _tab;

  /// Tabs the user has actually opened. Both stay mounted afterwards so
  /// switching back does not re-run their loads, but the untouched one is
  /// never built — the books tab queries an embedding status per entry on
  /// first build.
  final Set<MemoryTab> _visited = {};

  /// Published by [MemoryBooksTab] once it is mounted. The books tab owns the
  /// controller, so the sheet's header actions and FAB are driven from what
  /// the tab hands out rather than from the sheet reaching into it.
  MemoryBooksActions? _booksActions;
  bool _assistantOpen = false;

  /// Keep this ORIGINAL modal/tab/controller mounted beneath Astoria. Replacing
  /// the router location would discard it and make its finite native port stale.
  /// Navigation grants no read consent, edit authority or automatic book load.
  Future<void> _openAssistant() async {
    if (!mounted || _assistantOpen || widget.isOwnerCurrent?.call() == false) {
      return;
    }
    _assistantOpen = true;
    try {
      await Navigator.of(context, rootNavigator: true).push<void>(
        MaterialPageRoute<void>(
          builder: (_) =>
              const SupportAssistantScreen(returnToPreviousRoute: true),
        ),
      );
    } finally {
      if (mounted) _assistantOpen = false;
    }
  }

  @override
  void initState() {
    super.initState();
    final forced = widget.initialTab;
    if (forced != null) {
      _tab = forced;
      _visited.add(forced);
    } else {
      unawaited(_restoreTab());
    }
  }

  Future<void> _restoreTab() async {
    final index = await _tabStore.load(MemoryTab.values.length);
    if (!mounted) return;
    final tab = MemoryTab.values[index];
    setState(() {
      _tab = tab;
      _visited.add(tab);
    });
  }

  void _select(MemoryTab tab) {
    if (_tab == tab) return;
    setState(() {
      _tab = tab;
      _visited.add(tab);
    });
    unawaited(_tabStore.save(tab.index));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isOwnerCurrent?.call() == false) {
      return _unavailable();
    }
    final session = ref.watch(chatProvider(widget.charId)).value?.session;
    if (widget.expectedSessionId != null &&
        session?.id != widget.expectedSessionId) {
      return _unavailable();
    }
    final tab = _tab;

    return SheetView(
      title: 'memory_sheet_title'.tr(),
      showBack: true,
      headerBottom: GlazeTabBar(
        tabs: [
          GlazeTabItem(
            label: 'magic_summary'.tr(),
            icon: Icons.subject_rounded,
          ),
          GlazeTabItem(
            label: 'magic_memory_books'.tr(),
            icon: Icons.auto_stories_outlined,
          ),
        ],
        // Before the stored tab resolves the strip still has to show a
        // selection; it is replaced a frame later if the remembered tab differs.
        activeIndex: (tab ?? MemoryTab.summary).index,
        onChanged: (index) => _select(MemoryTab.values[index]),
      ),
      actions: [
        if (supportAssistantWorkspaceEnabled &&
            tab == MemoryTab.books &&
            _booksActions != null)
          SheetViewAction(
            icon: MemoryCircleButton(
              key: const ValueKey('memory_open_astoria'),
              icon: Icons.support_agent_rounded,
              label: 'Astoria',
              onTap: () => unawaited(_openAssistant()),
            ),
            tooltip: 'Astoria',
            onPressed: () => unawaited(_openAssistant()),
          ),
        if (tab == MemoryTab.summary && session != null)
          _summarySettingsAction(session.id),
        if (tab == MemoryTab.books && _booksActions != null)
          SheetViewAction(
            icon: MemoryCircleButton(
              icon: Icons.refresh_rounded,
              label: 'memory_books_btn_reindex'.tr(),
              onTap: _booksActions!.isReindexing
                  ? () {}
                  : _booksActions!.reindex,
            ),
            tooltip: 'memory_books_btn_reindex'.tr(),
            onPressed: _booksActions!.isReindexing
                ? () {}
                : _booksActions!.reindex,
          ),
        if (tab == MemoryTab.books && _booksActions != null)
          SheetViewAction(
            // Match the chat input bar's round glass controls.
            icon: MemoryCircleButton(
              icon: Icons.tune_rounded,
              label: 'memory_books_settings_title'.tr(),
              onTap: _booksActions!.openSettings,
            ),
            onPressed: _booksActions!.openSettings,
          ),
      ],
      floatingActionButton: tab == MemoryTab.books && _booksActions != null
          ? MemoryBooksActionsFab(
              onScanChat: _booksActions!.scanChat,
              onAddEntry: _booksActions!.addEntry,
              isReindexing: _booksActions!.isReindexing,
              onReindex: _booksActions!.reindex,
              onDeleteIndexes: _booksActions!.deleteIndexes,
              onScanBook: _booksActions!.scanBook,
              onDeleteAllDrafts: _booksActions!.deleteAllDrafts,
            )
          : null,
      body: session == null || tab == null
          ? const Center(child: GlazeSpinner())
          : IndexedStack(
              index: tab.index,
              sizing: StackFit.expand,
              children: [
                _visited.contains(MemoryTab.summary)
                    ? SummaryTab(charId: widget.charId)
                    : const SizedBox.shrink(),
                _visited.contains(MemoryTab.books)
                    ? MemoryBooksTab(
                        key: ValueKey(session.id),
                        sessionId: session.id,
                        charId: widget.charId,
                        messages: session.messages,
                        onActions: (actions) {
                          if (!mounted) return;
                          setState(() => _booksActions = actions);
                        },
                      )
                    : const SizedBox.shrink(),
              ],
            ),
    );
  }

  Widget _unavailable() => SheetView(
    title: 'memory_sheet_title'.tr(),
    showBack: true,
    body: const Center(
      child: Text(
        'Выбранная сессия больше не активна. Открой Memory Books из нужного чата.',
      ),
    ),
  );

  /// The Summary tab's settings, in the same place the Books tab keeps its
  /// own: one button in the header.
  ///
  /// This used to be a bare `Switch` for summary injection — one setting of
  /// the several the tab carried, promoted to the chrome because it was the
  /// one worth reaching quickly. It is in the sheet with the rest of them now
  /// ([SummarySettingsSheet]), which leaves the tab as the summary and the
  /// button that rewrites it.
  SheetViewAction _summarySettingsAction(String sessionId) {
    void open() => unawaited(
      SummarySettingsSheet.show(
        context,
        charId: widget.charId,
        sessionId: sessionId,
      ),
    );
    return SheetViewAction(
      icon: MemoryCircleButton(
        icon: Icons.tune_rounded,
        label: 'summary_settings_title'.tr(),
        onTap: open,
      ),
      onPressed: open,
    );
  }
}

Future<void> showMemorySheet(
  BuildContext context,
  String charId, {
  MemoryTab? initialTab,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => MemorySheet(charId: charId, initialTab: initialTab),
  );
}
