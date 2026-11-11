import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/game_time.dart';
import 'package:glaze_flutter/core/llm/memory_excerpt_selector.dart';
import 'package:glaze_flutter/core/llm/memory_formatting.dart';
import 'package:glaze_flutter/core/llm/memory_selector.dart';
import 'package:glaze_flutter/core/llm/prompt/memory_prompt_packer.dart';
import 'package:glaze_flutter/core/llm/tokenizer.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';

int _words(String text) =>
    text.trim().isEmpty ? 0 : text.trim().split(RegExp(r'\s+')).length;

MemoryEntry _scoped(String content, {List<int> anchors = const [0]}) =>
    MemoryEntry(
      id: 'memory',
      title: 'Memory16-30',
      content: content,
      keys: const ['festival'],
      keyParagraphs: {'festival': anchors},
      messageRange: const MessageRange(start: 16, end: 30),
    );

MemoryExcerptSelection _select(
  String mode,
  MemoryEntry entry, {
  int? budget = 1000,
  int chunkTokens = 1000,
  int maxWindows = 1,
  int Function(String)? counter,
  List<MemoryCandidateScore>? scores,
}) => MemoryExcerptSelector.select(
  MemorySelection(
    entries: [entry],
    allScores:
        scores ??
        [
          MemoryCandidateScore(
            entry: entry,
            score: 10,
            matchedKeys: const ['festival'],
          ),
        ],
    budgetTokens: budget,
    entryCap: 4,
  ),
  packingMode: mode,
  maxExcerptTokensPerEntry: chunkTokens,
  maxExcerptChunksPerEntry: maxWindows,
  tokenCounter: counter ?? _words,
);

