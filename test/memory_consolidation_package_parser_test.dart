import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/memory_consolidation_package_parser.dart';
import 'package:glaze_flutter/core/models/memory_consolidation.dart';
import 'package:glaze_flutter/core/models/memory_source_manifest.dart';

void main() {
  final source1 = _source('entry:one', 'one', 'message-one');
  final source2 = _source('entry:two', 'two', 'message-two');
  final pack = MemoryConsolidationSourcePack(
    packId: 'pack-1',
    sessionId: 'session-1',
    branchId: 'session-1',
    proposedEventId: 'event-one',
    proposedEventIds: const ['event-one', 'event-two'],
    sources: [source1, source2],
    candidates: const [
      MemoryConsolidationEventCandidate(
        id: 'event-old',
        kind: 'promise',
        description: 'An earlier promise.',
        state: 'open',
        sourceRefs: ['entry:one'],
      ),
    ],
    unexaminedOpenObligationIds: const ['event-unexamined'],
  );

  Map<String, dynamic> response({
    String outcome = 'confirmed',
    List<Object?>? events,
    List<Object?> links = const [],
    List<String> unverified = const [],
  }) {
    return {
      'contract': 'memory_event_consolidation',
      'version': 2,
      'outcome': outcome,
      'events':
          events ??
          [
            _event('event-one', 'entry:one', 'message-one'),
            _event('event-two', 'entry:two', 'message-two'),
          ],
      'links': links,
      'unverifiedSourceRefs': unverified,
      'unexaminedOpenObligationIds': ['event-unexamined'],
    };
  }

  test('parses two distinct events and a link to an existing event', () {
    final parsed = MemoryConsolidationPackageParser.parse(
      jsonEncode(
        response(
          links: const [
            {
              'linkId': 'link-1',
              'fromEventId': 'event-one',
              'toEventId': 'event-old',
              'relation': 'fulfills',
            },
            {
              'linkId': 'link-2',
              'fromEventId': 'event-one',
              'toEventId': 'event-two',
              'relation': 'continues',
            },
          ],
        ),
      ),
      pack,
    );

    expect(parsed.events.map((event) => event.eventId), [
      'event-one',
      'event-two',
    ]);
    expect(
      parsed
          .toRegistryEvents(pack)
          .map((event) => event.sources.single.memoryEntryId),
      ['one', 'two'],
    );
    final registryLinks = parsed.toRegistryLinks(pack);
    expect(registryLinks.map((link) => link.toEventId), [
      'event-old',
      'event-two',
    ]);
    expect(registryLinks.map((link) => link.id).toSet(), hasLength(2));
    expect(registryLinks.map((link) => link.id), isNot(contains('link-1')));
    expect(
      parsed.toRegistryLinks(pack).map((link) => link.id),
      registryLinks.map((link) => link.id),
    );
  });

  test('rejects reusing a selected source across separate events', () {
    final invalid = response(
      events: [
        _event('event-one', 'entry:one', 'message-one'),
        _event('event-two', 'entry:one', 'message-one'),
      ],
      unverified: const ['entry:two'],
    );
    expect(
      () => MemoryConsolidationPackageParser.parse(jsonEncode(invalid), pack),
      throwsFormatException,
    );
  });

  test('requires an event ID to cite its allocated selected source', () {
    final swapped = response(
      events: [
        _event('event-one', 'entry:two', 'message-two'),
        _event('event-two', 'entry:one', 'message-one'),
      ],
    );
    expect(
      () => MemoryConsolidationPackageParser.parse(jsonEncode(swapped), pack),
      throwsFormatException,
    );
  });

  test('requires every selected source to be classified exactly once', () {
    final missing = response(
      events: [_event('event-one', 'entry:one', 'message-one')],
    );
    expect(
      () => MemoryConsolidationPackageParser.parse(jsonEncode(missing), pack),
      throwsFormatException,
    );
  });

  test('unable-to-verify cannot contain an event or relation', () {
    final invalid = response(
      outcome: 'unable_to_verify',
      events: const [],
      links: const [
        {
          'linkId': 'link-1',
          'fromEventId': 'event-one',
          'toEventId': 'event-old',
          'relation': 'fulfills',
        },
      ],
      unverified: const ['entry:one', 'entry:two'],
    );
    expect(
      () => MemoryConsolidationPackageParser.parse(jsonEncode(invalid), pack),
      throwsFormatException,
    );
  });

  test(
    'rejects unknown IDs and links between unrelated existing candidates',
    () {
      final unknownId = response(
        events: [
          _event('model-event', 'entry:one', 'message-one'),
          _event('event-two', 'entry:two', 'message-two'),
        ],
      );
      expect(
        () =>
            MemoryConsolidationPackageParser.parse(jsonEncode(unknownId), pack),
        throwsFormatException,
      );

      final unrelated = response(
        links: const [
          {
            'linkId': 'link-1',
            'fromEventId': 'event-old',
            'toEventId': 'other-old',
            'relation': 'fulfills',
          },
        ],
      );
      expect(
        () =>
            MemoryConsolidationPackageParser.parse(jsonEncode(unrelated), pack),
        throwsFormatException,
      );
    },
  );
}

MemoryConsolidationSource _source(String ref, String id, String messageId) {
  final manifest = MemorySourceManifest(
    originSessionId: 'session-1',
    messages: [
      MemorySourceStamp(
        messageId: messageId,
        swipeId: 1,
        agentSwipeId: 2,
        contentHash: 'hash-$id',
      ),
    ],
  );
  return MemoryConsolidationSource(
    ref: ref,
    sessionId: 'session-1',
    branchId: 'session-1',
    memoryEntryId: id,
    revisionId: '$id:r1',
    fingerprint: 'f' * 64,
    title: 'Memory $id',
    content: 'Synthetic event source $id.',
    messageIds: [messageId],
    sourceSwipeId: 1,
    sourceAgentSwipeId: 2,
    sourceManifest: manifest,
  );
}

Map<String, dynamic> _event(String id, String ref, String messageId) => {
  'eventId': id,
  'kind': 'result',
  'description': 'A distinct event from $ref.',
  'state': 'completed',
  'sourceRefs': [ref],
  'boundary': {
    'messageId': messageId,
    'swipeId': 1,
    'agentSwipeId': 2,
    'ordinal': 1,
  },
};
