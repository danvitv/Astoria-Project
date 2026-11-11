import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../core/db/app_db.dart';
import '../../../../core/db/repositories/memory_event_registry_repo.dart';
import '../../../../core/models/chat_message.dart';
import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glaze_expansion_tile.dart';

String _formatAcceptedDate(int acceptedAtSeconds) {
  final date = DateTime.fromMillisecondsSinceEpoch(acceptedAtSeconds * 1000);
  return '${date.day.toString().padLeft(2, '0')}.'
      '${date.month.toString().padLeft(2, '0')}.${date.year}';
}

String memoryEventKindLabel(String value) => switch (value) {
  'promise' => 'memory_consolidation_kind_promise'.tr(),
  'agreement' => 'memory_consolidation_kind_agreement'.tr(),
  'action' => 'memory_consolidation_kind_action'.tr(),
  'result' => 'memory_consolidation_kind_result'.tr(),
  'cancellation' => 'memory_consolidation_kind_cancellation'.tr(),
  'change' => 'memory_consolidation_kind_change'.tr(),
  _ => value,
};

String memoryEventStateLabel(String value) => switch (value) {
  'open' => 'memory_consolidation_state_open'.tr(),
  'completed' => 'memory_consolidation_state_completed'.tr(),
  'cancelled' => 'memory_consolidation_state_cancelled'.tr(),
  'continuing' => 'memory_consolidation_state_continuing'.tr(),
  'contradiction' => 'memory_consolidation_state_contradiction'.tr(),
  _ => value,
};

String memoryEventRelationLabel(String value) => switch (value) {
  'continues' => 'memory_consolidation_relation_continues'.tr(),
  'fulfills' => 'memory_consolidation_relation_fulfills'.tr(),
  'cancels' => 'memory_consolidation_relation_cancels'.tr(),
  'contradicts' => 'memory_consolidation_relation_contradicts'.tr(),
  'confirms' => 'memory_consolidation_relation_confirms'.tr(),
  'independent_similarity' =>
    'memory_consolidation_relation_independent_similarity'.tr(),
  _ => value,
};

/// Read-only view of the session's accepted event registry: the durable
/// memory of what consolidation confirmed. Events and links are collapsed
/// behind disclosure tiles so a long history stays scannable.
class MemoryEventRegistryView extends StatefulWidget {
  const MemoryEventRegistryView({
    super.key,
    required this.sessionId,
    required this.branchId,
    required this.repo,
    required this.messages,
  });

  final String sessionId;
  final String branchId;
  final MemoryEventRegistryRepo repo;

  /// The session's chat messages in story order. Event sources reference
  /// messages by opaque id; the story position lives only in this order, so
  /// chronological captions and sorting are computed against it, and each
  /// message's ledger clock stamp (`ChatMessage.time`) carries the scene
  /// date the event was given at.
  final List<ChatMessage> messages;

  @override
  State<MemoryEventRegistryView> createState() =>
      _MemoryEventRegistryViewState();
}

