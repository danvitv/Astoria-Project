import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../core/db/repositories/support_consent_selection_repo.dart';
import '../../../core/models/support_consent_selection.dart';
import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../services/support_native_consent_controller.dart';
import 'support_surface_layout.dart';

/// Action-free native metadata picker: one exact returned page, never a union.
class SupportHistorySelectionSheet extends StatefulWidget {
  const SupportHistorySelectionSheet({
    super.key,
    required this.controller,
    required this.review,
    required this.repo,
    required this.source,
    required this.isCurrent,
  });
  final SupportNativeConsentController controller;
  final SupportNativeReview review;
  final SupportConsentSelectionRepo repo;
  final SupportConsentSelectionSource source;
  final bool Function() isCurrent;

  @override
  State<SupportHistorySelectionSheet> createState() => _HistorySelectionState();
}

class _HistorySelectionState extends State<SupportHistorySelectionSheet> {
  late final void Function() _stop;
  SupportConsentSessionPage? _sessions;
  SupportNativeMessageChoice? _choice;
  final Set<String> _selected = {};
  String? _sessionId;
  String? _failure;
  bool _busy = false, _closed = false, _replacement = false;
  int _request = 0;

  bool get _current => mounted && !_closed && widget.isCurrent();

  @override
  void initState() {
    super.initState();
    _stop = widget.controller.runtime.listen(() {
      if (mounted && !_closed) setState(() {});
    });
    if (widget.source == SupportConsentSelectionSource.support) {
      _messages(widget.review.view.sessionId);
    } else {
      _listSessions();
    }
  }

  @override
  void dispose() {
    _closed = true;
    _request++;
    _stop();
    super.dispose();
  }

  Future<void> _listSessions({int offset = 0}) async {
    if (!_current) return;
    final request = ++_request;
    setState(() {
      _busy = true;
      _failure = null;
      _sessions = null;
    });
    try {
      final page = await widget.repo.listRoleplaySessions(offset: offset);
      if (!_current || request != _request) return;
      setState(() => _sessions = page);
    } catch (_) {
      if (_current && request == _request) {
        setState(() => _failure = 'support_privacy_selection_unavailable');
      }
    } finally {
      if (_current && request == _request) setState(() => _busy = false);
    }
  }

  Future<void> _messages(String id, {int offset = 0}) async {
    if (!_current) return;
    final request = ++_request;
    setState(() {
      _sessionId = id;
      _busy = true;
      _failure = null;
      _replacement = offset > 0;
      _choice = null;
      _selected.clear();
    });
    try {
      final choice = await widget.controller.prepareMessages(
        widget.review,
        widget.source,
        id,
        offset: offset,
      );
      if (!_current || request != _request) return;
      setState(() {
        _choice = choice;
        if (choice == null) _failure = 'support_privacy_selection_unavailable';
      });
    } catch (_) {
      if (_current && request == _request) {
        setState(() => _failure = 'support_privacy_selection_unavailable');
      }
    } finally {
      if (_current && request == _request) setState(() => _busy = false);
    }
  }

  void _back() {
    if (_sessionId != null &&
        widget.source == SupportConsentSelectionSource.roleplay) {
      _request++;
      setState(() {
        _sessionId = null;
        _choice = null;
        _selected.clear();
        _busy = false;
        _failure = null;
      });
    } else {
      _closed = true;
      Navigator.of(context).pop();
    }
  }

