import 'dart:async';

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/memory_book.dart';
import '../../../core/models/memory_book_api_settings.dart';
import '../../../core/models/memory_consolidation.dart';
import '../../../core/credentials/memory_custom_api_credential_owner.dart';
import '../../../core/db/app_db.dart';
import '../../../core/llm/memory_book_api_config_resolver.dart';
import '../../../core/llm/memory_consolidation_batch_planner.dart';
import '../../../core/llm/memory_retrieval_mode.dart';
import '../../../core/services/memory_consolidation_batch_service.dart';
import '../../../core/services/memory_consolidation_coordinator.dart';
import '../../../core/services/generation_notification_service.dart';
import '../../../core/utils/error_format.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/lorebook_embedding_provider.dart';
import '../../../core/state/memory_settings_provider.dart';
import '../../../core/state/memory_custom_api_credentials_provider.dart';
import '../../../core/llm/memory_draft_api_source.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/glaze_expansion_tile.dart';
import '../../../shared/widgets/glaze_error_dialog.dart';
import '../../../shared/widgets/glaze_filter_chip_bar.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../../shared/widgets/glaze_tab_bar.dart';
import '../../../shared/widgets/glaze_text_field.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/swipe_tab_switcher.dart';
import '../../../shared/widgets/tab_slide_switcher.dart';
import '../../memory/controllers/memory_book_controller.dart';
import '../../memory/state/memory_book_revision_provider.dart';
import '../../memory/state/memory_consolidation_worker_provider.dart';
import '../../memory/state/memory_draft_jobs_provider.dart';
import '../../settings/api_list_provider.dart';
import 'memory/memory_books_controls.dart';
import 'memory/memory_books_toolbar.dart';
import 'memory/memory_consolidation_status.dart';
import 'memory/memory_draft_card.dart';
import 'memory/memory_entry_card.dart';
import 'memory/memory_event_registry_view.dart';
import 'memory/memory_tab_store.dart';
import 'memory_entry_editor_sheet.dart';
import 'memory_generation_settings_sheet.dart';

/// What an approved entry can be narrowed to. The counters that used to be
/// three read-only tiles are these chips: the number is still on screen, and
/// it now does something.
enum _EntryFilter { all, active, needsRebuild }

/// The same for drafts — the three states a draft is actually triaged by.
enum _DraftFilter { all, ready, needsGeneration, failed }

String _eventKindLabel(String value) => memoryEventKindLabel(value);

String _eventStateLabel(String value) => memoryEventStateLabel(value);

String _relationLabel(String value) => memoryEventRelationLabel(value);

/// What the host sheet drives from its own chrome: header actions and the
/// extended FAB over the list. The tab owns the controller, so
/// it hands these out once it is mounted rather than the sheet reaching into
/// it.
class MemoryBooksActions {
  final VoidCallback openSettings;
  final VoidCallback scanChat;
  final VoidCallback addEntry;
  final VoidCallback reindex;
  final VoidCallback deleteIndexes;
  final VoidCallback? scanBook;
  final VoidCallback? showRegistry;
  final VoidCallback? deleteAllDrafts;
  final bool isReindexing;

  const MemoryBooksActions({
    required this.openSettings,
    required this.scanChat,
    required this.addEntry,
    required this.reindex,
    required this.deleteIndexes,
    required this.scanBook,
    required this.showRegistry,
    required this.deleteAllDrafts,
    required this.isReindexing,
  });

  /// Whether [other] would render the same chrome. The callbacks are stable
  /// behaviour of the tab's state, so only the values the chrome reads can
  /// differ — publishing a new set that matches the old one changes nothing on
  /// screen.
  bool sameChrome(MemoryBooksActions other) =>
      isReindexing == other.isReindexing &&
      (scanBook == null) == (other.scanBook == null) &&
      (showRegistry == null) == (other.showRegistry == null) &&
      (deleteAllDrafts == null) == (other.deleteAllDrafts == null);
}

/// Memory Books tab of the Memory sheet — "Shelf" layout.
///
/// The tab strip is pinned above the list, so it stays reachable while
/// scrolling and stays off `TopEdgeBlur`'s raster path; the configuration, the
/// toolbar and the rows scroll under it. The search button on its right swaps
/// that strip for a search bar, and the list below it for one that spans both
/// tabs. Expects a bounded height from its host.
class MemoryBooksTab extends ConsumerStatefulWidget {
  final String sessionId;
  final String charId;
  final List<ChatMessage> messages;

  /// Published whenever the set changes, so the host sheet can render the
  /// header button and the FAB from it.
  final ValueChanged<MemoryBooksActions>? onActions;

  const MemoryBooksTab({
    super.key,
    required this.sessionId,
    required this.charId,
    this.messages = const [],
    this.onActions,
  });

  @override
  ConsumerState<MemoryBooksTab> createState() => _MemoryBooksTabState();
}

class _MemoryBooksTabState extends ConsumerState<MemoryBooksTab> {
  static const int _tabCount = 2;
  static const int _tabApproved = 0;
  static const MemoryTabStore _tabStore = MemoryTabStore.memoryBooks;

  late final MemoryBookController _ctrl;
  late final TextEditingController _searchCtrl;
  late final FocusNode _searchFocus;
  Map<String, String> _embeddingStatuses = {};
  int _tabIndex = _tabApproved;

  /// Whether the pinned row is the search bar rather than the tab strip.
  /// While it is, the list underneath is neither tab: it is everything the
  /// query matches, approved memories and drafts together.
  bool _searching = false;

  String _query = '';
  _EntryFilter _entryFilter = _EntryFilter.all;
  _DraftFilter _draftFilter = _DraftFilter.all;

  /// The generation failure this tab has already put in a toast. Failures are
  /// published as state rather than handed to a callback, because the request
  /// may well outlive the sheet that started it; this is what keeps a reopened
  /// sheet from re-announcing one it already showed — or one that happened
  /// while it was closed, which the draft's own row already carries.
  int _reportedFailureSeq = 0;

  /// The last [MemoryBooksActions] handed to the host, so an unchanged set is
  /// not republished. The host rebuilds from these, and publishing from
  /// `build` means that rebuild runs this `build` again: without the guard the
  /// sheet setState'd itself on every frame and never settled.
  MemoryBooksActions? _publishedActions;
  bool _reindexRequested = false;
  CancelToken? _consolidationCancelToken;
  String? _consolidatingEntryId;
  int _consolidationEpoch = 0;

  /// Fences short UI mutations (review, retry, cancel) without taking
  /// ownership of durable package execution.
  int _packageEpoch = 0;
  String? _packageJobId;

  /// Fences the one-time scan's estimate and durable enqueue. The app-scoped
  /// worker owns every model request after those rows exist.
  int _scanEpoch = 0;
  bool _scanRunning = false;

  @override
  void initState() {
    super.initState();
    _ctrl = MemoryBookController(ref, widget.sessionId, widget.charId);
    final originalSession = widget.sessionId, originalCharacter = widget.charId;
    _ctrl.bindNativeLifetime(
      changed: () {
        if (mounted) setState(() {});
      },
      isCurrent: () =>
          mounted &&
          widget.sessionId == originalSession &&
          widget.charId == originalCharacter,
    );
    _searchCtrl = TextEditingController();
    _searchFocus = FocusNode();
    _reportedFailureSeq =
        ref.read(memoryDraftJobsProvider).lastFailure?.seq ?? 0;
    _load();
  }

