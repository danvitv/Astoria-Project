import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/memory/memory_catalog_matcher.dart';
import 'package:glaze_flutter/core/llm/memory_selector.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';

void main() {
  test('memory key matcher accepts common Russian inflections', () {
    expect(
      memoryKeyMatchesGlaze(
        'призрак в доспехах',
        'Хочешь посмотреть «Призрака в доспехах»?',
      ),
      isTrue,
    );
    expect(memoryKeyMatchesGlaze('йоханссон', 'роль Йоханссона'), isTrue);
  });

  test('inflection fallback keeps whole-token boundaries', () {
    expect(memoryKeyMatchesGlaze('кот', 'На столе котлета.'), isFalse);
    expect(memoryKeyMatchesGlaze('дом', 'Она задумалась.'), isFalse);
  });

  test('catalog keyword path uses the same inflection-aware matcher', () {
    const entry = MemoryEntry(
      id: 'movie',
      title: 'Просмотр фильма',
      keys: ['Призрак в доспехах'],
      content: 'Фильм посмотрели перед планёркой.',
      status: 'active',
    );
    final matches = MemoryCatalogMatcher.keywordMatches(
      const [entry],
      'мы уже посмотрели Призрака в доспехах',
      'both',
    );
    expect(matches['movie'], ['Призрак в доспехах']);
  });
}