  void _approve() {
    if (!_current || _busy || _choice == null) return;
    _closed = true;
    Navigator.of(context).pop(
      SupportHistorySelectionResult(
        _choice!,
        _choice!.page.items
            .where((r) => _selected.contains(r.messageId))
            .map((r) => r.messageId)
            .toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    final page = _choice?.page;
    final sessions = _sessions;
    return SheetView(
      title:
          (widget.source == SupportConsentSelectionSource.roleplay
                  ? 'support_privacy_game_picker'
                  : 'support_privacy_support_picker')
              .tr(),
      showBack: false,
      titleWidget: SupportSheetTitle(
        title:
            (widget.source == SupportConsentSelectionSource.roleplay
                    ? 'support_privacy_game_picker'
                    : 'support_privacy_support_picker')
                .tr(),
        onBack: _back,
      ),
      onBack: _back,
      canPop:
          _sessionId == null ||
          widget.source == SupportConsentSelectionSource.support,
      collapsedFraction: 0.85,
      body: Builder(
        builder: (context) => SupportSheetDecisionBody(
          footer: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (page != null) ...[
                GlazeActionButton(
                  key: const ValueKey('support_privacy_select_messages'),
                  icon: Icons.check,
                  label: 'support_privacy_save_selection'.tr(
                    args: ['${_selected.length}'],
                  ),
                  expand: true,
                  maxLabelLines: null,
                  onTap: current && !_busy ? _approve : null,
                ),
                const SizedBox(height: 8),
              ],
              GlazeActionButton(
                label: 'support_privacy_cancel'.tr(),
                icon: Icons.close_rounded,
                expand: true,
                maxLabelLines: null,
                onTap: () {
                  _closed = true;
                  Navigator.of(context).pop();
                },
              ),
            ],
          ),
          content: ListView(
            key: const ValueKey('support_history_selection_scroll'),
            padding: EdgeInsets.fromLTRB(
              16,
              12,
              16,
              MediaQuery.paddingOf(context).bottom + 24,
            ),
            children: [
              Text('support_privacy_metadata_only'.tr()),
              if (!current) Text('support_privacy_stale'.tr()),
              if (_busy) const Center(child: CircularProgressIndicator()),
              if (_failure != null) Text(_failure!.tr()),
              if (_sessionId == null && sessions != null) ...[
                Text(_statusKey(sessions.status).tr()),
                Text(
                  'support_privacy_session_omissions'.tr(
                    args: ['${sessions.omittedCount}'],
                  ),
                ),
                for (final session in sessions.items)
                  SupportControlAvailability(
                    enabled: current && !_busy && _eligible(session.status),
                    child: MenuItem(
                      key: ValueKey(
                        'support_privacy_session_${session.sessionId}',
                      ),
                      label:
                          '${session.characterLabel} · ${session.variantLabel}',
                      subtitle: 'support_privacy_session_metadata'.tr(
                        args: [
                          '${session.sessionIndex + 1}',
                          '${session.messageCount ?? '—'}',
                        ],
                      ),
                      onTap: () => _messages(session.sessionId),
                    ),
                  ),
                if (sessions.nextOffset != null)
                  GlazeActionButton(
                    key: const ValueKey('support_privacy_next_sessions'),
                    icon: Icons.navigate_next,
                    label: 'support_privacy_next_page'.tr(),
                    expand: true,
                    onTap: current && !_busy
                        ? () => _listSessions(offset: sessions.nextOffset!)
                        : null,
                  ),
              ],
              if (page != null) ...[
                if (page.roleplaySession case final session?)
                  Text(
                    '${session.characterLabel} · ${session.variantLabel}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                Text(_statusKey(page.status).tr()),
                Text(
                  'support_privacy_message_counts'.tr(
                    args: [
                      '${page.items.length}',
                      '${page.omittedCount}',
                      '${page.limitedCount}',
                    ],
                  ),
                ),
                Text('support_privacy_page_replaces'.tr()),
                if (_replacement)
                  Text('support_privacy_page_selection_cleared'.tr()),
                for (final row in page.items)
                  SupportControlAvailability(
                    enabled: current && !_busy,
                    child: MenuSwitchItem(
                      key: ValueKey('support_privacy_message_${row.messageId}'),
                      value: _selected.contains(row.messageId),
                      label: 'support_privacy_message_label'.tr(
                        args: [
                          '${row.nativeOrder + 1}',
                          'support_privacy_role_${row.role.name}'.tr(),
                        ],
                      ),
                      onChanged: (checked) => setState(() {
                        if (checked == true) {
                          _selected.add(row.messageId);
                        } else {
                          _selected.remove(row.messageId);
                        }
                      }),
                    ),
                  ),
                if (page.nextOffset != null)
                  GlazeActionButton(
                    key: const ValueKey('support_privacy_next_messages'),
                    icon: Icons.navigate_next,
                    label: 'support_privacy_next_page'.tr(),
                    expand: true,
                    onTap: current && !_busy
                        ? () => _messages(_sessionId!, offset: page.nextOffset!)
                        : null,
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static bool _eligible(SupportConsentSelectionStatus status) =>
      status == SupportConsentSelectionStatus.available ||
      status == SupportConsentSelectionStatus.limited;
  static String _statusKey(SupportConsentSelectionStatus status) =>
      switch (status) {
        SupportConsentSelectionStatus.available =>
          'support_privacy_metadata_status',
        SupportConsentSelectionStatus.limited =>
          'support_privacy_limited_status',
        SupportConsentSelectionStatus.parentLocked =>
          'support_privacy_locked_status',
        SupportConsentSelectionStatus.unavailable =>
          'support_privacy_selection_unavailable',
      };
}

/// UI result retains the original opaque choice, not a fabricated selection.
final class SupportHistorySelectionResult {
  const SupportHistorySelectionResult(this.choice, this.ids);
  final SupportNativeMessageChoice choice;
  final List<String> ids;
}