  Future<void> _load() async {
    // Both reads are independent, so the prefs round-trip runs alongside the
    // book load instead of delaying it.
    final bookLoad = _ctrl.load();
    final storedTab = await _tabStore.load(_tabCount);
    await bookLoad;
    if (!mounted) return;
    unawaited(_loadEmbeddingStatuses());
    setState(() => _tabIndex = storedTab);
  }

  Future<void> _loadEmbeddingStatuses() async {
    final repo = ref.read(embeddingRepoProvider);
    final book = _ctrl.book;
    if (book == null) return;
    final statuses = <String, String>{};
    for (final entry in book.entries) {
      final record = await repo.getByEntryId(entry.id);
      if (record == null) {
        statuses[entry.id] = 'none';
      } else if (record.errorJson != null) {
        statuses[entry.id] = 'error';
      } else if (repo.hasUsableVectors(record)) {
        statuses[entry.id] = 'indexed';
      } else {
        statuses[entry.id] = 'none';
      }
    }
    if (mounted) setState(() => _embeddingStatuses = statuses);
  }

  @override
  void dispose() {
    _consolidationEpoch++;
    _consolidationCancelToken?.cancel('Memory Books tab disposed');
    _packageEpoch++;
    _scanEpoch++;
    _ctrl.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant MemoryBooksTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId ||
        oldWidget.charId != widget.charId) {
      _consolidationEpoch++;
      _consolidationCancelToken?.cancel('Memory Books context changed');
      _consolidationCancelToken = null;
      _consolidatingEntryId = null;
      _packageEpoch++;
      _packageJobId = null;
      _scanEpoch++;
      _scanRunning = false;
      // This State owns a final controller. A -> B -> A cannot resurrect it.
      _ctrl.dispose();
    }
  }

  /// Switching sub-tabs also persists the choice, so reopening the sheet comes
  /// up on the list that was last in use.
  void _setTab(int index) {
    if (index == _tabIndex) return;
    setState(() => _tabIndex = index);
    unawaited(_tabStore.save(index));
  }

  /// Swaps the tab strip for the search bar. The tab the reader was on is
  /// kept, not reset — closing the search puts them back on it.
  void _openSearch() {
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  /// The cross on the right of the search bar: drops the query with the bar,
  /// so the list that comes back is not silently narrowed by a search that is
  /// no longer on screen.
  void _closeSearch() {
    _searchCtrl.clear();
    _searchFocus.unfocus();
    setState(() {
      _searching = false;
      _query = '';
    });
  }

  // ─── Filtering ───────────────────────────────────────────────────

  /// Matches the title, the body and the keys — the three places a memory can
  /// be recognised from. Case-insensitive; an empty query matches everything.
  bool _matchesQuery(String title, String content, List<String> keys) {
    if (_query.isEmpty) return true;
    final needle = _query.toLowerCase();
    if (title.toLowerCase().contains(needle)) return true;
    if (content.toLowerCase().contains(needle)) return true;
    return keys.any((key) => key.toLowerCase().contains(needle));
  }

  bool _passesEntryFilter(MemoryEntry entry) => switch (_entryFilter) {
    _EntryFilter.all => true,
    _EntryFilter.active => entry.status == 'active',
    _EntryFilter.needsRebuild => entry.status == 'needs_rebuild',
  };

  bool _passesDraftFilter(MemoryDraft draft) => switch (_draftFilter) {
    _DraftFilter.all => true,
    _DraftFilter.ready => draft.content.isNotEmpty,
    _DraftFilter.needsGeneration =>
      draft.content.isEmpty && draft.status == 'pending_generation',
    _DraftFilter.failed => draft.status == 'needs_regeneration',
  };

  String _entryFilterLabel(_EntryFilter filter, List<MemoryEntry> entries) {
    final count = switch (filter) {
      _EntryFilter.all => entries.length,
      _EntryFilter.active => entries.where((e) => e.status == 'active').length,
      _EntryFilter.needsRebuild =>
        entries.where((e) => e.status == 'needs_rebuild').length,
    };
    final label = switch (filter) {
      _EntryFilter.all => 'memory_books_filter_all'.tr(),
      _EntryFilter.active => 'memory_books_filter_active'.tr(),
      _EntryFilter.needsRebuild => 'memory_books_filter_rebuild'.tr(),
    };
    return '$label $count';
  }

  String _draftFilterLabel(_DraftFilter filter, List<MemoryDraft> drafts) {
    final count = switch (filter) {
      _DraftFilter.all => drafts.length,
      _DraftFilter.ready => drafts.where((d) => d.content.isNotEmpty).length,
      _DraftFilter.needsGeneration =>
        drafts
            .where((d) => d.content.isEmpty && d.status == 'pending_generation')
            .length,
      _DraftFilter.failed =>
        drafts.where((d) => d.status == 'needs_regeneration').length,
    };
    final label = switch (filter) {
      _DraftFilter.all => 'memory_books_filter_all'.tr(),
      _DraftFilter.ready => 'memory_books_filter_ready'.tr(),
      _DraftFilter.needsGeneration => 'memory_books_filter_drafts'.tr(),
      _DraftFilter.failed => 'memory_books_filter_failed'.tr(),
    };
    return '$label $count';
  }

  // ─── Build ───────────────────────────────────────────────────────

  /// Published after the frame, never during build: the host rebuilds on it.
  void _publishActions(int draftCount) {
    final publish = widget.onActions;
    if (publish == null) return;
    final actions = MemoryBooksActions(
      openSettings: _openSettings,
      scanChat: _scanChat,
      addEntry: _addEntry,
      reindex: _reindexAll,
      deleteIndexes: _deleteAllMemoryIndexes,
      scanBook:
          MemoryRetrievalMode.fromValue(
            _ctrl.book?.settings.memoryMode ?? 'fast',
          ).isConsolidationMode
          ? _startBookScan
          : null,
      showRegistry:
          MemoryRetrievalMode.fromValue(
            _ctrl.book?.settings.memoryMode ?? 'fast',
          ).isConsolidationMode
          ? _showEventRegistry
          : null,
      deleteAllDrafts: draftCount > 1 ? _deleteAllDrafts : null,
      isReindexing: _reindexRequested,
    );
    final published = _publishedActions;
    if (published != null && published.sameChrome(actions)) return;
    _publishedActions = actions;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) publish(actions);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Both of these change from outside this widget: a generation keeps
    // running when the sheet is closed, and the auto-create stage writes
    // drafts during a chat turn.
    ref.listen(memoryBookRevisionProvider, (_, _) => unawaited(_reloadBook()));
    ref.listen(
      memoryDraftJobsProvider.select((jobs) => jobs.lastFailure),
      (_, failure) => _reportFailure(failure),
    );

    final book = _ctrl.book;
    final loading = _ctrl.loading || book == null;
    if (loading) return const Center(child: GlazeSpinner());

    // Studio Ledger entries (`source == 'studio_ledger'`) are legacy and
    // excluded from the UI — they were removed from the injection pipeline.
    final curatedEntries = book.entries
        .where((e) => e.source != 'studio_ledger')
        .toList();
    final scanDrafts = book.pendingDrafts
        .where((d) => d.source != 'studio_ledger')
        .toList();

    final draftsNeedingGen = _ctrl.draftsNeedingGeneration;
    // Watched, not read: the rows, the batch panel and the FAB all follow a
    // run that this widget does not own.
    final isGenerating = ref
        .watch(memoryDraftJobsProvider)
        .isBusy(widget.sessionId);
    _publishActions(scanDrafts.length);

    return Column(
      children: [
        // The host sheet reports its header height as MediaQuery top padding;
        // the pinned controls start below it so they do not sit under the
        // blurred strip the sheet paints over the top of its body.
        SizedBox(height: MediaQuery.paddingOf(context).top + 8),
        _buildPinnedControls(curatedEntries, scanDrafts),
        Expanded(
          child: _searching
              ? _buildSearchResults(curatedEntries, scanDrafts)
              : _buildTabbedList(
                  entries: curatedEntries,
                  drafts: scanDrafts,
                  pendingGeneration: draftsNeedingGen.length,
                  isGenerating: isGenerating,
                ),
        ),
      ],
    );
  }

  /// The two-tab body: one list, showing whichever tab is selected, with the
  /// batch panel and the status filter scrolling above it.
  Widget _buildTabbedList({
    required List<MemoryEntry> entries,
    required List<MemoryDraft> drafts,
    required int pendingGeneration,
    required bool isGenerating,
  }) {
    return SwipeTabSwitcher(
      index: _tabIndex,
      length: _tabCount,
      onChanged: _setTab,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          0,
          4,
          0,
          // Clears the nav bar and the extended FAB the host floats over the
          // bottom of this list.
          MediaQuery.paddingOf(context).bottom + 88,
        ),
        children: [
          // Drafts only. On the approved tab there is nothing to generate, so
          // this was a panel about the other list.
          if (_tabIndex != _tabApproved &&
              (pendingGeneration > 0 || isGenerating))
            MemoryBatchPanel(
              pendingCount: pendingGeneration,
              isGenerating: isGenerating,
              // The global settings, not the book's snapshot: the global copy
              // is what `MemoryDraftStage` actually gates auto-generation on.
              autoGenerateEnabled: ref
                  .watch(memoryGlobalSettingsProvider)
                  .autoGenerateEnabled,
              onGenerateBatch: _batchGenerate,
            ),
          // Under the batch panel, not above it: the filter narrows the list
          // it sits on top of, and the panel is about the queue.
          _buildFilters(entries, drafts),
          TabSlideSwitcher(
            index: _tabIndex,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _tabIndex == _tabApproved
                  ? _buildApprovedTab(entries)
                  : _buildDraftsTab(drafts),
            ),
          ),
        ],
      ),
    );
  }

  /// The one pinned row above the list: the tab strip with a search button on
  /// its right, or — once that button is pressed — the search bar that takes
  /// the row's place, with the cross that gives it back.
  ///
  /// The strip is [GlazeTabBarStyle.underline], not the default pill: the host
  /// sheet already carries a filled pill strip for Summary/Books directly
  /// above this one, and two identical controls stacked read as one broken
  /// control. Underline is the kit's answer for a strip that heads a surface
  /// it does not own.
  Widget _buildPinnedControls(
    List<MemoryEntry> entries,
    List<MemoryDraft> drafts,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: _searching ? _buildSearchBar() : _buildTabStrip(entries, drafts),
    );
  }

  Widget _buildTabStrip(List<MemoryEntry> entries, List<MemoryDraft> drafts) {
    return Row(
      children: [
        Expanded(
          child: GlazeTabBar(
            style: GlazeTabBarStyle.underline,
            tabs: [
              GlazeTabItem(
                label: 'memory_books_tab_approved'.tr(
                  args: ['${entries.length}'],
                ),
                icon: Icons.check_circle_outline_rounded,
              ),
              GlazeTabItem(
                label: 'memory_books_tab_scan_drafts'.tr(
                  args: ['${drafts.length}'],
                ),
                icon: Icons.drafts_outlined,
              ),
            ],
            activeIndex: _tabIndex,
            onChanged: _setTab,
          ),
        ),
        const SizedBox(width: 8),
        MemoryCircleButton(
          icon: Icons.search_rounded,
          label: 'memory_books_search_open'.tr(),
          onTap: _openSearch,
        ),
      ],
    );
  }

  /// The search bar that replaces the strip. The cross sits where the search
  /// button was, so the control the reader just pressed is the control that
  /// undoes it.
  Widget _buildSearchBar() {
    return Row(
      children: [
        Expanded(
          child: GlazeTextField(
            controller: _searchCtrl,
            focusNode: _searchFocus,
            hint: 'memory_books_search_hint'.tr(),
            isDense: true,
            textInputAction: TextInputAction.search,
            onChanged: (value) => setState(() => _query = value.trim()),
          ),
        ),
        const SizedBox(width: 8),
        MemoryCircleButton(
          icon: Icons.close_rounded,
          label: 'memory_books_search_close'.tr(),
          onTap: _closeSearch,
        ),
      ],
    );
  }

  /// Search results: one list across both tabs, approved memories first and
  /// then the drafts, each row saying which it is under its title. Searching
  /// for a memory you half remember is not a question about which tab it ended
  /// up on, so the tab filters and the batch panel stay out of it.
  Widget _buildSearchResults(
    List<MemoryEntry> entries,
    List<MemoryDraft> drafts,
  ) {
    final vectorAvailable = ref.watch(vectorSearchAvailableProvider);
    final visibleEntries = entries
        .where((entry) => _matchesQuery(entry.title, entry.content, entry.keys))
        .toList();
    final visibleDrafts = drafts
        .where((draft) => _matchesQuery(draft.title, draft.content, draft.keys))
        .toList();
    final empty = visibleEntries.isEmpty && visibleDrafts.isEmpty;
    return ListView(
      padding: EdgeInsets.fromLTRB(
        16,
        8,
        16,
        // Clears the nav bar and the extended FAB the host floats over the
        // bottom of this list.
        MediaQuery.paddingOf(context).bottom + 88,
      ),
      children: [
        if (empty)
          _buildEmpty(
            entries.isEmpty && drafts.isEmpty
                ? 'memory_books_empty_approved'.tr()
                : 'memory_books_empty_filtered'.tr(),
          )
        else ...[
          ...visibleEntries.map(
            (entry) => MemoryEntryCard(
              key: ValueKey('entry-${entry.id}'),
              entry: entry,
              embeddingStatus: vectorAvailable
                  ? _embeddingStatuses[entry.id]
                  : null,
              showStatus: true,
              onEdit: () => _editEntry(entry),
              onDelete: () => _deleteEntry(entry.id),
            ),
          ),
          ...visibleDrafts.map(_buildDraftCard),
        ],
      ],
    );
  }

  /// The status filter, scrolling with the list rather than pinned: it belongs
  /// to the list it narrows, and under the batch panel rather than above it.
  Widget _buildFilters(List<MemoryEntry> entries, List<MemoryDraft> drafts) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: _tabIndex == _tabApproved
          ? GlazeFilterChipBar<_EntryFilter>(
              current: _entryFilter,
              options: _EntryFilter.values,
              labelBuilder: (filter) => _entryFilterLabel(filter, entries),
              onSelected: (filter) => setState(() => _entryFilter = filter),
            )
          : GlazeFilterChipBar<_DraftFilter>(
              current: _draftFilter,
              options: _DraftFilter.values,
              labelBuilder: (filter) => _draftFilterLabel(filter, drafts),
              onSelected: (filter) => setState(() => _draftFilter = filter),
            ),
    );
  }

  Widget _buildApprovedTab(List<MemoryEntry> entries) {
    final vectorAvailable = ref.watch(vectorSearchAvailableProvider);
    final visible = entries
        .where(
          (entry) =>
              _passesEntryFilter(entry) &&
              _matchesQuery(entry.title, entry.content, entry.keys),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_consolidatingEntryId != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GlazeActionButton(
              tone: GlazeActionTone.neutral,
              icon: Icons.close_rounded,
              label: 'memory_consolidation_cancel'.tr(),
              onTap: () =>
                  _consolidationCancelToken?.cancel('Cancelled by user'),
            ),
          ),
        _buildPackagePanel(),
        if (visible.isEmpty)
          _buildEmpty(
            entries.isEmpty
                ? 'memory_books_empty_approved'.tr()
                : 'memory_books_empty_filtered'.tr(),
          )
        else
          ...visible.map(
            (entry) => MemoryEntryCard(
              key: ValueKey(entry.id),
              entry: entry,
              // No index badge while semantic search is off in the API —
              // there is nothing to be indexed against.
              embeddingStatus: vectorAvailable
                  ? _embeddingStatuses[entry.id]
                  : null,
              onEdit: () => _editEntry(entry),
              onDelete: () => _deleteEntry(entry.id),
              onConsolidate: _canConsolidate(entry)
                  ? () => _consolidateEntry(entry)
                  : null,
            ),
          ),
      ],
    );
  }

  Widget _buildDraftsTab(List<MemoryDraft> drafts) {
    final visible = drafts
        .where(
          (draft) =>
              _passesDraftFilter(draft) &&
              _matchesQuery(draft.title, draft.content, draft.keys),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (visible.isEmpty)
          _buildEmpty(
            drafts.isEmpty
                ? 'memory_books_empty_scan_drafts'.tr()
                : 'memory_books_empty_filtered'.tr(),
          )
        else
          ...visible.map(_buildDraftCard),
      ],
    );
  }

  Widget _buildDraftCard(MemoryDraft draft) {
    final jobs = ref.watch(memoryDraftJobsProvider);
    return MemoryDraftCard(
      // Prefixed because the search results put entries and drafts in one
      // list, and an approved draft keeps its id as the entry's.
      key: ValueKey('draft-${draft.id}'),
      draft: draft,
      isGenerating: jobs.isGenerating(widget.sessionId, draft.id),
      generatingSince: jobs.startedAt(widget.sessionId, draft.id),
      onGenerate: () => _generateDraft(draft.id),
      onRegenerate: () => _generateDraft(draft.id),
      onCancel: () => _cancelDraft(draft.id),
      onApprove: () => _approveDraft(draft.id),
      onEdit: () => _editDraft(draft),
      onDelete: () => _deleteDraft(draft.id),
    );
  }

  Widget _buildEmpty(String message) {
    return GlassSurface(
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: context.cs.outlineVariant),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: context.cs.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  // ─── Actions delegating to controller ────────────────────────────

  void _scanChat() async {
    final msg = await _ctrl.scanChat();
    if (msg != null && mounted) {
      setState(() {});
      GlazeToast.show(context, msg);
    }
  }

  /// Starts a generation and leaves it alone: the run belongs to
  /// [memoryDraftJobsProvider], which this tab watches, so the row updates
  /// whether or not the sheet is still on screen when the request settles.
  void _generateDraft(String draftId) =>
      unawaited(_ctrl.generateDraft(draftId));

  void _cancelDraft(String draftId) => _ctrl.cancelDraftGeneration(draftId);

  void _batchGenerate() => unawaited(_ctrl.batchGenerate());

  /// Re-reads the book after something outside this sheet wrote to it — a
  /// generation finishing, or the auto-create stage adding drafts during a
  /// chat turn. Without it the sheet showed the book as it was when it opened,
  /// and its next save wrote that stale copy back over the new drafts.
  Future<void> _reloadBook() async {
    await _ctrl.load();
    if (mounted) setState(() {});
  }

  /// Reports a generation failure once, and only to a sheet that is open.
  void _reportFailure(MemoryDraftJobFailure? failure) {
    if (failure == null || failure.sessionId != widget.sessionId) return;
    if (failure.seq <= _reportedFailureSeq) return;
    _reportedFailureSeq = failure.seq;
    if (!mounted) return;
    final label = failure.wasRegeneration
        ? 'memory_books_regeneration_failed'.tr()
        : 'error_generation'.tr();
    GlazeToast.show(context, '$label: ${failure.message}');
  }

  void _approveDraft(String draftId) async {
    try {
      await _ctrl.approveDraft(draftId);
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) GlazeToast.show(context, formatError(error));
    }
  }

  void _deleteDraft(String draftId) async {
    await _ctrl.deleteDraft(draftId);
    if (mounted) setState(() {});
  }

  void _deleteAllDrafts() async {
    await _ctrl.deleteAllDrafts();
    if (mounted) setState(() {});
  }

  void _deleteEntry(String entryId) async {
    await _ctrl.deleteEntry(entryId);
    if (mounted) setState(() {});
  }

  bool _canConsolidate(MemoryEntry entry) {
    final settings = _ctrl.book?.settings;
    return _tabIndex == _tabApproved &&
        MemoryRetrievalMode.fromValue(
          settings?.memoryMode ?? 'fast',
        ).isConsolidationMode &&
        entry.status == 'active' &&
        entry.activeRevisionId != null &&
        _hasEligibleManifest(entry) &&
        _consolidatingEntryId == null &&
        _packageJobId == null;
  }

  bool _hasEligibleManifest(MemoryEntry entry) {
    final revisionId = entry.activeRevisionId;
    if (revisionId == null) return false;
    MemoryEntryRevision? activeRevision;
    for (final revision in entry.revisions) {
      if (revision.id == revisionId) {
        activeRevision = revision;
        break;
      }
    }
    if (activeRevision == null) return false;
    final manifest = activeRevision.sourceManifest;
    return manifest != null &&
        !manifest.invalidated &&
        manifest.version == 1 &&
        manifest.originSessionId == widget.sessionId &&
        activeRevision.messageIds.isNotEmpty &&
        manifest.messages.length == activeRevision.messageIds.length &&
        activeRevision.messageIds.asMap().entries.every(
          (item) => manifest.messages[item.key].messageId == item.value,
        ) &&
        entry.messageIds.length == activeRevision.messageIds.length &&
        entry.messageIds.asMap().entries.every(
          (item) => activeRevision!.messageIds[item.key] == item.value,
        );
  }

  Future<void> _consolidateEntry(MemoryEntry entry) async {
    if (!_canConsolidate(entry)) return;
    final pipeline = ref.read(pipelineSettingsProvider);
    final apiSettings = pipeline.memoryBookApi;
    final runtime = ref.read(nativeProviderRuntimeProvider);
    final sources = runtime?.sources;
    final customOwner = apiSettings.generationSource == 'custom'
        ? ref.read(memoryCustomApiCredentialOwnerProvider)
        : null;
    final epoch = ++_consolidationEpoch;
    final cancelToken = CancelToken();
    _consolidationCancelToken = cancelToken;
    _consolidatingEntryId = entry.id;
    final sessionId = widget.sessionId;
    final charId = widget.charId;
    final revisionEpoch = ref.read(memoryBookRevisionProvider);
    final bookSettings = _ctrl.book!.settings;
    final entryIdentity = _entryConsolidationIdentity(entry);
    MemoryCustomApiInvocation? customInvocation;
    bool isCurrent() => _consolidationCurrent(
      epoch,
      sessionId,
      charId,
      cancelToken,
      revisionEpoch,
      entry.id,
      entryIdentity,
      apiSettings,
      bookSettings,
    );

    setState(() {});
    GlazeToast.show(context, 'memory_consolidation_generating'.tr());
    try {
      customInvocation = customOwner?.capture(
        apiSettings,
        isCurrent: isCurrent,
      );
      final originalStamp = apiSettings.generationSource == 'custom'
          ? null
          : sources?.captureOriginalStamp();
      final apiResolver = MemoryDraftApiSourceResolver(
        sources: sources,
        loadApiConfigs: () async {
          await ref.read(apiListProvider.future);
          if (!isCurrent()) return const [];
          return ref.read(apiListProvider).value ?? const [];
        },
        readActiveApiConfig: () => ref.read(activeApiConfigProvider),
      );
      final coordinator = ref.read(memoryConsolidationCoordinatorProvider);
      final draft = await coordinator.generateDraftWithSettings(
        sessionId: sessionId,
        branchId: sessionId,
        proposedEventId: 'event_${DateTime.now().microsecondsSinceEpoch}',
        memoryEntryIds: [entry.id],
        settings: apiSettings,
        apiResolver: apiResolver,
        originalStamp: originalStamp,
        originalCustomApi: customInvocation,
        isCurrent: isCurrent,
        cancelToken: cancelToken,
      );
      if (!isCurrent()) return;
      if (draft == null) {
        if (mounted) {
          GlazeToast.show(context, 'memory_consolidation_unavailable'.tr());
        }
        return;
      }
      final accepted = await _reviewConsolidation(draft);
      if (accepted != true || !isCurrent()) return;
      final saved = await coordinator.acceptReviewed(
        draft: draft,
        isCurrent: isCurrent,
      );
      if (!isCurrent()) return;
      if (saved) {
        if (mounted) {
          GlazeToast.show(context, 'memory_consolidation_accepted'.tr());
        }
      } else {
        if (mounted) {
          GlazeToast.show(context, 'memory_consolidation_stale'.tr());
        }
      }
    } catch (error) {
      if (mounted && isCurrent()) {
        GlazeToast.show(
          context,
          'memory_consolidation_failed'.tr(
            namedArgs: {'error': formatError(error)},
          ),
        );
      }
    } finally {
      if (mounted && epoch == _consolidationEpoch) {
        setState(() {
          _consolidationCancelToken = null;
          _consolidatingEntryId = null;
        });
      }
    }
  }

  bool _consolidationCurrent(
    int epoch,
    String sessionId,
    String charId,
    CancelToken cancelToken,
    int revisionEpoch,
    String entryId,
    String identity,
    MemoryBookApiSettings apiSettings,
    MemoryBookSettings bookSettings,
  ) {
    if (!mounted ||
        epoch != _consolidationEpoch ||
        cancelToken.isCancelled ||
        widget.sessionId != sessionId ||
        widget.charId != charId ||
        ref.read(memoryBookRevisionProvider) != revisionEpoch ||
        ref.read(pipelineSettingsProvider).memoryBookApi != apiSettings ||
        _ctrl.book?.settings != bookSettings ||
        !MemoryRetrievalMode.fromValue(
          bookSettings.memoryMode,
        ).isConsolidationMode) {
      return false;
    }
    MemoryEntry? current;
    for (final item in _ctrl.book?.entries ?? const <MemoryEntry>[]) {
      if (item.id == entryId) {
        current = item;
        break;
      }
    }
    return current != null &&
        current.status == 'active' &&
        _hasEligibleManifest(current) &&
        _entryConsolidationIdentity(current) == identity;
  }

  String _entryConsolidationIdentity(MemoryEntry entry) =>
      '${entry.activeRevisionId}|${_activeRevisionIdentity(entry)}|'
      '${entry.sourceSwipeId}|'
      '${entry.sourceAgentSwipeId}|${entry.sourceManifest?.toJson()}|'
      '${entry.title}|${entry.content}|${entry.messageIds.join(',')}';

  String _activeRevisionIdentity(MemoryEntry entry) {
    for (final revision in entry.revisions) {
      if (revision.id == entry.activeRevisionId) {
        return '${revision.id}|${revision.version}|${revision.title}|'
            '${revision.content}|${revision.messageIds.join(',')}|'
            '${revision.sourceManifest?.toJson()}';
      }
    }
    return '';
  }

  // ─── Package consolidation (durable jobs) ────────────────────────

  /// The durable package queue. Every package of the session is visible with
  /// its state, source count and localized cause; per-row actions are only
  /// the ones safe for that state. Package execution belongs to the
  /// app-scoped runner; this widget never owns transport.
  Widget _buildPackagePanel() {
    final settings = _ctrl.book?.settings;
    if (settings == null ||
        !MemoryRetrievalMode.fromValue(
          settings.memoryMode,
        ).isConsolidationMode) {
      return const SizedBox.shrink();
    }
    if (_scanRunning) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          'memory_consolidation_package_processing'.tr(),
          style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
        ),
      );
    }
    final jobs =
        ref
            .watch(memoryConsolidationSessionJobsProvider(widget.sessionId))
            .value ??
        const <MemoryConsolidationJobRow>[];
    if (jobs.isEmpty) return const SizedBox.shrink();
    final counts =
        ref
            .watch(
              memoryConsolidationSessionItemCountsProvider(widget.sessionId),
            )
            .value ??
        const <String, int>{};
    // Oldest first, so package numbers follow creation order and stay stable.
    final ordered = [...jobs]
      ..sort(
        (a, b) => a.createdAt == b.createdAt
            ? a.id.compareTo(b.id)
            : a.createdAt.compareTo(b.createdAt),
      );
    var completed = 0;
    final rows = <MemoryConsolidationQueueItem>[];
    for (final job in ordered) {
      if (job.status == 'completed') {
        completed++;
        continue;
      }
      rows.add(
        MemoryConsolidationQueueItem(
          jobId: job.id,
          status: job.status,
          index: rows.length + completed + 1,
          sourceCount: counts[job.id] ?? 0,
          lastError: job.lastError,
          attemptCount: job.attemptCount,
        ),
      );
    }
    if (rows.isEmpty && completed == 0) return const SizedBox.shrink();

    MemoryConsolidationJobRow? rowJob(String jobId) =>
        jobs.where((row) => row.id == jobId).firstOrNull;
    return MemoryConsolidationStatus(
      items: rows,
      completedCount: completed,
      onReview: (jobId) {
        final job = rowJob(jobId);
        if (job != null) _openPendingPackageReview(job);
      },
      onRetry: (jobId) {
        final job = rowJob(jobId);
        if (job != null) _retryPackage(job);
      },
      // Never revive a pack whose frozen sources went stale. Re-plan the
      // current book so new revisions receive new fingerprints/request keys.
      onRebuild: (_) => _startBookScan(),
      onCopyDiagnostics: _copyPackageDiagnostics,
      onCancel: (jobId) {
        final job = rowJob(jobId);
        if (job != null) _cancelPackage(job);
      },
    );
  }

  Future<void> _copyPackageDiagnostics(String jobId) async {
    try {
      final report = await ref
          .read(memoryConsolidationBatchProvider)
          .loadFailureDiagnostics(jobId);
      if (!mounted) return;
      if (report == null) {
        GlazeToast.show(
          context,
          'memory_consolidation_diagnostics_unavailable'.tr(),
        );
        return;
      }
      await Clipboard.setData(ClipboardData(text: report));
      if (mounted) {
        GlazeToast.show(
          context,
          'memory_consolidation_diagnostics_copied'.tr(),
        );
      }
    } catch (error) {
      if (mounted) {
        GlazeToast.show(
          context,
          'memory_consolidation_failed'.tr(
            namedArgs: {'error': formatError(error)},
          ),
        );
      }
    }
  }

  Future<void> _retryPackage(MemoryConsolidationJobRow job) async {
    if (_packageJobId != null ||
        _consolidatingEntryId != null ||
        _scanRunning) {
      return;
    }
    final epoch = ++_packageEpoch;
    setState(() => _packageJobId = job.id);
    try {
      final repo = ref.read(memoryConsolidationJobRepoProvider);
      if (job.status == 'cancelled') {
        await repo.revive(job.id);
      } else {
        await repo.retryFailed(job.id);
      }
      ref
          .read(memoryConsolidationWorkerProvider)
          .notifyPending(widget.sessionId);
    } catch (error) {
      if (mounted && epoch == _packageEpoch) {
        GlazeToast.show(
          context,
          'memory_consolidation_failed'.tr(
            namedArgs: {'error': formatError(error)},
          ),
        );
      }
    } finally {
      _packageFinish(epoch);
    }
  }

  Future<void> _cancelPackage(MemoryConsolidationJobRow job) async {
    if (_packageJobId != null || _scanRunning) return;
    final epoch = ++_packageEpoch;
    setState(() => _packageJobId = job.id);
    try {
      await ref.read(memoryConsolidationJobRepoProvider).cancel(job.id);
    } catch (error) {
      if (mounted && epoch == _packageEpoch) {
        GlazeToast.show(
          context,
          'memory_consolidation_failed'.tr(
            namedArgs: {'error': formatError(error)},
          ),
        );
      }
    } finally {
      _packageFinish(epoch);
    }
  }

  Future<void> _openPendingPackageReview(MemoryConsolidationJobRow job) async {
    if (_packageJobId != null ||
        _consolidatingEntryId != null ||
        _scanRunning) {
      return;
    }
    final epoch = ++_packageEpoch;
    setState(() => _packageJobId = job.id);
    try {
      await _reviewPackageCore(epoch, job.id);
    } catch (error) {
      if (mounted && epoch == _packageEpoch) {
        GlazeToast.show(
          context,
          'memory_consolidation_failed'.tr(
            namedArgs: {'error': formatError(error)},
          ),
        );
      }
    } finally {
      _packageFinish(epoch);
    }
  }

  Future<void> _reviewPackageCore(int epoch, String jobId) async {
    final batch = ref.read(memoryConsolidationBatchProvider);
    final review = await batch.loadReview(jobId);
    if (!mounted || epoch != _packageEpoch) return;
    if (review == null) {
      GlazeToast.show(context, 'memory_consolidation_unavailable'.tr());
      return;
    }
    final accepted = await _reviewPackageSheet(review);
    if (accepted == null || !mounted || epoch != _packageEpoch) return;
    if (accepted == true) {
      final saved = await batch.acceptReviewed(
        jobId: review.jobId,
        isCurrent: () => mounted && epoch == _packageEpoch,
      );
      if (!mounted || epoch != _packageEpoch) return;
      GlazeToast.show(
        context,
        saved
            ? 'memory_consolidation_accepted'.tr()
            : 'memory_consolidation_stale'.tr(),
      );
    } else {
      await batch.reject(review.jobId);
    }
  }

  Future<bool?> _reviewPackageSheet(MemoryConsolidationPackageReview review) =>
      GlazeBottomSheet.show<bool>(
        context,
        title: 'memory_consolidation_package_review_title'.tr(),
        child: _MemoryConsolidationPackageReview(review: review),
        items: [
          if (review.response.outcome != 'unable_to_verify')
            BottomSheetItem(
              icon: Icons.check_rounded,
              label: 'memory_consolidation_accept'.tr(),
              centered: true,
              onTap: () => Navigator.of(context, rootNavigator: true).pop(true),
            ),
          BottomSheetItem(
            icon: Icons.close_rounded,
            label: 'memory_consolidation_reject'.tr(),
            centered: true,
            onTap: () => Navigator.of(context, rootNavigator: true).pop(false),
          ),
        ],
      );

  void _packageFinish(int epoch) {
    if (mounted && epoch == _packageEpoch) {
      setState(() {
        _packageJobId = null;
      });
    }
  }

  // ─── Initial book scan (resumable, no autoaccept) ────────────────

  /// Read-only browser of the session's accepted events and links — the
  /// durable memory consolidation has already confirmed. Nothing here
  /// mutates the registry; acceptance stays an explicit review action.
  Future<void> _showEventRegistry() async {
    await GlazeBottomSheet.show<void>(
      context,
      title: 'memory_consolidation_registry_title'.tr(),
      child: MemoryEventRegistryView(
        sessionId: widget.sessionId,
        branchId: widget.sessionId,
        repo: ref.read(memoryEventRegistryRepoProvider),
        messages: widget.messages,
      ),
    );
  }

  /// The one-time pass over an existing book: a model-aware dry-run plan is
  /// confirmed first, then its packages become durable jobs. The app-scoped
  /// worker executes them, so closing this sheet cannot cancel the scan.
  Future<void> _startBookScan() async {
    if (_scanRunning ||
        _packageJobId != null ||
        _consolidatingEntryId != null) {
      return;
    }
    final book = _ctrl.book;
    if (book == null) return;
    final epoch = ++_scanEpoch;
    setState(() => _scanRunning = true);
    try {
      final apiSettings = ref.read(pipelineSettingsProvider).memoryBookApi;
      await ref.read(apiListProvider.future);
      if (!mounted || epoch != _scanEpoch) return;
      final apiConfig = apiSettings.generationSource == 'custom'
          ? null
          : MemoryBookApiConfigResolver(
              apiConfigs: ref.read(apiListProvider).value ?? const [],
              activeConfig: ref.read(activeApiConfigProvider),
            ).resolve(apiSettings);
      final budget = MemoryConsolidationRequestBudget.forApi(
        settings: apiSettings,
        config: apiConfig,
      );
      final batch = ref.read(memoryConsolidationBatchProvider);
      final plan = await batch.planScan(
        sessionId: widget.sessionId,
        branchId: widget.sessionId,
        entries: book.entries,
        budget: budget,
      );
      final jobs = await ref
          .read(memoryConsolidationJobRepoProvider)
          .getSessionJobs(widget.sessionId);
      final pendingCount = jobs.where((job) => job.status == 'pending').length;
      if (!mounted || epoch != _scanEpoch) return;
      if (plan.packages.isEmpty && pendingCount == 0) {
        GlazeToast.show(context, 'memory_consolidation_package_no_new'.tr());
        return;
      }
      final started = await _scanConfirmSheet(
        eligibleCount: plan.eligibleCount,
        packageCount: plan.packages.length,
        pendingCount: pendingCount,
      );
      if (started != true || !mounted || epoch != _scanEpoch) return;
      final worker = ref.read(memoryConsolidationWorkerProvider);
      await batch.enqueueScan(
        sessionId: widget.sessionId,
        branchId: widget.sessionId,
        plan: plan,
      );
      worker.notifyPending(widget.sessionId);
      if (!mounted || epoch != _scanEpoch) return;
      GlazeToast.show(
        context,
        'memory_consolidation_scan_queued'.tr(
          namedArgs: {'packages': '${plan.packages.length + pendingCount}'},
        ),
      );
    } catch (error) {
      if (mounted && epoch == _scanEpoch) {
        GlazeToast.show(
          context,
          'memory_consolidation_failed'.tr(
            namedArgs: {'error': formatError(error)},
          ),
        );
      }
    } finally {
      if (mounted && epoch == _scanEpoch) {
        setState(() => _scanRunning = false);
      }
    }
  }

  Future<bool?> _scanConfirmSheet({
    required int eligibleCount,
    required int packageCount,
    required int pendingCount,
  }) => GlazeBottomSheet.show<bool>(
    context,
    title: 'memory_consolidation_scan_title'.tr(),
    child: _MemoryConsolidationScanConfirm(
      eligibleCount: eligibleCount,
      packageCount: packageCount,
      pendingCount: pendingCount,
    ),
    items: [
      BottomSheetItem(
        icon: Icons.play_arrow_rounded,
        label: 'memory_consolidation_scan_start'.tr(),
        centered: true,
        onTap: () => Navigator.of(context, rootNavigator: true).pop(true),
      ),
      BottomSheetItem(
        icon: Icons.close_rounded,
        label: 'common_cancel'.tr(),
        centered: true,
        onTap: () => Navigator.of(context, rootNavigator: true).pop(false),
      ),
    ],
  );

  Future<bool?> _reviewConsolidation(MemoryConsolidationDraft draft) =>
      GlazeBottomSheet.show<bool>(
        context,
        title: 'memory_consolidation_review_title'.tr(),
        child: _MemoryConsolidationReview(draft: draft),
        items: [
          if (draft.response.outcome != 'unable_to_verify')
            BottomSheetItem(
              icon: Icons.check_rounded,
              label: 'memory_consolidation_accept'.tr(),
              centered: true,
              onTap: () => Navigator.of(context, rootNavigator: true).pop(true),
            ),
          BottomSheetItem(
            icon: Icons.close_rounded,
            label: 'memory_consolidation_reject'.tr(),
            centered: true,
            onTap: () => Navigator.of(context, rootNavigator: true).pop(false),
          ),
        ],
      );

  void _openSettings() async {
    final currentSettings = _ctrl.globalSettingsAsBookSettings();
    final newResult = await MemoryGenerationSettingsSheet.show(
      context,
      settings: currentSettings,
      sessionId: widget.sessionId,
    );
    if (newResult != null && mounted) {
      await _ctrl.updateSettings(newResult.settings, newResult.vectorThreshold);
      // The generation slot is global app state, not part of the book, so it
      // is written where the Agents tab writes it — the sheet only buffers it.
      final pipeline = ref.read(pipelineSettingsProvider);
      if (pipeline.memoryBookApi != newResult.memoryBookApi) {
        await ref
            .read(pipelineSettingsProvider.notifier)
            .save(pipeline.copyWith(memoryBookApi: newResult.memoryBookApi));
      }
      if (mounted) setState(() {});
    }
  }

  /// The outcome is a typed value, so the presentation is chosen structurally —
  /// this used to match the English prefixes of an already-translated string,
  /// which meant no locale but English ever reached the error dialog.
  void _reindexAll() async {
    if (_reindexRequested) return;
    setState(() => _reindexRequested = true);
    final hold = await GenerationNotificationService.instance.acquireWorkHold(
      title: 'Astoria',
      text: 'Indexing memories...',
    );
    late final ReindexOutcome outcome;
    try {
      outcome = await _ctrl.reindexAll();
    } finally {
      await hold.release();
      if (mounted) setState(() => _reindexRequested = false);
    }
    if (!mounted) return;
    switch (outcome) {
      case ReindexNotReady():
        break;
      case ReindexNeedsEmbeddingApi():
        GlazeErrorDialog.show(
          context,
          'memory_books_setup_embedding_first'.tr(),
        );
      case ReindexFailed(:final error):
        GlazeErrorDialog.show(
          context,
          error,
          prefix: 'memory_books_reindex_failed_prefix'.tr(),
        );
      case ReindexDone(:final indexed, :final skipped, :final failed):
        GlazeToast.show(
          context,
          'memory_books_reindex_result'.tr(
            namedArgs: {
              'indexed': '$indexed',
              'skipped': '$skipped',
              'failed': '$failed',
            },
          ),
        );
    }
  }

  void _deleteAllMemoryIndexes() async {
    final confirmed = await GlazeBottomSheet.show<bool>(
      context,
      title: 'action_delete_indexes'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_outline,
        description: 'action_delete_indexes_confirm'.tr(),
      ),
      items: [
        BottomSheetItem(
          label: 'btn_delete'.tr(),
          isDestructive: true,
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(true),
        ),
        BottomSheetItem(
          label: 'btn_cancel'.tr(),
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(false),
        ),
      ],
    );
    if (confirmed != true) return;
    await _ctrl.deleteAllMemoryIndexes();
    if (mounted) {
      setState(() => _embeddingStatuses = {});
      GlazeToast.show(context, 'memory_books_indexes_deleted'.tr());
    }
  }

  void _editEntry(MemoryEntry entry) async {
    final result = await GlazeBottomSheet.show<MemoryEntry>(
      context,
      title: entry.title.isNotEmpty ? entry.title : 'action_edit'.tr(),
      child: MemoryEntryEditorSheet(entry: entry),
    );
    if (result != null && mounted) {
      try {
        await _ctrl.editEntry(entry, result);
        if (mounted) setState(() {});
      } catch (error) {
        if (mounted) GlazeToast.show(context, formatError(error));
      }
    }
  }

  void _addEntry() async {
    final entry = MemoryEntry(
      id: 'mem_${DateTime.now().millisecondsSinceEpoch}',
      status: 'active',
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    final result = await GlazeBottomSheet.show<MemoryEntry>(
      context,
      title: 'action_create_new'.tr(),
      child: MemoryEntryEditorSheet(entry: entry),
    );
    if (result != null && mounted) {
      await _ctrl.addEntry(result);
      if (mounted) setState(() {});
    }
  }

  void _editDraft(MemoryDraft draft) async {
    final entry = MemoryEntry(
      id: draft.id,
      title: draft.title,
      content: draft.content,
      keys: draft.keys,
      keyParagraphs: draft.keyParagraphs,
      ledgerRange: draft.ledgerRange,
      messageIds: draft.messageIds,
      status: 'active',
      createdAt: draft.createdAt,
    );
    final result = await GlazeBottomSheet.show<MemoryEntry>(
      context,
      title: 'action_edit'.tr(),
      child: MemoryEntryEditorSheet(entry: entry),
    );
    if (result != null && mounted) {
      await _ctrl.editDraft(draft, result);
      if (mounted) setState(() {});
    }
  }
}

