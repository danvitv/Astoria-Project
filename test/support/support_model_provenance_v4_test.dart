import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_model_provenance.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_provenance_codec.dart';

SupportModelToolDisclosure _disclosure({
  String source = 'game-source',
  String? digest,
}) => SupportModelToolDisclosure(
  domain: SupportModelToolDisclosureDomain.game,
  sourceId: source,
  orderedSourceIds: ['active-a', 'active-b'],
  snapshotDigest: digest ?? List.filled(64, 'a').join(),
);

SupportModelProvenance _recipe({
  List<SupportModelToolDisclosure>? disclosures,
  bool direct = true,
  String? checkpoint,
}) => SupportModelProvenance(
  supportSessionId: 'own-chat',
  replyMessageId: 'reply',
  runId: 'run',
  currentUserMessageId: 'user',
  originalRanges: [
    SupportModelSourceRange(
      domain: SupportModelSourceDomain.support,
      sessionId: 'own-chat',
      orderedMessageIds: ['old-user'],
    ),
  ],
  directReplies: const [],
  currentConversationMessageIds: direct ? ['old-user'] : null,
  compactedThroughMessageId: checkpoint,
  toolDisclosures: disclosures,
);

void main() {
  test(
    'v4 exact roundtrip, private metadata, no body/recipient/rights; old ranges unchanged',
    () {
      final item = _disclosure();
      final recipe = _recipe(disclosures: [item]);
      final encoded = SupportModelProvenanceCodec.encodeForEncryptedStorage(
        recipe,
      );
      final map = jsonDecode(encoded) as Map;
      expect(map['version'], 4);
      expect(
        map.keys,
        unorderedEquals([
          'marker',
          'version',
          'supportSessionId',
          'replyMessageId',
          'runId',
          'currentUserMessageId',
          'originalRanges',
          'directReplies',
          'currentConversationMessageIds',
          'toolDisclosures',
        ]),
      );
      final decoded = SupportModelProvenanceCodec.decodeFromEncryptedStorage(
        encoded,
      ).recipe!;
      expect(
        decoded.toolDisclosures!.single.domain,
        SupportModelToolDisclosureDomain.game,
      );
      expect(decoded.toolDisclosures!.single.orderedSourceIds, [
        'active-a',
        'active-b',
      ]);
      expect(decoded.originalRanges.single.orderedMessageIds, ['old-user']);
      expect(
        SupportModelProvenanceCodec.encodeForEncryptedStorage(decoded),
        encoded,
      );
    },
  );

  test('explicit v4 empty disclosures and optional checkpoint stay v4', () {
    for (final checkpoint in [null, 'checkpoint']) {
      final encoded = SupportModelProvenanceCodec.encodeForEncryptedStorage(
        _recipe(disclosures: [], checkpoint: checkpoint),
      );
      final decoded = SupportModelProvenanceCodec.decodeFromEncryptedStorage(
        encoded,
      ).recipe!;
      expect((jsonDecode(encoded) as Map)['version'], 4);
      expect(decoded.toolDisclosures, isEmpty);
      expect(decoded.compactedThroughMessageId, checkpoint);
    }
  });

  test(
    'old v1/v2/v3 retain strict original format, no default disclosures',
    () {
      for (final recipe in [
        _recipe(direct: false),
        _recipe(),
        _recipe(checkpoint: 'checkpoint'),
      ]) {
        final encoded = SupportModelProvenanceCodec.encodeForEncryptedStorage(
          recipe,
        );
        final decoded = SupportModelProvenanceCodec.decodeFromEncryptedStorage(
          encoded,
        ).recipe!;
        expect(decoded.toolDisclosures, isNull);
        expect(
          SupportModelProvenanceCodec.encodeForEncryptedStorage(decoded),
          encoded,
        );
        final poisoned = (jsonDecode(encoded) as Map)
          ..['toolDisclosures'] = <Object?>[];
        expect(
          SupportModelProvenanceCodec.decodeFromEncryptedStorage(
            jsonEncode(poisoned),
          ).isValid,
          isFalse,
        );
      }
    },
  );

  test(
    'unknown/duplicate/missing/malformed metadata refuses entire record',
    () {
      final encoded = SupportModelProvenanceCodec.encodeForEncryptedStorage(
        _recipe(disclosures: [_disclosure()]),
      );
      final base = jsonDecode(encoded) as Map<String, dynamic>;
      final bad = <String>[
        encoded.replaceFirst('"version":4', '"version":4,"version":4'),
        encoded.replaceFirst('"sourceId":', '"sourceId":"x","sourceId":'),
        encoded.replaceFirst('"domain":"game"', '"domain":"studio"'),
        encoded.replaceFirst(
          '"snapshotDigest":',
          '"permission":true,"snapshotDigest":',
        ),
        encoded.replaceFirst(List.filled(64, 'a').join(), 'not-a-digest'),
        jsonEncode({...base}..remove('currentConversationMessageIds')),
        jsonEncode({...base, 'compactedThroughMessageId': null}),
        jsonEncode({...base, 'version': 5}),
      ];
      for (final raw in bad) {
        expect(
          SupportModelProvenanceCodec.decodeFromEncryptedStorage(raw).isValid,
          isFalse,
        );
      }
      expect(
        () => _recipe(direct: false, disclosures: [_disclosure()]),
        throwsA(isA<SupportModelProvenanceException>()),
      );
      expect(
        () => _recipe(disclosures: [_disclosure(), _disclosure()]),
        throwsA(isA<SupportModelProvenanceException>()),
      );
      expect(
        () => _recipe(
          disclosures: [
            for (var i = 0; i < 17; i++) _disclosure(source: 'source-$i'),
          ],
        ),
        throwsA(isA<SupportModelProvenanceException>()),
      );
      expect(
        () => SupportModelToolDisclosure(
          domain: SupportModelToolDisclosureDomain.game,
          sourceId: 'source',
          orderedSourceIds: [for (var i = 0; i < 17; i++) 'id-$i'],
          snapshotDigest: List.filled(64, 'a').join(),
        ),
        throwsA(isA<SupportModelProvenanceException>()),
      );
    },
  );

  test('saved Studio domain must declare exactly the actual preset ID', () {
    final studio = SupportModelToolDisclosure(
      domain: SupportModelToolDisclosureDomain.studioPreset,
      sourceId: 'preset',
      orderedSourceIds: ['preset'],
      snapshotDigest: List.filled(64, 'b').join(),
    );
    final encoded = SupportModelProvenanceCodec.encodeForEncryptedStorage(
      _recipe(disclosures: [studio]),
    );
    expect(
      SupportModelProvenanceCodec.decodeFromEncryptedStorage(
        encoded,
      ).recipe!.toolDisclosures!.single.domain,
      SupportModelToolDisclosureDomain.studioPreset,
    );
    expect(
      () => SupportModelToolDisclosure(
        domain: SupportModelToolDisclosureDomain.studioPreset,
        sourceId: 'preset',
        orderedSourceIds: ['game-message'],
        snapshotDigest: List.filled(64, 'b').join(),
      ),
      throwsA(isA<SupportModelProvenanceException>()),
    );
  });

  test(
    'cached own-chat input retention needs metadata only, not foreign body coverage',
    () {
      final original = _recipe(disclosures: [_disclosure()]);
      final retained =
          SupportModelProvenanceCodec.retainToolDisclosuresForCachedInputs([
            original,
          ]);
      expect(
        identical(retained!.single, original.toolDisclosures!.single),
        isTrue,
      );
      final cached = _recipe(disclosures: retained);
      expect(
        cached.originalRanges.single.domain,
        SupportModelSourceDomain.support,
      );
      expect(
        cached.originalRanges.any(
          (r) => r.domain == SupportModelSourceDomain.game,
        ),
        isFalse,
      );
      final encoded = SupportModelProvenanceCodec.encodeForEncryptedStorage(
        cached,
      );
      expect(
        SupportModelProvenanceCodec.decodeFromEncryptedStorage(
          encoded,
        ).recipe!.toolDisclosures!.single.sourceId,
        'game-source',
      );
      expect(
        SupportModelProvenanceCodec.retainToolDisclosuresForCachedInputs([
          _recipe(),
        ]),
        isNull,
      );
      expect(
        SupportModelProvenanceCodec.retainToolDisclosuresForCachedInputs([
          _recipe(disclosures: []),
        ]),
        isEmpty,
      );
    },
  );

  test(
    'retention refuses overflow instead of silently erasing oldest disclosures',
    () {
      final a = _recipe(
        disclosures: [
          for (var i = 0; i < 16; i++) _disclosure(source: 'source-$i'),
        ],
      );
      final b = _recipe(disclosures: [_disclosure(source: 'source-16')]);
      expect(
        () => SupportModelProvenanceCodec.retainToolDisclosuresForCachedInputs([
          a,
          b,
        ]),
        throwsA(isA<SupportModelProvenanceException>()),
      );
    },
  );
}
