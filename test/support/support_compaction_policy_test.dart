import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_context_policy.dart';

void main() {
  test(
    'measured usage and unlabelled heuristic independently trigger pressure',
    () {
      expect(
        SupportContextPolicy.shouldCompact(
          contextSize: 32000,
          outputReserve: 512,
          requestCharacters: 100,
          suffixMessages: 6,
          measuredInputTokens: 30000,
        ),
        isTrue,
      );
      expect(
        SupportContextPolicy.shouldCompact(
          contextSize: 32000,
          outputReserve: 512,
          requestCharacters: 100,
          suffixMessages: 6,
        ),
        isFalse,
      );
      expect(
        SupportContextPolicy.shouldCompact(
          contextSize: 2000,
          outputReserve: 512,
          requestCharacters: 5000,
          suffixMessages: 6,
        ),
        isTrue,
      );
    },
  );
  test(
    'provider-neutral future pruning removes only exact redundant payloads',
    () {
      const first = SupportContextPayload(identity: 'same', text: 'old');
      const changed = SupportContextPayload(identity: 'same', text: 'changed');
      const repeated = SupportContextPayload(identity: 'same', text: 'old');
      expect(
        SupportContextPolicy.pruneExactDuplicates([first, changed, repeated]),
        [changed, repeated],
      );
    },
  );
}
