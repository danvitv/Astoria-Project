import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_revision_repo.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/session_canon_checkpoint_repo.dart';
import 'package:glaze_flutter/core/db/repositories/sync_session_consistency_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_snapshot_repo.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/models/tracker_snapshot.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';

void main() {
  test(
    'snapshot replacement rolls back a failure after an earlier insert',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await _snapshot(db, 'old', 'old', '');
      final original = await TrackerSnapshotRepo(db).getBySessionId('session');
      await expectLater(
        _FailingSnapshotRepo(db).replaceForSession('session', [
          const TrackerSnapshot(sessionId: 'session', messageId: 'first'),
          const TrackerSnapshot(sessionId: 'session', messageId: 'reject'),
        ]),
        throwsStateError,
      );
      expect(await TrackerSnapshotRepo(db).getBySessionId('session'), original);
    },
  );

  test(
    'snapshot restore CAS protects edits before the replacement transaction',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await _chat(db, ['turn']);
      await _snapshot(db, 'turn', 'before', '');
      final repo = TrackerSnapshotRepo(db);
      final expected = await repo.getBySessionId('session');
      final chat = await ChatRepo(db).getById('session');
      await _snapshot(db, 'turn', 'authored', '');
      await expectLater(
        repo.replaceForSession(
          'session',
          [],
          expectedSnapshots: expected,
          expectedChat: chat,
        ),
        throwsStateError,
      );
      expect(
        (await repo.getBySessionId('session')).single.trackers.single.value,
        'authored',
      );
      final updatedSnapshots = await repo.getBySessionId('session');
      await _chat(db, ['turn', 'new']);
      await expectLater(
        repo.replaceForSession(
          'session',
          [],
          expectedSnapshots: updatedSnapshots,
          expectedChat: chat,
        ),
        throwsStateError,
      );
      expect(await repo.getBySessionId('session'), updatedSnapshots);
    },
  );

  test('a late restore ownership failure rolls back replacement', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _snapshot(db, 'old', 'original', '');
    final repo = TrackerSnapshotRepo(db);
    final original = await repo.getBySessionId('session');
    var checkpoints = 0;
    await expectLater(
      repo.replaceForSession(
        'session',
        [const TrackerSnapshot(sessionId: 'session', messageId: 'new')],
        checkCurrent: () {
          if (++checkpoints == 4) throw StateError('Sync queue aborted');
        },
      ),
      throwsStateError,
    );
    expect(checkpoints, 4);
    expect(await repo.getBySessionId('session'), original);
  });

  test(
    'foreign nested tracker identity cannot replace local history',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await _snapshot(db, 'old', 'original', '');
      final repo = TrackerSnapshotRepo(db);
      final original = await repo.getBySessionId('session');
      await expectLater(
        repo.replaceForSession('session', [
          const TrackerSnapshot(
            sessionId: 'session',
            messageId: 'new',
            trackers: [
              Tracker(
                sessionId: 'other',
                name: 'scene.location',
                value: 'foreign',
                scope: 'ledger',
              ),
            ],
          ),
        ]),
        throwsFormatException,
      );
      expect(await repo.getBySessionId('session'), original);
    },
  );

  test(
    'post-pull reconciliation removes orphan snapshots and restores Ledger',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      const sessionId = 'session';
      const chat = ChatSession(
        id: sessionId,
        characterId: 'character',
        sessionIndex: 0,
        messages: [
          ChatMessage(id: 'm0', role: 'user', content: 'before'),
          ChatMessage(id: 'm1', role: 'assistant', content: 'accepted'),
        ],
      );
      await ChatRepo(db).put(chat);
      final snapshots = TrackerSnapshotRepo(db);
      Tracker location(String messageId, String value) => Tracker(
        sessionId: sessionId,
        name: 'scene.location',
        value: value,
        scope: 'ledger',
        provenance: messageId,
      );
      await snapshots.upsertTrackers(
        sessionId: sessionId,
        messageId: 'm1',
        swipeId: 0,
        agentSwipeId: 0,
        trackers: [location('m1', 'accepted')],
        committed: true,
      );
      await snapshots.upsertTrackers(
        sessionId: sessionId,
        messageId: 'deleted',
        swipeId: 0,
        agentSwipeId: 0,
        trackers: [location('deleted', 'stale')],
        committed: true,
      );
      final trackers = TrackerRepo(db);
      await trackers.upsert(location('deleted', 'stale'));

      await SyncSessionConsistencyRepo(db).reconcile({sessionId});

      expect(
        (await snapshots.getBySessionId(sessionId)).map((s) => s.messageId),
        ['m1'],
      );
      expect(
        (await trackers.get(sessionId, 'scene.location'))?.value,
        'accepted',
      );
    },
  );

  test('rejects live snapshots from canon that was rolled back', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    const sessionId = 'session';
    const original = Character(
      id: 'original',
      name: 'Card',
      description: 'old',
    );
    const fork = Character(id: 'fork', name: 'Card', description: 'new');
    await db
        .into(db.characters)
        .insert(
          CharactersCompanion.insert(
            charId: 'original',
            name: 'Card',
            description: Value('old'),
          ),
        );
    await db
        .into(db.characters)
        .insert(
          CharactersCompanion.insert(
            charId: 'fork',
            name: 'Card',
            description: Value('new'),
          ),
        );
    final revisions = CharacterRevisionRepo(db);
    Future<void> addRevision(Character card) => revisions.insert(
      CharacterRevisionRecord(
        characterId: card.id,
        revision: 1,
        revisionHash: CardCanonicalizer.sha256(card),
        parentRevisionHash: '',
        snapshotJson: jsonEncode(card.toJson()),
        createdAt: 1,
      ),
    );
    await addRevision(original);
    await addRevision(fork);
    const chat = ChatSession(
      id: sessionId,
      characterId: 'fork',
      sessionIndex: 0,
      messages: [
        ChatMessage(id: 'old', role: 'assistant', content: 'old base'),
        ChatMessage(id: 'new', role: 'assistant', content: 'new turn'),
      ],
    );
    await ChatRepo(db).put(chat);
    final checkpoints = SessionCanonCheckpointRepo(db);
    final root = await checkpoints.appendRootInTransaction(
      sessionId: sessionId,
      characterId: original.id,
      characterRevision: 1,
      characterRevisionHash: CardCanonicalizer.sha256(original),
    );
    await checkpoints.appendInTransaction(
      sessionId: sessionId,
      expectedParentCheckpointId: root.id,
      characterId: fork.id,
      characterRevision: 1,
      characterRevisionHash: CardCanonicalizer.sha256(fork),
      rewriteJobId: 'rewrite',
      anchor: const SessionCanonCheckpointAnchor(
        messageId: 'deleted-anchor',
        swipeId: 0,
        agentSwipeId: 0,
      ),
    );
    final snapshots = TrackerSnapshotRepo(db);
    Tracker clock(String messageId, String value, String hash) => Tracker(
      sessionId: sessionId,
      name: 'world:time',
      value: value,
      scope: 'ledger',
      provenance: messageId,
      basisRevisionNumber: 1,
      basisRevisionHash: hash,
    );
    await snapshots.upsertTrackers(
      sessionId: sessionId,
      messageId: 'old',
      swipeId: 0,
      agentSwipeId: 0,
      trackers: [clock('old', '20:50', CardCanonicalizer.sha256(original))],
      committed: true,
    );
    await snapshots.upsertTrackers(
      sessionId: sessionId,
      messageId: 'new',
      swipeId: 0,
      agentSwipeId: 0,
      trackers: [clock('new', '23:48', CardCanonicalizer.sha256(fork))],
      committed: true,
    );

    await SyncSessionConsistencyRepo(db).reconcile({sessionId});

    expect((await ChatRepo(db).getById(sessionId))?.characterId, original.id);
    expect(
      (await snapshots.getBySessionId(sessionId)).map((s) => s.messageId),
      ['old'],
    );
    expect(
      (await TrackerRepo(db).get(sessionId, 'world:time'))?.value,
      '20:50',
    );
  });

  test('preserves inherited canon epochs older than the branch root', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final current = await _card(db, 'character');
    await _chat(db, ['old-a', 'old-b', 'current']);
    await SessionCanonCheckpointRepo(db).appendRootInTransaction(
      sessionId: 'session',
      characterId: 'character',
      characterRevision: 1,
      characterRevisionHash: CardCanonicalizer.sha256(current),
    );
    await _snapshot(db, 'old-a', 'history-a', 'old-a');
    await _snapshot(db, 'old-b', 'history-b', 'old-b');
    await _snapshot(db, 'current', 'live', CardCanonicalizer.sha256(current));
    final before = await TrackerSnapshotRepo(db).getBySessionId('session');

    await SyncSessionConsistencyRepo(db).reconcile({'session'});
    await SyncSessionConsistencyRepo(db).reconcile({'session'});

    expect(await TrackerSnapshotRepo(db).getBySessionId('session'), before);
    expect(
      (await TrackerRepo(db).get('session', 'scene.location'))?.value,
      'live',
    );
  });

  test('a surviving rewrite does not delete its earlier epoch', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final old = await _card(db, 'old');
    final current = await _card(db, 'current');
    await _chat(db, ['before', 'rewrite', 'after'], characterId: current.id);
    final checkpoints = SessionCanonCheckpointRepo(db);
    final root = await checkpoints.appendRootInTransaction(
      sessionId: 'session',
      characterId: old.id,
      characterRevision: 1,
      characterRevisionHash: CardCanonicalizer.sha256(old),
    );
    await checkpoints.appendInTransaction(
      sessionId: 'session',
      expectedParentCheckpointId: root.id,
      characterId: current.id,
      characterRevision: 1,
      characterRevisionHash: CardCanonicalizer.sha256(current),
      rewriteJobId: 'rewrite',
      anchor: const SessionCanonCheckpointAnchor(
        messageId: 'rewrite',
        swipeId: 0,
        agentSwipeId: 0,
      ),
    );
    await _snapshot(db, 'before', 'old history', CardCanonicalizer.sha256(old));
    await _snapshot(db, 'after', 'new live', CardCanonicalizer.sha256(current));

    await SyncSessionConsistencyRepo(db).reconcile({'session'});

    expect(
      (await TrackerSnapshotRepo(db).getBySessionId(
        'session',
      )).map((snapshot) => snapshot.messageId).toSet(),
      {'before', 'after'},
    );
    expect(
      (await TrackerRepo(db).get('session', 'scene.location'))?.value,
      'new live',
    );
  });

  test(
    'inactive surviving green and agent swipes are kept but not promoted',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      const message = ChatMessage(
        id: 'turn',
        role: 'assistant',
        content: 'selected',
        swipes: ['first', 'second'],
        swipeId: 1,
        agentSwipes: [AgentSwipe(content: 'selected')],
        agentSwipeId: 1,
        swipesMeta: [
          {
            'agentSwipes': [
              {'content': 'first cleaned'},
            ],
          },
          {
            'agentSwipes': [
              {'content': 'selected'},
            ],
          },
        ],
      );
      await ChatRepo(db).put(
        const ChatSession(
          id: 'session',
          characterId: 'character',
          sessionIndex: 0,
          messages: [message],
        ),
      );
      await _snapshot(db, 'turn', 'inactive green', '', swipe: 0);
      await _snapshot(db, 'turn', 'inactive agent', '', swipe: 0, agent: 1);
      await _snapshot(db, 'turn', 'active green base', '', swipe: 1);
      await _snapshot(db, 'turn', 'selected', '', swipe: 1, agent: 1);
      await _snapshot(db, 'turn', 'removed green', '', swipe: 2);
      await _snapshot(db, 'turn', 'removed agent', '', swipe: 0, agent: 2);

      await SyncSessionConsistencyRepo(db).reconcile({'session'});

      final snapshots = await TrackerSnapshotRepo(db).getBySessionId('session');
      expect(
        snapshots
            .map((snapshot) => (snapshot.swipeId, snapshot.agentSwipeId))
            .toSet(),
        {(0, 0), (0, 1), (1, 0), (1, 1)},
      );
      expect(
        (await TrackerRepo(db).get('session', 'scene.location'))?.value,
        'selected',
      );
    },
  );

  test('a mixed historical basis is retained without becoming live', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final current = await _card(db, 'character');
    await _chat(db, ['current', 'mixed']);
    await SessionCanonCheckpointRepo(db).appendRootInTransaction(
      sessionId: 'session',
      characterId: 'character',
      characterRevision: 1,
      characterRevisionHash: CardCanonicalizer.sha256(current),
    );
    await _snapshot(
      db,
      'current',
      'valid live',
      CardCanonicalizer.sha256(current),
    );
    await TrackerSnapshotRepo(db).upsertTrackers(
      sessionId: 'session',
      messageId: 'mixed',
      swipeId: 0,
      agentSwipeId: 0,
      committed: true,
      trackers: [
        const Tracker(
          sessionId: 'session',
          name: 'scene.location',
          value: 'mixed',
          scope: 'ledger',
          basisRevisionHash: 'older',
        ),
        Tracker(
          sessionId: 'session',
          name: 'npc:goal',
          value: 'mixed',
          scope: 'ledger',
          basisRevisionHash: CardCanonicalizer.sha256(current),
        ),
      ],
    );

    await SyncSessionConsistencyRepo(db).reconcile({'session'});

    expect((await TrackerSnapshotRepo(db).getBySessionId('session')).length, 2);
    expect(
      (await TrackerRepo(db).get('session', 'scene.location'))?.value,
      'valid live',
    );
    expect(await TrackerRepo(db).get('session', 'npc:goal'), isNull);
  });

  test(
    'without a compatible live snapshot history survives and seed is restored',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final current = await _card(db, 'character');
      await _chat(db, ['old']);
      await SessionCanonCheckpointRepo(db).appendRootInTransaction(
        sessionId: 'session',
        characterId: 'character',
        characterRevision: 1,
        characterRevisionHash: CardCanonicalizer.sha256(current),
      );
      final trackers = TrackerRepo(db);
      await trackers.seedInitialGameTime(
        sessionId: 'session',
        time: '10:00',
        date: '2026-04-11',
      );
      await trackers.upsertValue(
        'session',
        'scene.location',
        'stale',
        scope: 'ledger',
      );
      await _snapshot(db, 'old', 'historical', 'old');

      await SyncSessionConsistencyRepo(db).reconcile({'session'});

      expect(
        (await TrackerSnapshotRepo(db).getBySessionId('session')).length,
        1,
      );
      expect(await trackers.get('session', 'scene.location'), isNull);
      expect((await trackers.get('session', 'world:time'))?.value, '10:00');
    },
  );

  test(
    'rollback removes discarded epochs but retains earlier surviving history',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final a = await _card(db, 'a');
      final b = await _card(db, 'b');
      final c = await _card(db, 'c');
      await _chat(db, ['a', 'b', 'c'], characterId: c.id);
      final checkpoints = SessionCanonCheckpointRepo(db);
      final root = await checkpoints.appendRootInTransaction(
        sessionId: 'session',
        characterId: a.id,
        characterRevision: 1,
        characterRevisionHash: CardCanonicalizer.sha256(a),
      );
      final middle = await checkpoints.appendInTransaction(
        sessionId: 'session',
        expectedParentCheckpointId: root.id,
        characterId: b.id,
        characterRevision: 1,
        characterRevisionHash: CardCanonicalizer.sha256(b),
        rewriteJobId: 'rewrite-b',
        anchor: const SessionCanonCheckpointAnchor(
          messageId: 'b',
          swipeId: 0,
          agentSwipeId: 0,
        ),
      );
      await checkpoints.appendInTransaction(
        sessionId: 'session',
        expectedParentCheckpointId: middle.id,
        characterId: c.id,
        characterRevision: 1,
        characterRevisionHash: CardCanonicalizer.sha256(c),
        rewriteJobId: 'rewrite-c',
        anchor: const SessionCanonCheckpointAnchor(
          messageId: 'deleted',
          swipeId: 0,
          agentSwipeId: 0,
        ),
      );
      await _snapshot(db, 'a', 'history-a', CardCanonicalizer.sha256(a));
      await _snapshot(db, 'b', 'live-b', CardCanonicalizer.sha256(b));
      await _snapshot(db, 'c', 'discarded-c', CardCanonicalizer.sha256(c));

      await SyncSessionConsistencyRepo(db).reconcile({'session'});

      expect((await ChatRepo(db).getById('session'))?.characterId, b.id);
      expect(
        (await TrackerSnapshotRepo(db).getBySessionId(
          'session',
        )).map((snapshot) => snapshot.messageId).toSet(),
        {'a', 'b'},
      );
      expect(
        (await TrackerRepo(db).get('session', 'scene.location'))?.value,
        'live-b',
      );
      // A later import must not revive an epoch the existing rollback retired.
      await _snapshot(db, 'c', 'discarded-c', CardCanonicalizer.sha256(c));
      await SyncSessionConsistencyRepo(db).reconcile({'session'});
      expect(
        (await TrackerSnapshotRepo(db).getBySessionId(
          'session',
        )).map((snapshot) => snapshot.messageId).toSet(),
        {'a', 'b'},
      );
    },
  );
}

