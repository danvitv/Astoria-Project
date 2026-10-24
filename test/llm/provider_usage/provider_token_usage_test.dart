import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/provider_token_usage.dart';

import '_provider_usage_fixture.dart';

void main() {
  test('DTO accepts only bounded counters and preserves explicit zero', () {
    final usage = ProviderTokenUsage(
      inputTokens: 0,
      outputTokens: ProviderTokenUsage.maxReportedTokens,
      totalTokens: -1,
      cachedInputTokens: ProviderTokenUsage.maxReportedTokens + 1,
      cacheCreationInputTokens: 4,
      reasoningTokens: 5,
    );
    expect(usageNumbers(usage), [0, 0x7fffffff, null, null, 4, 5]);
    expect(usage.hasReportedTokens, isTrue);
    expect(ProviderTokenUsage().hasReportedTokens, isFalse);
    expect(usage.toString(), 'ProviderTokenUsage');
  });

  test(
    'cumulative merge replaces values without sums, maximums or estimates',
    () {
      final original = ProviderTokenUsage(
        inputTokens: 100,
        outputTokens: 2,
        cachedInputTokens: 60,
      );
      final cumulative = original.mergeSnapshot(
        ProviderTokenUsage(outputTokens: 8, reasoningTokens: 3),
      );
      expect(usageNumbers(cumulative), [100, 8, null, 60, null, 3]);
      expect(
        usageNumbers(cumulative.mergeSnapshot(cumulative)),
        usageNumbers(cumulative),
      );
      expect(
        usageNumbers(
          cumulative.mergeSnapshot(ProviderTokenUsage(outputTokens: 0)),
        ),
        [100, 0, null, 60, null, 3],
      );
      expect(
        usageNumbers(
          cumulative.mergeSnapshot(ProviderTokenUsage(outputTokens: 7)),
        ),
        [100, 7, null, 60, null, 3],
      );
      expect(usageNumbers(original), [100, 2, null, 60, null, null]);
    },
  );
}