class _MemoryEventRegistryViewState extends State<MemoryEventRegistryView> {
  List<MemoryEventRow> _events = const [];
  List<MemoryEventLinkRow> _links = const [];
  Map<String, List<MemoryEventSourceRow>> _sources = const {};
  Map<String, int> _messageOrder = const {};
  Map<String, String> _messageTimes = const {};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final events = await widget.repo.getActiveEvents(
      sessionId: widget.sessionId,
      branchId: widget.branchId,
    );
    final links = await widget.repo.getActiveLinks(
      sessionId: widget.sessionId,
      branchId: widget.branchId,
    );
    final sources = await widget.repo.getActiveEventSources(
      sessionId: widget.sessionId,
      branchId: widget.branchId,
    );
    if (!mounted) return;
    final order = <String, int>{};
    final times = <String, String>{};
    for (var i = 0; i < widget.messages.length; i++) {
      final message = widget.messages[i];
      order[message.id] = i;
      final time = message.time;
      if (time != null && time.isNotEmpty) times[message.id] = time;
    }
    setState(() {
      _sources = sources;
      _messageOrder = order;
      _messageTimes = times;
      _events = _sortChronologically(events);
      _links = links;
      _loaded = true;
    });
  }

  /// Ledger clock stamp of the scene the event was given at: the first
  /// source message carrying one, in story order. The clock only moves
  /// forward, so the first stamp is "when it was given", not when the
  /// later scenes referencing it ran. Null when no source message carries
  /// a stamp — no date is invented then.
  String? _sceneTime(String eventId) {
    final rows = _sources[eventId] ?? const <MemoryEventSourceRow>[];
    if (rows.isEmpty || _messageTimes.isEmpty) return null;
    for (final row in rows) {
      try {
        final ids = jsonDecode(row.messageIdsJson) as List;
        for (final id in ids) {
          final time = _messageTimes[id.toString()];
          if (time != null) return time;
        }
      } catch (_) {}
    }
    return null;
  }

  /// 1-based story positions of an event's source messages. Positions come
  /// from the session's message order, never parsed out of the ids — ids
  /// are opaque, and their trailing digits are not a message number.
  List<int> _positions(String eventId) {
    final rows = _sources[eventId] ?? const <MemoryEventSourceRow>[];
    final positions = <int>[];
    for (final row in rows) {
      try {
        final ids = jsonDecode(row.messageIdsJson) as List;
        for (final id in ids) {
          final position = _messageOrder[id.toString()];
          if (position != null) positions.add(position + 1);
        }
      } catch (_) {}
    }
    positions.sort();
    return positions;
  }

  /// Story order, not acceptance order: events line up by the earliest
  /// source message position in the session; events whose sources cannot be
  /// resolved to positions keep their accepted-at place. An event
  /// consolidated late can still describe an early scene, so the read order
  /// follows the chat it came from.
  List<MemoryEventRow> _sortChronologically(List<MemoryEventRow> events) {
    final positions = <String, List<int>>{};
    for (final event in events) {
      positions[event.id] = _positions(event.id);
    }
    return [...events]..sort((a, b) {
      final positionsA = positions[a.id]!;
      final positionsB = positions[b.id]!;
      if (positionsA.isNotEmpty && positionsB.isNotEmpty) {
        final byMessage = positionsA.first.compareTo(positionsB.first);
        if (byMessage != 0) return byMessage;
      }
      final timed = a.acceptedAt.compareTo(b.acceptedAt);
      if (timed != 0) return timed;
      return a.id.compareTo(b.id);
    });
  }

  /// Message range the event was consolidated from, e.g. "Messages 211–225".
  /// Positions are 1-based indexes into the session's message order. An
  /// event whose source ids cannot be resolved to positions falls back to a
  /// plain source count, so nothing is invented.
  String _messageRange(String eventId) {
    final rows = _sources[eventId] ?? const <MemoryEventSourceRow>[];
    final positions = _positions(eventId);
    if (positions.isEmpty) {
      return rows.isEmpty
          ? ''
          : 'memory_consolidation_registry_sources'.tr(
              namedArgs: {'count': '${rows.length}'},
            );
    }
    final first = positions.first;
    final last = positions.last;
    if (first == last) {
      return 'memory_consolidation_registry_message_one'.tr(
        namedArgs: {'message': '$first'},
      );
    }
    return 'memory_consolidation_registry_message_range'.tr(
      namedArgs: {'first': '$first', 'last': '$last'},
    );
  }

  String _snippet(String eventId) {
    final event = _events.where((event) => event.id == eventId).firstOrNull;
    if (event == null) return '…';
    final text = event.description;
    return text.length <= 80 ? text : '${text.substring(0, 80)}…';
  }

  /// Tile subtitle: message range plus a one-line preview of the
  /// description. Kind · state titles repeat across unrelated events (two
  /// open agreements are not the same agreement), so the preview is what
  /// makes rows distinguishable at a glance. The scene's ledger clock is
  /// appended when a source message carries one, so an old condition can
  /// never read as a current one (the §10.1 Chisato case) — the acceptance
  /// date stays visible in the expanded tile.
  String _tileSubtitle(MemoryEventRow event) {
    final range = _messageRange(event.id);
    final description = event.description.trim();
    final preview = description.length <= 72
        ? description
        : '${description.substring(0, 72)}…';
    final scene = _sceneTime(event.id);
    final parts = [
      if (range.isNotEmpty) range,
      preview,
      if (scene != null)
        'memory_consolidation_registry_scene'.tr(namedArgs: {'time': scene}),
    ];
    return parts.join(' · ');
  }

  /// Chains = connected components of the accepted link graph. Events share
  /// a chain when links tie them together directly or transitively; events
  /// without any link are their own single-event chain. Components are cut
  /// over the chronologically sorted events, so chain 1 is the one the
  /// story reaches first, and the order inside each chain is story order.
  List<List<MemoryEventRow>> _chains() {
    final byId = {for (final event in _events) event.id: event};
    final adjacency = <String, Set<String>>{};
    for (final link in _links) {
      adjacency.putIfAbsent(link.fromEventId, () => {}).add(link.toEventId);
      adjacency.putIfAbsent(link.toEventId, () => {}).add(link.fromEventId);
    }
    final chains = <List<MemoryEventRow>>[];
    final seen = <String>{};
    for (final event in _events) {
      if (!seen.add(event.id)) continue;
      final chain = <MemoryEventRow>[event];
      final queue = [event.id];
      while (queue.isNotEmpty) {
        final current = queue.removeLast();
        for (final neighbor in adjacency[current] ?? const <String>{}) {
          if (seen.add(neighbor)) {
            final row = byId[neighbor];
            if (row != null) {
              chain.add(row);
              queue.add(neighbor);
            }
          }
        }
      }
      chains.add(chain);
    }
    return chains;
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_events.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(
          'memory_consolidation_registry_empty'.tr(),
          style: TextStyle(fontSize: 13, color: context.cs.onSurfaceVariant),
        ),
      );
    }
    final byId = {for (final event in _events) event.id: event};
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'memory_consolidation_registry_summary'.tr(
              namedArgs: {
                'events': '${_events.length}',
                'links': '${_links.length}',
              },
            ),
            style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          _sectionTitle(context, 'memory_consolidation_registry_events'.tr()),
          for (final chain in _chains().asMap().entries) ...[
            const SizedBox(height: 8),
            Text(
              'memory_consolidation_registry_chain'.tr(
                namedArgs: {
                  'index': '${chain.key + 1}',
                  'count': '${chain.value.length}',
                },
              ),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: context.cs.onSurfaceVariant,
              ),
            ),
            for (final event in chain.value) ...[
              const SizedBox(height: 8),
              GlazeExpansionTile(
                showDivider: true,
                title: Text(
                  '${memoryEventKindLabel(event.kind)} · '
                  '${memoryEventStateLabel(event.state)}',
                ),
                subtitle: Text(
                  _tileSubtitle(event),
                  style: TextStyle(
                    fontSize: 11,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'memory_consolidation_registry_accepted'.tr(
                            namedArgs: {
                              'date': _formatAcceptedDate(event.acceptedAt),
                            },
                          ),
                          style: TextStyle(
                            fontSize: 11,
                            color: context.cs.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 4),
                        SelectableText(event.description),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ],
          if (_links.isNotEmpty) ...[
            const SizedBox(height: 20),
            _sectionTitle(context, 'memory_consolidation_registry_links'.tr()),
            for (final link in _links) ...[
              const SizedBox(height: 8),
              GlazeExpansionTile(
                showDivider: true,
                title: Text(memoryEventRelationLabel(link.relation)),
                subtitle: Text(
                  '${_snippet(link.fromEventId)} → ${_snippet(link.toEventId)}',
                  style: TextStyle(
                    fontSize: 11,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (byId[link.fromEventId] != null)
                          SelectableText(
                            '${memoryEventKindLabel(byId[link.fromEventId]!.kind)}: '
                            '${byId[link.fromEventId]!.description}',
                          ),
                        const SizedBox(height: 8),
                        if (byId[link.toEventId] != null)
                          SelectableText(
                            '${memoryEventKindLabel(byId[link.toEventId]!.kind)}: '
                            '${byId[link.toEventId]!.description}',
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
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
