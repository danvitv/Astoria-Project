import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/character_knowledge_fact_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_snapshot_repo.dart';
import 'package:glaze_flutter/core/llm/game_time.dart';
import 'package:glaze_flutter/core/llm/ledger/ledger_canon_authority.dart';
import 'package:glaze_flutter/core/llm/ledger/ledger_turn_committer.dart';
import 'package:glaze_flutter/core/models/tracker.dart';

import 'fixtures/ledger_clock_exports.dart';
import 'fixtures/ledger_clock_persistence_fixture.dart';

void main() {
  test(
    'raw numeric minute persists canonically and advances for two more turns',
    () async {
      final fixture = LedgerClockPersistenceFixture();
      addTearDown(fixture.db.close);
      await fixture.seed(
        const GameTimeState(time: '10:00', date: '01.01.2026', day: 0),
      );

      for (final (turn, raw, expected) in [
        (1, '10:5', '10:05'),
        (2, '10:06', '10:06'),
        (3, '10:07', '10:07'),
      ]) {
        final before = await fixture.currentClock();
        final prepared = await fixture.prepare(
          ledgerClockExport([ledgerClockSet('world:time', raw)]),
          turn,
        );
        expect(prepared.parsed.rejectedOps, isEmpty);
        expect(prepared.parsed.export!.ops.single.value, expected);
        expect(await fixture.committer.commit(prepared.request), 1);
        await _expectPersisted(
          fixture,
          turn,
          GameTimeState(time: expected, date: '01.01.2026', day: 0),
        );
        expect(_delta(await fixture.currentClock(), before), turn == 1 ? 5 : 1);
      }
    },
  );

  for (final (initialDate, initialDay, nextDate, nextDay) in [
    ('01.01.2026', 0, '02.01.2026', 1),
    ('28.02.2024', 0, '29.02.2024', 1),
    ('31.12.2026', 3, '02.01.2027', 5),
  ]) {
    test(
      'numeric and canonical rows/deltas agree across $initialDate to $nextDate',
      () async {
        final numeric = LedgerClockPersistenceFixture();
        final canonical = LedgerClockPersistenceFixture();
        addTearDown(numeric.db.close);
        addTearDown(canonical.db.close);
        final seed = GameTimeState(
          time: '23:58',
          date: initialDate,
          day: initialDay,
        );
        await numeric.seed(seed);
        await canonical.seed(seed);

        for (var turn = 1; turn <= 3; turn++) {
          final date = turn == 1 ? initialDate : nextDate;
          final day = turn == 1 ? initialDay : nextDay;
          final time = turn == 1
              ? '23:59'
              : turn == 2
              ? '00:02'
              : '00:03';
          final numericOps = turn == 3
              ? [ledgerClockSet('world:time', time)]
              : [
                  ledgerClockSet('world:time', turn == 2 ? '0:2' : time),
                  ledgerClockSet('world:date', date.replaceAll('.', '-')),
                  ledgerClockSet('world:day', '$day'.padLeft(2, '0')),
                ];
          final canonicalOps = turn == 3
              ? [ledgerClockSet('world:time', time)]
              : [
                  ledgerClockSet('world:time', time),
                  ledgerClockSet('world:date', date),
                  ledgerClockSet('world:day', '$day'),
                ];
          final beforeNumeric = await numeric.currentClock();
          final beforeCanonical = await canonical.currentClock();
          final actual = await numeric.prepare(
            ledgerClockExport(numericOps),
            turn,
          );
          final expected = await canonical.prepare(
            ledgerClockExport(canonicalOps),
            turn,
          );
          expect(actual.parsed.rejectedOps, isEmpty);
          expect(actual.parsed.export!.ops, expected.parsed.export!.ops);
          expect(
            await numeric.committer.commit(actual.request),
            numericOps.length,
          );
          expect(
            await canonical.committer.commit(expected.request),
            canonicalOps.length,
          );

          final clock = GameTimeState(time: time, date: date, day: day);
          await _expectPersisted(numeric, turn, clock);
          await _expectPersisted(canonical, turn, clock);
          expect(
            _values(await numeric.clockRows()),
            _values(await canonical.clockRows()),
          );
          final delta = _delta(await numeric.currentClock(), beforeNumeric);
          expect(
            delta,
            _delta(await canonical.currentClock(), beforeCanonical),
          );
          expect(delta, turn == 2 ? (nextDay - initialDay - 1) * 1440 + 3 : 1);
        }
      },
    );
  }

  test(
    'bad normalized packet preserves clock; unrelated op still survives',
    () async {
      final fixture = LedgerClockPersistenceFixture();
      addTearDown(fixture.db.close);
      const seed = GameTimeState(time: '23:59', date: '01.01.2026', day: 0);
      await fixture.seed(seed);
      final prepared = await fixture.prepare(
        ledgerClockExport([
          ledgerClockSet('world:time', '0:2'),
          ledgerClockSet('world:date', '02-01-2026'),
          ledgerClockSet('world:day', '02'),
          ledgerClockSet('world:location', 'gate'),
        ]),
        1,
      );
      expect(prepared.parsed.rejectedOps, hasLength(3));
      expect(prepared.parsed.export!.ops.single.key, 'world:location');
      expect(await fixture.committer.commit(prepared.request), 1);
      await _expectPersisted(fixture, 1, seed);
      expect(
        (await fixture.trackers.get(
          LedgerClockPersistenceFixture.sessionId,
          'world:location',
        ))!.value,
        'gate',
      );
    },
  );

  test('normalization cannot bypass the real manual mutation fence', () async {
    final fixture = LedgerClockPersistenceFixture();
    addTearDown(fixture.db.close);
    const seed = GameTimeState(time: '10:00', date: '01.01.2026', day: 0);
    await fixture.seed(seed);
    final prepared = await fixture.prepare(
      ledgerClockExport([ledgerClockSet('world:time', '10:5')]),
      1,
    );
    await fixture.trackers.bumpLedgerManualMutationRevision(
      LedgerClockPersistenceFixture.sessionId,
    );
    await expectLater(
      fixture.committer.commit(prepared.request),
      throwsA(isA<LedgerCommitStale>()),
    );
    expect(_values(await fixture.clockRows()), _clockValues(seed));
    expect(await fixture.snapshot(1), isNull);
  });

  test(
    'canonical time op still respects the owning repository canon lock',
    () async {
      final fixture = LedgerClockPersistenceFixture();
      addTearDown(fixture.db.close);
      const seed = GameTimeState(time: '10:00', date: '01.01.2026', day: 0);
      await fixture.seed(seed);
      await fixture.trackers.upsertValue(
        LedgerClockPersistenceFixture.sessionId,
        'canon_lock:world:time',
        'true',
        scope: 'ledger',
      );
      final prepared = await fixture.prepare(
        ledgerClockExport([ledgerClockSet('world:time', '10:5')]),
        1,
      );
      expect(prepared.parsed.export!.ops.single.value, '10:05');
      await fixture.committer.commit(prepared.request);
      await _expectPersisted(fixture, 1, seed);
    },
  );

  test(
    'snapshot failure rolls all canonical tracker writes back atomically',
    () async {
      final fixture = LedgerClockPersistenceFixture();
      addTearDown(fixture.db.close);
      const seed = GameTimeState(time: '23:59', date: '01.01.2026', day: 0);
      await fixture.seed(seed);
      final prepared = await fixture.prepare(
        ledgerClockExport([
          ledgerClockSet('world:time', '0:2'),
          ledgerClockSet('world:date', '02-01-2026'),
          ledgerClockSet('world:day', '01'),
        ]),
        1,
      );
      final committer = LedgerTurnCommitter(
        trackerRepo: fixture.trackers,
        snapshotRepo: _FailingSnapshotRepo(fixture),
        knowledgeFactRepo: CharacterKnowledgeFactRepo(fixture.db),
        canonAuthority: fixture.authority,
      );
      expect(prepared.parsed.export!.ops, hasLength(3));
      await expectLater(committer.commit(prepared.request), throwsStateError);
      expect(_values(await fixture.clockRows()), _clockValues(seed));
      expect(await fixture.snapshot(1), isNull);
      expect((await fixture.currentClock()).format(), seed.format());
    },
  );
}

