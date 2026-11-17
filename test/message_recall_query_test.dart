import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/message_recall_query.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';

void main() {
  test('short current scene retains nearby disputed-report narrative', () {
    const history = [
      ChatMessage(
        id: 'u1',
        role: 'user',
        content: '[OOC: The DA report remains disputed.]',
      ),
      ChatMessage(
        id: 'a1',
        role: 'assistant',
        content:
            '<lumiaooc>The institute will recruit everyone.</lumiaooc>She leaves the unsigned report beside the coffee.',
      ),
      ChatMessage(id: 'u2', role: 'user', content: 'I take a sip.'),
    ];
    final query = MessageRecallQuery.build(
      currentText: 'I take a sip.',
      history: history,
    );
    expect(query, startsWith('user: I take a sip.'));
    expect(query, contains('[OOC: The DA report remains disputed.]'));
    expect(query, contains('unsigned report beside the coffee'));
    expect(query, isNot(contains('recruit everyone')));
    expect('I take a sip.'.allMatches(query).length, 1);
  });

  test('unrelated old report is not forced into every coffee scene', () {
    final history = [
      const ChatMessage(id: 'old', role: 'user', content: 'DA report'),
      for (var i = 0; i < 6; i++)
        ChatMessage(id: 'a$i', role: 'assistant', content: 'Coffee scene $i'),
      const ChatMessage(id: 'latest', role: 'user', content: 'A sip.'),
    ];
    final query = MessageRecallQuery.build(
      currentText: 'A sip.',
      history: history,
    );
    expect(query, isNot(contains('DA report')));
    expect(query, contains('Coffee scene 5'));
    expect(query, isNot(contains('Coffee scene 1')));
  });

  test(
    'query excludes marked reasoning, wire tokens and non-source messages',
    () {
      const history = [
        ChatMessage(id: 'sys', role: 'system', content: 'Protocol rules'),
        ChatMessage(
          id: 'hidden',
          role: 'user',
          content: 'Hidden fact',
          isHidden: true,
        ),
        ChatMessage(
          id: 'typing',
          role: 'assistant',
          content: 'Typing fact',
          isTyping: true,
        ),
        ChatMessage(
          id: 'error',
          role: 'assistant',
          content: 'Error fact',
          isError: true,
        ),
        ChatMessage(
          id: 'a1',
          role: 'assistant',
          content:
              '<thought>Private forecast.</thought>Visible scene. <analysis>unfinished private plan',
        ),
        ChatMessage(
          id: 'u1',
          role: 'user',
          content: '<|im_end|>[OOC: Keep the correction.]',
        ),
      ];
      final query = MessageRecallQuery.build(
        currentText: history.last.content,
        history: history,
      );
      expect(query, contains('Visible scene.'));
      expect(query, contains('[OOC: Keep the correction.]'));
      for (final excluded in [
        'Protocol rules',
        'Hidden fact',
        'Typing fact',
        'Error fact',
        'forecast',
        'private plan',
        '<|im_end|>',
      ]) {
        expect(query, isNot(contains(excluded)));
      }
    },
  );

  test('query has deterministic bounds and uses selected content only', () {
    final history = [
      for (var i = 0; i < 20; i++)
        ChatMessage(
          id: 'm$i',
          role: 'assistant',
          content: 'scene $i ${'x' * 1000}',
        ),
      ChatMessage(
        id: 'last',
        role: 'user',
        content: '${'y' * 2000} corrected tail',
        swipes: const ['obsolete swipe'],
        swipeId: 1,
      ),
    ];
    final query = MessageRecallQuery.build(
      currentText: history.last.content,
      history: history,
    );
    expect(query.length, lessThanOrEqualTo(MessageRecallQuery.maxChars));
    expect(query, contains('corrected tail'));
    expect(query, isNot(contains('obsolete swipe')));
    expect(
      query,
      MessageRecallQuery.build(
        currentText: history.last.content,
        history: history,
      ),
    );
  });

  test('a hidden latest message is not relabelled as user input', () {
    const latest = ChatMessage(
      id: 'hidden',
      role: 'user',
      content: 'Hidden correction',
      isHidden: true,
    );
    expect(
      MessageRecallQuery.build(
        currentText: latest.content,
        history: const [latest],
      ),
      isEmpty,
    );
  });

  test(
    'correction lexical query carries the preceding assistant antecedent',
    () {
      const history = [
        ChatMessage(
          id: 'a1',
          role: 'assistant',
          content: 'Давай посмотрим «Призрака в доспехах» с Йоханссон.',
        ),
        ChatMessage(
          id: 'u1',
          role: 'user',
          content:
              'Вообще-то мы вчера с тобой её разнесли. Совсем память подводит?',
        ),
      ];

      final query = MessageRecallQuery.lexicalContinuity(
        currentText: history.last.content,
        history: history,
      );
      expect(query, contains('Вообще-то мы вчера'));
      expect(query, contains('Призрака в доспехах'));
      expect(query, contains('Йоханссон'));
    },
  );

  test('ordinary lexical query does not inherit assistant assertions', () {
    const history = [
      ChatMessage(
        id: 'a1',
        role: 'assistant',
        content: 'Непроверенное утверждение о красном мосте.',
      ),
      ChatMessage(id: 'u1', role: 'user', content: 'Продолжай.'),
    ];
    final query = MessageRecallQuery.lexicalContinuity(
      currentText: history.last.content,
      history: history,
    );
    expect(query, 'Продолжай.');
    expect(query, isNot(contains('мосте')));
  });
}
