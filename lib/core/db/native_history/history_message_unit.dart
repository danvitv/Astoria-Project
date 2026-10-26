import 'dart:convert';

import '../repositories/support_source_text/support_source_json.dart';

/// One strict, complete original message object, including unknown authored
/// fields in its private raw capture. Never a tolerant canonical normalization.
final class HistoryMessageUnit {
  HistoryMessageUnit(String raw) {
    final value = SupportSourceJson.decode(raw);
    if (value is! Map<String, Object?> ||
        !SupportSourceJson.identity(value['id']))
      bad();
    object = value;
    id = value['id'] as String;
    if (utf8.encode(id).length > 256) bad();
    if (value['content'] is! String ||
        !const ['user', 'assistant', 'system'].contains(value['role']))
      bad();
    for (final key in [
      'isHidden',
      'isError',
      'isTyping',
      'isEditing',
      'isLocked',
      'isAllReasoning',
    ]) {
      if (value[key] != null && value[key] is! bool) bad();
    }
    if (value['status'] != null && value['status'] is! String) bad();
    if (value['timestamp'] != null &&
        (value['timestamp'] is! int ||
            (value['timestamp'] as int) < 0 ||
            (value['timestamp'] as int) > 8640000000000000))
      bad();
    eligible =
        ![
          'isHidden',
          'isError',
          'isTyping',
          'isEditing',
          'isLocked',
          'isAllReasoning',
        ].any((k) => value[k] == true) &&
        (value['status'] == null || value['status'] == 'complete');
    swipe = _index(value['swipeId']);
    agentSwipe = _index(value['agentSwipeId']);
    if (value['role'] == 'assistant') {
      final swipes = value['swipes'], agents = value['agentSwipes'];
      if (swipes != null &&
          (swipes is! List || swipes.any((s) => s is! String)))
        bad();
      if (agents != null && agents is! List) bad();
      if (eligible) {
        final s = swipes as List? ?? const [], a = agents as List? ?? const [];
        if ((s.isEmpty ? swipe != 0 : swipe >= s.length) ||
            (a.isEmpty ? agentSwipe != 0 : agentSwipe >= a.length))
          bad();
        if (a.isNotEmpty) {
          final active = a[agentSwipe];
          if (active is! Map<String, Object?> ||
              active['content'] != value['content'] ||
              (active['kind'] != null &&
                  !const ['final', 'cleaned'].contains(active['kind'])) ||
              (active['parentSwipeId'] != null &&
                  active['parentSwipeId'] != swipe))
            bad();
        } else if (s.isNotEmpty && s[swipe] != value['content']) {
          bad();
        }
      }
    }
  }
  late final Map<String, Object?> object;
  late final String id;
  late final bool eligible;
  int swipe = 0, agentSwipe = 0;
  String get content => object['content'] as String;
  String get role => object['role'] as String;
  String? get nativeSwipe => object['swipeId'] == null ? null : '$swipe';
  String? get nativeAgentSwipe =>
      object['agentSwipeId'] == null ? null : '$agentSwipe';
  static Never bad() => throw const FormatException('Unsupported message');
  static int _index(Object? value) {
    if (value == null) return 0;
    if (value is! int || value < 0 || value > 1000000) bad();
    return value;
  }
}
