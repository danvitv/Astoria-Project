import '../models/chat_message.dart';

/// Per-turn occurrence metadata. Selected-source order is preserved without
/// scanning the full chat for every ranked excerpt or retaining its swipe graph.
class RecallSourceClockIndex {
  final Map<String, ({int order, String? stamp})> _sources;
  final Map<String, String?> _ranges = {};

  RecallSourceClockIndex(List<ChatMessage> history)
    : _sources = {
        for (var i = 0; i < history.length; i++)
          history[i].id: (
            order: i,
            stamp:
                !history[i].isHidden &&
                    !history[i].isTyping &&
                    history[i].content.trim().isNotEmpty &&
                    (history[i].role == 'user' ||
                        history[i].role == 'assistant')
                ? history[i].time?.trim()
                : null,
          ),
      };

  String? rangeFor(List<String> ids) {
    final ordered = ids.where(_sources.containsKey).toSet().toList()
      ..sort((a, b) => _sources[a]!.order.compareTo(_sources[b]!.order));
    final key = ordered.join('\u001f');
    return _ranges.putIfAbsent(key, () {
      final stamps = [
        for (final id in ordered)
          if (_sources[id]!.stamp?.isNotEmpty == true) _sources[id]!.stamp!,
      ];
      if (stamps.isEmpty) return null;
      return stamps.length == 1 || stamps.first == stamps.last
          ? stamps.first
          : '${stamps.first} -> ${stamps.last}';
    });
  }
}