Future<void> _expectPersisted(
  LedgerClockPersistenceFixture fixture,
  int turn,
  GameTimeState expected,
) async {
  final liveRows = await fixture.clockRows();
  expect(_values(liveRows), _clockValues(expected));
  final snapshot = await fixture.snapshot(turn);
  expect(snapshot, isNotNull);
  expect(snapshot!.committed, isFalse);
  expect(_values(snapshot.trackers), _clockValues(expected));
  expect(
    snapshot.trackers.where(
      (tracker) => _clockValues(expected).containsKey(tracker.name),
    ),
    liveRows,
  );
  expect(
    GameTimeState.fromTrackers(snapshot.trackers).format(),
    expected.format(),
  );
  await fixture.accept(turn);
  // Both the repository snapshot-first reader and the next prepare() use this
  // durable accepted baseline; no in-memory expected clock is injected.
  expect((await fixture.currentClock()).format(), expected.format());
}

Map<String, String> _clockValues(GameTimeState clock) => {
  'world:time': clock.time!,
  'world:date': clock.date!,
  'world:day': '${clock.day!}',
};

Map<String, String> _values(Iterable<Tracker> trackers) => {
  for (final tracker in trackers)
    if (const {'world:time', 'world:date', 'world:day'}.contains(tracker.name))
      tracker.name: tracker.value,
};

int _delta(GameTimeState next, GameTimeState current) {
  int minutes(String time) {
    final parts = time.split(':').map(int.parse).toList();
    return parts[0] * 60 + parts[1];
  }

  return (next.day! - current.day!) * 1440 +
      minutes(next.time!) -
      minutes(current.time!);
}

final class _FailingSnapshotRepo extends TrackerSnapshotRepo {
  _FailingSnapshotRepo(LedgerClockPersistenceFixture fixture)
    : super(fixture.db);

  @override
  Future<void> upsertTrackers({
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
    required List<Tracker> trackers,
    bool committed = false,
  }) async => throw StateError('Synthetic snapshot failure');
}
