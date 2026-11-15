import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/memory_event_registry_sync_repo.dart';

void main() {
  late AppDatabase source;
  late AppDatabase target;
  late MemoryEventRegistrySyncRepo sourceSync;
  late MemoryEventRegistrySyncRepo targetSync;

  setUp(() async {
    source = AppDatabase.forTesting(NativeDatabase.memory());
    target = AppDatabase.forTesting(NativeDatabase.memory());
    sourceSync = MemoryEventRegistrySyncRepo(source);
    targetSync = MemoryEventRegistrySyncRepo(target);
    await _seedChat(source);
    await _seedChat(target);
  });

  tearDown(() async {
    await source.close();
    await target.close();
  });

  test(
    'exports accepted facts deterministically without private drafts',
    () async {
      await sourceSync.mergeBySessionId('session', _payload('event-b'));
      await sourceSync.mergeBySessionId('session', _payload('event-a'));
      await source.customStatement(
        'INSERT INTO memory_consolidation_job_rows '
        '(id, session_id, branch_id, request_key, package_draft_json, '
        'created_at, updated_at) VALUES (?, ?, ?, ?, ?, 1, 1)',
        [
          'private-job',
          'session',
          'session',
          'request',
          'private Memory Book text',
        ],
      );

      final first = (await sourceSync.getBySessionId('session'))!;
      final second = (await sourceSync.getBySessionId('session'))!;

      expect(first, second);
      expect(
        (first['events'] as List).cast<Map<String, dynamic>>().map(
          (row) => row['id'],
        ),
        ['event-a', 'event-b'],
      );
      expect(jsonEncode(first), isNot(contains('private Memory Book text')));
      expect(first.keys, {
        '__memoryEventRegistry',
        'schemaVersion',
        'sessionId',
        'events',
        'sources',
        'links',
        'invalidations',
      });
    },
  );

  test('imports idempotently and unions independent accepted facts', () async {
    await sourceSync.mergeBySessionId('session', _payload('source-event'));
    await targetSync.mergeBySessionId('session', _payload('target-event'));

    final merged = await targetSync.mergeBySessionId(
      'session',
      (await sourceSync.getBySessionId('session'))!,
    );
    final repeated = await targetSync.mergeBySessionId(
      'session',
      (await sourceSync.getBySessionId('session'))!,
    );

    expect(repeated, merged);
    expect((merged['events'] as List), hasLength(2));
    expect((merged['sources'] as List), hasLength(2));
  });

  test('identity collision rolls back the complete incoming union', () async {
    await targetSync.mergeBySessionId('session', _payload('collision'));
    final original = (await targetSync.getBySessionId('session'))!;
    final incoming = _payload('new-event', extraEvents: [_event('collision')]);
    final events = (incoming['events'] as List).cast<Map<String, dynamic>>();
    events.last['description'] = 'different immutable content';
    (incoming['sources'] as List).add(_source('collision'));

    await expectLater(
      targetSync.mergeBySessionId('session', incoming),
      throwsStateError,
    );

    expect(await targetSync.getBySessionId('session'), original);
  });

  test(
    'invalidation uses portable natural identity and rejects collision',
    () async {
      final payload = _payload('event');
      payload['invalidations'] = [_invalidation('event')];
      await targetSync.mergeBySessionId('session', payload);
      await targetSync.mergeBySessionId('session', payload);

      final conflicting = _clone(payload);
      (conflicting['invalidations'] as List).single['createdAt'] = 99;
      await expectLater(
        targetSync.mergeBySessionId('session', conflicting),
        throwsStateError,
      );
      expect(
        ((await targetSync.getBySessionId('session'))!['invalidations'] as List)
            .single['createdAt'],
        10,
      );
    },
  );

  test('rejects malformed or foreign rows before writing', () async {
    final foreign = _payload('event');
    (foreign['events'] as List).single['sessionId'] = 'other';
    await expectLater(
      targetSync.mergeBySessionId('session', foreign),
      throwsFormatException,
    );

    final malformed = _payload('event');
    (malformed['sources'] as List).single['fingerprint'] = 'not-sha256';
    await expectLater(
      targetSync.mergeBySessionId('session', malformed),
      throwsFormatException,
    );
    expect(await targetSync.getBySessionId('session'), isNull);
  });

  test(
    'requires an owning chat and deletes the aggregate child-first',
    () async {
      await target.customStatement(
        'DELETE FROM chat_sessions WHERE session_id = ?',
        ['session'],
      );
      await expectLater(
        targetSync.mergeBySessionId('session', _payload('event')),
        throwsStateError,
      );
      await _seedChat(target);
      await targetSync.mergeBySessionId('session', _payload('event'));

      await targetSync.deleteBySessionId('session');

      expect(await targetSync.getBySessionId('session'), isNull);
      expect(await target.select(target.memoryEventSourceRows).get(), isEmpty);
      expect(
        await target.select(target.memoryEventInvalidationRows).get(),
        isEmpty,
      );
    },
  );
}

Future<void> _seedChat(AppDatabase db) => db.customStatement(
  'INSERT INTO chat_sessions '
  '(session_id, character_id, session_index, messages_json) '
  'VALUES (?, ?, 0, ?)',
  ['session', 'character', '[]'],
);

Map<String, dynamic> _payload(
  String eventId, {
  List<Map<String, dynamic>> extraEvents = const [],
}) => {
  '__memoryEventRegistry': true,
  'schemaVersion': 1,
  'sessionId': 'session',
  'events': [_event(eventId), ...extraEvents],
  'sources': [_source(eventId)],
  'links': <Map<String, dynamic>>[],
  'invalidations': <Map<String, dynamic>>[],
};

Map<String, dynamic> _event(String id) => {
  'id': id,
  'sessionId': 'session',
  'branchId': 'session',
  'kind': 'action',
  'description': 'Accepted $id',
  'state': 'completed',
  'status': 'active',
  'boundaryMessageId': null,
  'boundarySwipeId': null,
  'boundaryAgentSwipeId': null,
  'boundaryOrdinal': null,
  'revision': 1,
  'acceptedAt': 10,
  'acceptedBy': 'user',
  'createdAt': 10,
};

Map<String, dynamic> _source(String eventId) => {
  'id': '$eventId-source',
  'eventId': eventId,
  'sessionId': 'session',
  'branchId': 'session',
  'memoryEntryId': 'memory-$eventId',
  'revisionId': 'revision-$eventId',
  'fingerprint': 'a' * 64,
  'sourceManifestJson': jsonEncode({
    'version': 1,
    'originSessionId': 'session',
    'messages': [
      {
        'messageId': 'message-$eventId',
        'swipeId': 0,
        'agentSwipeId': 0,
        'contentHash': 'b' * 64,
      },
    ],
    'invalidated': false,
  }),
  'messageIdsJson': jsonEncode(['message-$eventId']),
  'sourceSwipeId': 0,
  'sourceAgentSwipeId': 0,
};

Map<String, dynamic> _invalidation(String eventId) => {
  'sessionId': 'session',
  'branchId': 'session',
  'targetType': 'event',
  'targetId': eventId,
  'causeMemoryEntryId': 'memory-$eventId',
  'reason': 'source_changed',
  'createdAt': 10,
};

Map<String, dynamic> _clone(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
