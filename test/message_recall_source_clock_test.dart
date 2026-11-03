import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/memory_draft_transcript_builder.dart';
import 'package:glaze_flutter/core/llm/message_recall_source_clock.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';

void main() {
  test('cached clocks retain source order and legacy eligibility exactly', () {
    const messages = [
      ChatMessage(id: 'a', role: 'user', content: 'a', time: ' day 1 10:00 '),
      ChatMessage(
        id: 'hidden',
        role: 'assistant',
        content: 'hidden',
        time: 'later',
        isHidden: true,
      ),
      ChatMessage(id: 'tool', role: 'tool', content: 'tool', time: 'later'),
      ChatMessage(id: 'blank', role: 'user', content: ' ', time: 'later'),
      ChatMessage(
        id: 'b',
        role: 'assistant',
        content: 'b',
        time: 'day 1 10:05',
      ),
      ChatMessage(id: 'no-time', role: 'assistant', content: 'c'),
      ChatMessage(id: 'c', role: 'user', content: 'c', time: 'day 1 10:00'),
    ];
    final clocks = RecallSourceClockIndex(messages);
    for (final ids in [
      ['a'],
      ['b', 'a'],
      ['hidden', 'a', 'b'],
      ['tool', 'blank', 'no-time'],
      ['unknown'],
      ['c', 'a'],
    ]) {
      final expected = MemoryDraftTranscriptBuilder.ledgerRange(
        messages.where((m) => ids.contains(m.id)).toList(),
      );
      expect(clocks.rangeFor(ids), expected);
      expect(clocks.rangeFor(ids.reversed.toList()), expected);
    }
    expect(clocks.rangeFor(['a', 'a']), 'day 1 10:00');
  });
}
