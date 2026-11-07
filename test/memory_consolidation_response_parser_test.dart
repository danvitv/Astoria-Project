import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/memory_consolidation_response_parser.dart';
import 'package:glaze_flutter/core/models/memory_consolidation.dart';
import 'package:glaze_flutter/core/models/memory_source_manifest.dart';

void main() {
  final source = MemoryConsolidationSource(
    ref: 'source-1',
    sessionId: 'session-1',
    branchId: 'session-1',
    memoryEntryId: 'entry-1',
    revisionId: 'entry-1:r1',
    fingerprint: 'a' * 64,
    title: 'Promise',
    content: 'Mira agreed to return the key.',
    messageIds: const ['message-1'],
    sourceSwipeId: 2,
    sourceAgentSwipeId: 3,
    sourceManifest: MemorySourceManifest(
      originSessionId: 'session-1',
      messages: const [
        MemorySourceStamp(
          messageId: 'message-1',
          swipeId: 2,
          agentSwipeId: 3,
          contentHash: 'message-hash',
        ),
      ],
    ),
  );

  final pack = MemoryConsolidationSourcePack(
    packId: 'pack-1',
    sessionId: 'session-1',
    branchId: 'session-1',
    proposedEventId: 'event-new',
    sources: [source],
    candidates: const [
      MemoryConsolidationEventCandidate(
        id: 'event-old',
        kind: 'promise',
        description: 'An older promise.',
        state: 'open',
        sourceRefs: ['source-1'],
      ),
    ],
    unexaminedOpenObligationIds: const ['event-unexamined'],
  );

  Map<String, dynamic> response({
    String eventId = 'event-new',
    String outcome = 'confirmed',
    Object? event = _event,
    List<Object?> links = const [],
  }) {
    final value = <String, dynamic>{
      'contract': MemoryConsolidationResponseParser.contract,
      'version': MemoryConsolidationResponseParser.version,
      'outcome': outcome,
      'event': event == null
          ? null
          : {...(event as Map<String, dynamic>), 'eventId': eventId},
      'links': <Object?>[...links],
      'unverifiedSourceRefs': const <String>[],
      'unexaminedOpenObligationIds': const ['event-unexamined'],
    };
    return value;
  }

  test('parses one event, exact boundary, and link to known event', () {
    final parsed = MemoryConsolidationResponseParser.parse(
      jsonEncode(
        response(
          links: const [
            {
              'linkId': 'link-1',
              'fromEventId': 'event-new',
              'toEventId': 'event-old',
              'relation': 'fulfills',
            },
          ],
        ),
      ),
      pack,
    );

    expect(parsed.event?.eventId, 'event-new');
    expect(parsed.event?.sourceRefs, ['source-1']);
    expect(parsed.event?.boundaryMessageId, 'message-1');
    expect(parsed.links.single.toEventId, 'event-old');
    final change = parsed.toRegistryChange(pack);
    expect(change.event.id, 'event-new');
    expect(change.event.sources.single.memoryEntryId, 'entry-1');
  });

  test('rejects an event ID not allocated by the application', () {
    expect(
      () => MemoryConsolidationResponseParser.parse(
        jsonEncode(response(eventId: 'model-chosen-id')),
        pack,
      ),
      throwsA(isA<MemoryConsolidationResponseFormatException>()),
    );
  });

  test('rejects unknown source refs and unrelated links', () {
    final unknownSource = response(
      event: {
        ..._event,
        'sourceRefs': ['missing-source'],
      },
    );
    expect(
      () => MemoryConsolidationResponseParser.parse(
        jsonEncode(unknownSource),
        pack,
      ),
      throwsA(isA<MemoryConsolidationResponseFormatException>()),
    );

    final unrelatedLink = response(
      links: const [
        {
          'linkId': 'link-1',
          'fromEventId': 'event-old',
          'toEventId': 'event-other',
          'relation': 'fulfills',
        },
      ],
    );
    expect(
      () => MemoryConsolidationResponseParser.parse(
        jsonEncode(unrelatedLink),
        pack,
      ),
      throwsA(isA<MemoryConsolidationResponseFormatException>()),
    );
  });

  test('keeps unable-to-verify as a non-mutating result', () {
    final parsed = MemoryConsolidationResponseParser.parse(
      jsonEncode(response(outcome: 'unable_to_verify', event: null)),
      pack,
    );

    expect(parsed.event, isNull);
    expect(parsed.links, isEmpty);
  });
}

const _event = <String, dynamic>{
  'eventId': 'event-new',
  'kind': 'result',
  'description': 'Mira returned the key.',
  'state': 'completed',
  'sourceRefs': ['source-1'],
  'boundary': {
    'messageId': 'message-1',
    'swipeId': 2,
    'agentSwipeId': 3,
    'ordinal': 4,
  },
};