class _MemoryConsolidationReview extends StatelessWidget {
  const _MemoryConsolidationReview({required this.draft});

  final MemoryConsolidationDraft draft;

  @override
  Widget build(BuildContext context) {
    final response = draft.response;
    final event = response.event;
    final outcomeKey = switch (response.outcome) {
      'confirmed' => 'memory_consolidation_outcome_confirmed',
      'independent_similarity' =>
        'memory_consolidation_outcome_independent_similarity',
      _ => 'memory_consolidation_outcome_unable',
    };
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(response.outcome == 'unable_to_verify' ? '⚠' : '●'),
          const SizedBox(height: 8),
          Text(outcomeKey.tr()),
          if (event != null) ...[
            const SizedBox(height: 20),
            _sectionTitle(context, 'memory_consolidation_event'.tr()),
            const SizedBox(height: 6),
            Text(
              '${_eventKindLabel(event.kind)} · '
              '${_eventStateLabel(event.state)}',
            ),
            const SizedBox(height: 4),
            Text(event.description),
          ],
          if (response.links.isNotEmpty) ...[
            const SizedBox(height: 20),
            _sectionTitle(context, 'memory_consolidation_links'.tr()),
            const SizedBox(height: 6),
            for (final link in response.links)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(_relationLabel(link.relation)),
              ),
          ],
          const SizedBox(height: 20),
          _sectionTitle(context, 'memory_consolidation_sources'.tr()),
          for (final source in draft.pack.sources) ...[
            const SizedBox(height: 8),
            GlazeExpansionTile(
              showDivider: true,
              title: Text(
                source.title.isEmpty
                    ? 'memory_consolidation_untitled_source'.tr()
                    : source.title,
              ),
              subtitle: Text(
                response.unverifiedSourceRefs.contains(source.ref)
                    ? 'memory_consolidation_source_unverified'.tr()
                    : event?.sourceRefs.contains(source.ref) == true
                    ? 'memory_consolidation_source_cited'.tr()
                    : 'memory_consolidation_source_context'.tr(),
                style: TextStyle(
                  fontSize: 11,
                  color: response.unverifiedSourceRefs.contains(source.ref)
                      ? context.cs.error
                      : context.cs.onSurfaceVariant,
                ),
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: SelectableText(source.content),
                ),
              ],
            ),
          ],
          if (draft.pack.unexaminedOpenObligationIds.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(
              'memory_consolidation_unexamined'.plural(
                draft.pack.unexaminedOpenObligationIds.length,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String title) => Text(
    title,
    style: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w700,
      color: context.cs.primary,
    ),
  );
}