void main() {
  for (final mode in ['hybrid', 'chunk_first']) {
    group('$mode forward source windows', () {
      test('keeps the reported Rise outcome with its festival anchor', () {
        // Exact adjacent paragraphs from the audited accepted Memory16-30.
        const anchor =
            'МЕМ-тё показала Данви смонтированную ею запись первого большого фестиваля «B-Komachi». '
            'Он досмотрел выступление, похвалил группу и признался, что предпочитал живое пение без микрофона и сопровождения. '
            'Данви предложил Кане обмен выступлениями, предупредив, что сам якобы не умел петь; '
            'она приняла вызов и акапелла исполнила куплет с выходом в припев главной песни группы. '
            'Ради выступления Мика приглушил музыку в кафе.';
        const outcome =
            'В ответ Данви целиком исполнил «Rise» Glitch Mob, превратив пение в небольшое шоу с жестами и зрительным контактом с Каной. '
            'Его сильный вокал вызвал аплодисменты; Кана восприняла песню о борьбе за признание как обращение к собственным амбициям '
            'и выразила профессиональное восхищение, шутливо обвинив его в обмане насчёт неумения петь. '
            'Аква отметил привычку Данви занижать ожидания перед демонстрацией способностей, '
            'а МЕМ-тё потребовала совместный эфир, поскольку камера была выключена.';
        final entry = _scoped(
          [
            'Раннее утро.',
            'Дорога к фестивалю.',
            'Подготовка сцены.',
            anchor,
            outcome,
            'Другая сцена без связи с выступлением.',
          ].join('\n\n'),
          anchors: const [3],
        );

        final result = _select(mode, entry);

        expect(result.items.single.text, '$anchor\n\n$outcome');
        expect(result.items.single.chunkIndexes, [3, 4]);
        expect(result.items.single.excerpt, isTrue);
        expect(result.totalTokens, _words(result.items.single.text));
      });

      test(
        'does not keep just the anchor when the entire window cannot fit',
        () {
          const anchor = 'festival exchange promised';
          const outcome = 'The exchange was completed and witnessed.';
          final entry = _scoped('$anchor\n\n$outcome\n\nUnrelated tail.');
          final windowCost = _words('$anchor\n\n$outcome');

          final tooTight = _select(mode, entry, budget: windowCost - 1);
          final fits = _select(mode, entry, budget: windowCost);

          expect(tooTight.items, isEmpty);
          expect(tooTight.totalTokens, 0);
          expect(tooTight.budgetTrimmed, isTrue);
          expect(fits.items.single.text, '$anchor\n\n$outcome');
          expect(fits.totalTokens, windowCost);
          expect(fits.totalTokens, lessThanOrEqualTo(windowCost));
        },
      );

      test('deduplicates overlapping windows in exact source order', () {
        const content =
            'festival anchor A.\r\n\r\nfestival  anchor B.\r\n\r\n'
            'The outcome has two clauses; both remain here.\r\n\r\nUnused tail.';
        final entry = _scoped(content, anchors: const [0, 1]);

        final result = _select(mode, entry, maxWindows: 2);

        expect(result.items.single.text, content.split('\r\n\r\nUnused').first);
        expect(result.items.single.chunkIndexes, [0, 1, 2]);
        expect(result.totalTokens, _words(result.items.single.text));
      });

      test('bounds a long paragraph to the anchor and immediately next chunk', () {
        const content =
            'festival  one two three four five six seven eight nine ten eleven '
            'twelve thirteen fourteen fifteen sixteen seventeen eighteen '
            'nineteen twenty\n\nNo distant paragraph should be added.';
        final entry = _scoped(content);

        final result = _select(
          mode,
          entry,
          // Hybrid keeps its strict entry-wide cap. Global windows may cost
          // two chunk limits, but neither path shrinks chunks to fit a budget.
          chunkTokens: 10,
          budget: mode == 'hybrid' ? 10 : 20,
        );

        if (mode == 'hybrid') {
          // No over-budget first-window fallback; the final scoped chunk may
          // still be an anchor, but it must include its next source chunk.
          expect(result.totalTokens, lessThanOrEqualTo(10));
          expect(
            result.items.every((item) => !item.text.startsWith('festival')),
            isTrue,
          );
        } else {
          expect(result.items.single.chunkIndexes, [0, 1]);
          expect(result.items.single.text, startsWith('festival  one'));
          expect(_words(result.items.single.text), 20);
          expect(result.items.single.text, isNot(contains('No distant')));
          expect(result.items.single.text, isNot(contains('nineteen twenty')));
        }
      });

      test(
        'does not open a source-window-excluded entry through key metadata',
        () {
          final eligible = _scoped('festival anchor\n\nLocal outcome.');
          final excluded = MemoryEntry(
            id: 'excluded',
            content: 'festival excluded anchor\n\nExcluded outcome.',
            keys: const ['festival'],
            keyParagraphs: const {
              'festival': [0],
            },
          );
          final result = _select(
            mode,
            eligible,
            scores: [
              MemoryCandidateScore(
                entry: excluded,
                score: 100,
                matchedKeys: const ['festival'],
                excludedBySourceWindow: true,
              ),
              MemoryCandidateScore(
                entry: eligible,
                score: 10,
                matchedKeys: const ['festival'],
              ),
            ],
          );

          expect(result.items.map((item) => item.entry.id), ['memory']);
          expect(result.items.single.text, eligible.content);
          expect(result.items.single.text, isNot(contains('Excluded')));
        },
      );

      test(
        'does not cross entries for a future or unselected closing event',
        () {
          final entry = _scoped('festival performance was offered');
          final future = MemoryEntry(
            id: 'future',
            content: 'The performance was completed in a future scene.',
            messageRange: const MessageRange(start: 31, end: 45),
          );
          final result = _select(
            mode,
            entry,
            scores: [
              MemoryCandidateScore(
                entry: entry,
                score: 10,
                matchedKeys: const ['festival'],
              ),
              MemoryCandidateScore(
                entry: future,
                score: 100,
                excludedBySourceWindow: true,
                exclusionReason: 'future source excluded upstream',
              ),
            ],
          );

          expect(result.items.single.text, entry.content);
          expect(result.items.single.chunkIndexes, [0]);
          expect(result.items.single.text, isNot(contains('completed')));
        },
      );

      test(
        'counts rendered union and separators with a non-additive counter',
        () {
          final entry = _scoped(
            'festival first\n\nFirst outcome.\n\nOmitted middle.\n\n'
            'festival second\n\nSecond outcome.\n\nUnused tail.',
            anchors: const [0, 3],
          );
          const expected =
              'festival first\n\nFirst outcome.\n\n'
              'festival second\n\nSecond outcome.';
          int counter(String text) =>
              100 + _words(text) + RegExp(r'\n\n').allMatches(text).length * 7;
          final result = _select(
            mode,
            entry,
            maxWindows: 2,
            counter: counter,
            budget: counter(expected),
          );

          expect(result.items.single.text, expected);
          expect(result.items.single.chunkIndexes, [0, 1, 3, 4]);
          expect(result.items.single.tokenCost, counter(expected));
          expect(result.totalTokens, counter(expected));
          expect(result.totalTokens, lessThanOrEqualTo(counter(expected)));
          expect(result.items.single.originalTokenCost, counter(entry.content));
        },
      );

      test(
        'zero window settings do not overflow or admit a first fallback',
        () {
          final entry = _scoped('festival anchor\n\nOutcome.');
          expect(_select(mode, entry, maxWindows: 0).items, isEmpty);
          expect(_select(mode, entry, chunkTokens: 0).items, isEmpty);
        },
      );

      test(
        'an unsplittable word cannot bypass the finite window token cap',
        () {
          final entry = _scoped(List.filled(1000, 'festival').join());
          final result = _select(
            mode,
            entry,
            chunkTokens: 20,
            budget: null,
            counter: (text) => text.length,
          );
          expect(result.items, isEmpty);
          expect(result.totalTokens, 0);
        },
      );

      test('final prompt envelope keeps the whole window or drops it', () {
        const anchor = 'festival exchange was offered';
        const outcome = 'The exchange was completed. Everyone applauded.';
        const expected = '$anchor\n\n$outcome';
        final entry = _scoped('$expected\n\nAn unrelated later scene.');
        const packer = MemoryPromptPacker();
        final expectedItem = MemoryInjectionItem(
          entry: entry,
          excerpt: true,
          text: expected,
          tokenCost: estimateTokens(expected),
          originalTokenCost: estimateTokens(entry.content),
        );
        final budget = estimateTokens(
          packer.format([expectedItem]).hardBlockContent,
        );
        MemoryExcerptSelection pack(int limit) => packer.pack(
          selection: MemorySelection(
            entries: [entry],
            allScores: [
              MemoryCandidateScore(
                entry: entry,
                score: 10,
                matchedKeys: const ['festival'],
              ),
            ],
            budgetTokens: limit,
            entryCap: 1,
          ),
          excerptingEnabled: true,
          packingMode: mode,
          excerptTokensPerChunk: 500,
          excerptChunksPerEntry: 1,
          chunkFirstTopEntries: 1,
          chunkFirstTopChunks: 1,
        );

        final fits = pack(budget);
        final tooTight = pack(budget - 1);
        expect(fits.items.single.text, expected);
        expect(fits.totalTokens, budget);
        expect(
          estimateTokens(packer.format(fits.items).macroContent),
          lessThanOrEqualTo(budget),
        );
        expect(tooTight.items, isEmpty);
        expect(tooTight.totalTokens, 0);
        expect(tooTight.budgetTrimmed, isTrue);
      });

      test('accepted event and complete source share one budget unit', () {
        final entry = _scoped(
          'festival exchange was offered. The full accepted source stays intact. '
          'An unrelated later scene follows.',
        );
        const annotation = MemoryEventPromptAnnotation(
          eventId: 'event-1',
          kind: 'agreement',
          description: 'The exchange was completed.',
          state: 'completed',
          relation: 'fulfills',
        );
        const packer = MemoryPromptPacker();
        final expectedItem = MemoryInjectionItem(
          entry: entry,
          excerpt: false,
          text: entry.content.trim(),
          tokenCost: estimateTokens(entry.content),
          originalTokenCost: estimateTokens(entry.content),
          eventAnnotations: [annotation],
        );
        final budget = estimateTokens(
          packer.format([expectedItem]).hardBlockContent,
        );
        MemoryExcerptSelection pack(int limit) => packer.pack(
          selection: MemorySelection(
            entries: [entry],
            allScores: [
              MemoryCandidateScore(
                entry: entry,
                score: 10,
                matchedKeys: const ['festival'],
              ),
            ],
            budgetTokens: limit,
            entryCap: 1,
            eventAnnotationsByEntryId: const {
              'memory': [annotation],
            },
          ),
          excerptingEnabled: true,
          packingMode: mode,
          excerptTokensPerChunk: 8,
          excerptChunksPerEntry: 2,
          chunkFirstTopEntries: 1,
          chunkFirstTopChunks: 1,
        );

        final fits = pack(budget);
        final tooTight = pack(budget - 1);
        expect(fits.items, hasLength(1));
        expect(fits.items.single.excerpt, isFalse);
        expect(fits.items.single.text, entry.content.trim());
        expect(fits.items.single.eventAnnotations, [annotation]);
        expect(fits.totalTokens, budget);
        expect(tooTight.items, isEmpty);
        expect(tooTight.totalTokens, 0);
        expect(tooTight.budgetTrimmed, isTrue);
      });
    });
  }

  test(
    'full mode preserves complete source and honors the supplied counter',
    () {
      final entry = _scoped(
        'festival  anchor\r\n\r\nOutcome.\r\n\r\nOther scene.',
      );
      final result = _select('full', entry, counter: (text) => text.length);
      expect(result.items.single.excerpt, isFalse);
      expect(result.items.single.text, entry.content);
      expect(result.totalTokens, entry.content.length);
    },
  );

  for (final mode in ['hybrid', 'chunk_first']) {
    test('$mode scopes a catalog-matched knowledge key to its paragraph', () {
      const relevant =
          'Данви самостоятельно вычислил адрес штаба и договорился ждать в двух кварталах.';
      final entry = MemoryEntry(
        id: 'headquarters-memory',
        title: '826-840',
        content: [
          'Длинный разговор о машине и лекции.',
          'Обсуждение старой фотографии.',
          'Поездка в кофейню.',
          'Страйкбольный винчестер и папарацци.',
          'Разговор в подсобке.',
          relevant,
        ].join('\n\n'),
        keys: const ['машина', 'лекция', 'штаб', 'геолокация'],
        keyParagraphs: const {
          'машина': [0],
          'лекция': [0],
          'штаб': [5],
          'геолокация': [5],
        },
      );
      final result = _select(
        mode,
        entry,
        scores: [
          MemoryCandidateScore(
            entry: entry,
            score: 10,
            catalogMatchedTerms: const ['штаб'],
          ),
        ],
      );

      expect(result.items.single.text, relevant);
      expect(result.items.single.text, isNot(contains('машине')));
      expect(result.items.single.chunkIndexes, [5]);
    });
  }

  test(
    'partial memory framing never turns omissions into negative evidence',
    () {
      final entry = _scoped('festival performance was offered');
      final selected = _select('chunk_first', entry);
      final text = formatMemoryItems(
        selected.items,
        includeContextHeader: true,
        gameTime: const GameTimeState(day: 9),
      );

      expect(text, contains('incomplete historical records'));
      expect(text, contains('does not prove that an event never happened'));
      expect(text, contains('a character did not know'));
      expect(text, contains('a promise remained unfulfilled'));
      expect(text, contains('unknown, not as current Ledger facts'));
      expect(
        text,
        contains(
          'Current Ledger canon and Character Knowledge take precedence',
        ),
      );
      expect(text, contains('does not give every NPC shared knowledge'));
      expect(text, contains('Current story point: day 9'));
      expect(text, contains('[Excerpted from a larger Memory Book entry]'));
    },
  );
}
