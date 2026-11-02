import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/canon_evidence_text.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/services/pipeline_utils.dart';

void main() {
  test('Hotel route forecast is excluded while Ruby scene is preserved', () {
    const text =
        '<lumiaooc><font color="#9370DB">'
        'Кана собственница; Мияко делит мужчину со своими воспитанницами.'
        '</font></lumiaooc>Руби привалилась виском к его плечу.';
    final narrative = CanonEvidenceText.assistantNarrative(text);
    expect(narrative, isNot(contains('делит мужчину')));
    expect(narrative, isNot(contains('Кана собственница')));
    expect(narrative, contains('Руби привалилась виском к его плечу.'));
    expect(text, contains('Кана собственница')); // Saved source not mutated.
  });

  test('marked OOC supports attributes, nesting, case and multiple blocks', () {
    const text =
        'До. <MetaOOC class="note">Прогноз '
        '<oocnote>Вложенный.</oocnote> Продолжение.</MetaOOC>'
        ' После. [OOC: путь [вариант] открыт] Кана смеётся.'
        ' ((Возможно, влюбится (если захочет))) Идёт к машине.'
        ' (OOC: это прогноз)';
    final result = CanonEvidenceText.assistantNarrative(text);
    expect(result, contains('До.'));
    expect(result, contains('После.'));
    expect(result, contains('Кана смеётся.'));
    expect(result, contains('Идёт к машине.'));
    for (final meta in [
      'Прогноз',
      'Вложенный',
      'вариант',
      'влюбится',
      'прогноз',
    ]) {
      expect(result, isNot(contains(meta)));
    }
  });

  test('unfinished marked assistant OOC cannot leak into evidence', () {
    for (final tail in [
      '<lumiaooc>Все уже влюблены.',
      '[OOC: Все уже влюблены.',
      '((Все уже влюблены.',
    ]) {
      expect(
        CanonEvidenceText.assistantNarrative('Сцена. $tail'),
        allOf(contains('Сцена.'), isNot(contains('влюблены'))),
      );
    }
  });

  test('ordinary narration and chosen romance are byte-for-byte preserved', () {
    const scene =
        'Кана стояла рядом у машины. <i>Она доверяет ему.</i> '
        'Позже они решили начать отношения. {{user}} не обещал эксклюзивность.';
    expect(CanonEvidenceText.assistantNarrative(scene), scene);
  });

  test('user OOC corrections and romance choices are never filtered', () {
    const correction =
        '[OOC: Не считаем помощь ухаживанием. '
        'Реальный разговор Каны у машины сохраняем.]';
    expect(CanonEvidenceText.forMessage('user', correction), correction);
  });

  test('JSON projection preserves IDs, metadata and non-history canon', () {
    final input = jsonEncode({
      'chatHistory': [
        {
          'messageId': 'a1',
          'role': 'assistant',
          'content': '<lumiaooc>Все влюбятся.</lumiaooc>Кана у машины.',
          'swipeId': 2,
        },
        {'messageId': 'u2', 'role': 'user', 'content': '[OOC: исправь факт]'},
      ],
      'effectiveCanon': {'revision': 3},
      'card': {'personality': 'Independent.'},
    });
    final projected = jsonDecode(CanonEvidenceText.projectContextJson(input));
    expect(projected['chatHistory'][0]['messageId'], 'a1');
    expect(projected['chatHistory'][0]['swipeId'], 2);
    expect(projected['chatHistory'][0]['content'], isNot(contains('влюбятся')));
    expect(projected['chatHistory'][0]['content'], contains('Кана у машины.'));
    expect(projected['chatHistory'][1]['content'], '[OOC: исправь факт]');
    expect(projected['effectiveCanon'], {'revision': 3});
    expect(
      jsonDecode(input)['chatHistory'][0]['content'],
      contains('влюбятся'),
    );
  });

  test('unchanged writer input remains byte-identical for durable replay', () {
    const input =
        '{ "chatHistory": [{"role":"assistant",'
        '"content":"Кана у машины."}], "other": 42 }';
    expect(CanonEvidenceText.projectContextJson(input), input);
  });

  test('automatic Ledger recent history excludes assistant forecasts only', () {
    final result = extractRecentHistoryText(const [
      ChatMessage(id: 'u1', role: 'user', content: '[OOC: Кана не влюблена.]'),
      ChatMessage(
        id: 'a1',
        role: 'assistant',
        content: '<lumiaooc>Влюбится.</lumiaooc>Кана смеётся у машины.',
      ),
    ]);
    expect(result, contains('[OOC: Кана не влюблена.]'));
    expect(result, contains('Кана смеётся у машины.'));
    expect(result, isNot(contains('Влюбится.')));
  });
}