class _MemoryConsolidationPackageReview extends StatelessWidget {
  const _MemoryConsolidationPackageReview({required this.review});

  final MemoryConsolidationPackageReview review;

  @override
  Widget build(BuildContext context) {
    final response = review.response;
    final outcomeKey = switch (response.outcome) {
      'confirmed' => 'memory_consolidation_outcome_confirmed',
      'independent_similarity' =>
        'memory_consolidation_outcome_independent_similarity',
      _ => 'memory_consolidation_outcome_unable',
    };
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(response.outcome == 'unable_to_verify' ? '⚠' : '●'),
          const SizedBox(height: 8),
          Text(outcomeKey.tr()),
          if (response.events.isNotEmpty) ...[
            const SizedBox(height: 20),
            _sectionTitle(context, 'memory_consolidation_package_events'.tr()),
            for (final event in response.events) ...[
              const SizedBox(height: 8),
              GlazeExpansionTile(
                showDivider: true,
                title: Text(
                  '${_eventKindLabel(event.kind)} · '
                  '${_eventStateLabel(event.state)}',
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: SelectableText(event.description),
                  ),
                ],
              ),
            ],
          ],
          if (response.links.isNotEmpty) ...[
            const SizedBox(height: 20),
            _sectionTitle(context, 'memory_consolidation_links'.tr()),
            const SizedBox(height: 6),
            for (final link in response.links)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(_relationLabel(link.relation)),
              ),
          ],
          const SizedBox(height: 20),
          _sectionTitle(context, 'memory_consolidation_sources'.tr()),
          for (final source in review.pack.sources) ...[
            const SizedBox(height: 8),
            GlazeExpansionTile(
              showDivider: true,
              title: Text(
                source.title.isEmpty
                    ? 'memory_consolidation_untitled_source'.tr()
                    : source.title,
              ),
              subtitle: Text(
                _sourceStatus(source),
                style: TextStyle(
                  fontSize: 11,
                  color: response.unverifiedSourceRefs.contains(source.ref)
                      ? context.cs.error
                      : context.cs.onSurfaceVariant,
                ),
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: SelectableText(source.content),
                ),
              ],
            ),
          ],
          if (review.pack.unexaminedOpenObligationIds.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(
              'memory_consolidation_unexamined'.plural(
                review.pack.unexaminedOpenObligationIds.length,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _sourceStatus(MemoryConsolidationSource source) {
    final response = review.response;
    if (response.unverifiedSourceRefs.contains(source.ref)) {
      return 'memory_consolidation_source_unverified'.tr();
    }
    final citedBy = response.events
        .where((event) => event.sourceRefs.contains(source.ref))
        .length;
    return citedBy == 0
        ? 'memory_consolidation_source_context'.tr()
        : 'memory_consolidation_source_cited'.tr();
  }

  Widget _sectionTitle(BuildContext context, String title) => Text(
    title,
    style: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w700,
      color: context.cs.primary,
    ),
  );
}

/// The dry-run estimate the scan asks the reader to confirm before any
/// package is created: sources, packages, and expected model calls.
class _MemoryConsolidationScanConfirm extends StatelessWidget {
  const _MemoryConsolidationScanConfirm({
    required this.eligibleCount,
    required this.packageCount,
    required this.pendingCount,
  });

  final int eligibleCount;
  final int packageCount;
  final int pendingCount;

  @override
  Widget build(BuildContext context) {
    final calls = packageCount + pendingCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'memory_consolidation_scan_estimate'.tr(
              namedArgs: {
                'sources': '$eligibleCount',
                'packages': '$packageCount',
                'calls': '$calls',
              },
            ),
            style: TextStyle(color: context.cs.onSurface),
          ),
        ],
      ),
    );
  }
}