Future<void> _chat(
  AppDatabase db,
  List<String> ids, {
  String characterId = 'character',
}) => ChatRepo(db).put(
  ChatSession(
    id: 'session',
    characterId: characterId,
    sessionIndex: 0,
    messages: [
      for (final id in ids) ChatMessage(id: id, role: 'assistant', content: id),
    ],
  ),
);

Future<void> _snapshot(
  AppDatabase db,
  String messageId,
  String value,
  String hash, {
  int swipe = 0,
  int agent = 0,
}) => TrackerSnapshotRepo(db).upsertTrackers(
  sessionId: 'session',
  messageId: messageId,
  swipeId: swipe,
  agentSwipeId: agent,
  committed: true,
  trackers: [
    Tracker(
      sessionId: 'session',
      name: 'scene.location',
      value: value,
      scope: 'ledger',
      provenance: messageId,
      basisRevisionHash: hash,
    ),
  ],
);

Future<Character> _card(AppDatabase db, String id) async {
  final card = Character(id: id, name: 'Card', description: id);
  await db
      .into(db.characters)
      .insert(
        CharactersCompanion.insert(
          charId: id,
          name: 'Card',
          description: Value(id),
        ),
      );
  await CharacterRevisionRepo(db).insert(
    CharacterRevisionRecord(
      characterId: id,
      revision: 1,
      revisionHash: CardCanonicalizer.sha256(card),
      parentRevisionHash: '',
      snapshotJson: jsonEncode(card.toJson()),
      createdAt: 1,
    ),
  );
  return card;
}

class _FailingSnapshotRepo extends TrackerSnapshotRepo {
  _FailingSnapshotRepo(super.db);

  @override
  Future<void> upsert(TrackerSnapshot snapshot) {
    if (snapshot.messageId == 'reject') {
      throw StateError('Snapshot storage failure');
    }
    return super.upsert(snapshot);
  }
}
