import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';
import 'package:glaze_flutter/core/services/card_rewriter/saved_card_lorebook_rerouter.dart';

void main() {
  const content = 'Miyako manages the agency. She cares for the twins.';
  const addition = 'Miyako and Danvi keep their relationship private.';
  final selected = jsonEncode({
    'accumulatedObservations': [
      {
        'targetKind': 'injected_lorebook_entry',
        'lorebookEntryId': 'book:miyako',
        'retrievalKeys': [
          'relationship:miyako:danvi',
          'npc:miyako',
          'book:miyako',
        ],
      },
    ],
    'injectedLorebookEntries': [
      {
        'lorebookId': 'book',
        'entryId': 'miyako',
        'content': content,
        'baseContent': content,
        'expectedContentHash': CardCanonicalizer.scalarSha256(content),
      },
    ],
  });
  final card = CardRewriteOperationSnapshot(
    field: CardRewriteField.scenario,
    patches: [
      AnchoredScalarPatch(
        field: CardRewriteField.scenario,
        scopeKey: 'relationship:miyako:danvi',
        anchor: 'The agency is separate.',
        anchorSha256: CardCanonicalizer.scalarSha256('The agency is separate.'),
        value: 'The agency is separate. $addition',
      ),
    ],
    transition: const CardRewriteTransitionSnapshot(
      id: 'transition',
      scopeKey: 'relationship:miyako:danvi',
      canonicalClaim: addition,
      promotionDestination: 'scenario',
      affectedTrackerKeys: ['npc:miyako'],
      factIds: [],
    ),
  );
  final lore = LorebookRewriteOperationSnapshot(
    lorebookId: 'book',
    entryId: 'miyako',
    baseContent: content,
    expectedContentHash: CardCanonicalizer.scalarSha256(content),
    patches: [
      LorebookAnchoredPatch(
        anchor: 'She cares for the twins.',
        anchorSha256: CardCanonicalizer.scalarSha256(
          'She cares for the twins.',
        ),
        value: 'She cares for the twins and guards their privacy.',
      ),
    ],
  );
  final unrelated = LorebookRewriteOperationSnapshot(
    lorebookId: 'book',
    entryId: 'ruby',
    baseContent: 'Ruby.',
    expectedContentHash: CardCanonicalizer.scalarSha256('Ruby.'),
    patches: [
      LorebookAnchoredPatch(
        anchor: 'Ruby.',
        anchorSha256: CardCanonicalizer.scalarSha256('Ruby.'),
        value: 'Ruby supports her brother.',
      ),
    ],
  );

  test(
    'routes exact saved addition, retains old lore edits and unrelated target',
    () {
      final result = SavedCardLorebookRerouter.reroute(
        cardOperations: [card],
        loreOperations: [lore, unrelated],
        selectedInputJson: selected,
      );
      expect(result, hasLength(2));
      expect(
        RewriteOperationSnapshotCodec.encode(result.last),
        RewriteOperationSnapshotCodec.encode(unrelated),
      );
      final repaired = result.first;
      expect(repaired.patches.single.anchor, content);
      expect(
        repaired.patches.single.value,
        'Miyako manages the agency. She cares for the twins and guards their privacy.\n\n$addition',
      );
      expect(
        repaired.patches.single.value,
        isNot(contains('The agency is separate.')),
      );
      expect(
        SavedCardLorebookRerouter.applySavedPatches(repaired, content),
        repaired.patches.single.value,
      );
    },
  );

  test('cannot silently discard a card edit that is allowed', () {
    final input = jsonDecode(selected) as Map;
    input['accumulatedObservations'] = <dynamic>[];
    expect(
      () => SavedCardLorebookRerouter.reroute(
        cardOperations: [card],
        loreOperations: [lore],
        selectedInputJson: jsonEncode(input),
      ),
      throwsFormatException,
    );
  });

  test('ambiguous destination requires model repair rather than a guess', () {
    final input = jsonDecode(selected) as Map;
    final first = (input['accumulatedObservations'] as List).single as Map;
    (input['accumulatedObservations'] as List).add({
      ...first,
      'lorebookEntryId': 'book:another',
    });
    expect(
      () => SavedCardLorebookRerouter.reroute(
        cardOperations: [card],
        loreOperations: [lore],
        selectedInputJson: jsonEncode(input),
      ),
      throwsFormatException,
    );
  });

  test('stale selected lore hash cannot become a new proposal anchor', () {
    final input = jsonDecode(selected) as Map;
    ((input['injectedLorebookEntries'] as List).single as Map)['content'] =
        'Changed';
    expect(
      () => SavedCardLorebookRerouter.reroute(
        cardOperations: [card],
        loreOperations: [lore],
        selectedInputJson: jsonEncode(input),
      ),
      throwsFormatException,
    );
  });

  test('overlapping saved lore patches are rejected before composing', () {
    final overlapping = LorebookRewriteOperationSnapshot(
      lorebookId: 'book',
      entryId: 'miyako',
      baseContent: content,
      expectedContentHash: lore.expectedContentHash,
      patches: [
        ...lore.patches,
        LorebookAnchoredPatch(
          anchor: content,
          anchorSha256: CardCanonicalizer.scalarSha256(content),
          value: content,
        ),
      ],
    );
    expect(
      () => SavedCardLorebookRerouter.reroute(
        cardOperations: [card],
        loreOperations: [overlapping],
        selectedInputJson: selected,
      ),
      throwsFormatException,
    );
  });
}
