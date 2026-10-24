import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/game_time.dart';
import 'package:glaze_flutter/core/llm/studio_ledger_export_parser.dart';

import 'fixtures/ledger_clock_exports.dart';

void main() {
  const parser = StudioLedgerExportParser();
  const morning = LedgerClockPolicy.turn(
    current: GameTimeState(time: '10:00', date: '01.01.2026', day: 0),
  );
  const midnight = LedgerClockPolicy.turn(
    current: GameTimeState(time: '23:59', date: '01.01.2026', day: 0),
  );

  test(
    'all three numeric clock formats produce the identical canonical ops',
    () {
      final canonical = [
        ledgerClockSet('world:location', 'gate'),
        ledgerClockSet('world:date', '02.01.2026'),
        ledgerClockSet('world:time', '00:02'),
        ledgerClockSet('scene.immediate_thread', 'waiting'),
        ledgerClockSet('world:day', '1'),
      ];
      final numeric = [
        canonical[0],
        ledgerClockSet('world:date', '02-01-2026'),
        ledgerClockSet('world:time', '0:2'),
        canonical[3],
        ledgerClockSet('world:day', '01'),
      ];

      final expected = parser.parse(
        ledgerClockExport(canonical),
        clockPolicy: midnight,
      );
      final result = parser.parse(
        ledgerClockExport(numeric),
        clockPolicy: midnight,
      );

      expect(result.export!.ops, expected.export!.ops);
      expect(result.export!.ops.map((op) => op.toJson()), canonical);
      expect(result.rejectedOps, isEmpty);
      expect(result.failure, LedgerParseFailure.none);
      expect(result.visibleLedger, 'Synthetic clock update');
    },
  );

  for (final (raw, value) in [('10:5', '10:05'), ('10:06', '10:06')]) {
    test('time-only $raw inherits the complete current date and RP day', () {
      final result = parser.parse(
        ledgerClockExport([ledgerClockSet('world:time', raw)]),
        clockPolicy: morning,
      );

      expect(result.export!.ops.single.value, value);
      expect(
        result.export!.ops.single.evidence,
        'Synthetic elapsed-time estimate',
      );
      expect(result.export!.ops.single.eventState, 'completed');
      expect(result.rejectedOps, isEmpty);
    });
  }

  test('zero-padded RP day normalizes without inventing an advance', () {
    for (final value in ['00', 0]) {
      final result = parser.parse(
        ledgerClockExport([ledgerClockSet('world:day', value)]),
        clockPolicy: morning,
      );
      expect(result.export!.ops.single.value, '0');
      expect(result.rejectedOps, isEmpty);
    }
  });

  for (final (key, value) in <(String, Object?)>[
    ('world:time', 'at 10:5'),
    ('world:time', '10:5 tomorrow'),
    ('world:time', '+5 minutes'),
    ('world:time', '10:05:00'),
    ('world:time', '24:00'),
    ('world:time', '10:60'),
    ('world:time', '100:05'),
    ('world:time', '9:59'),
    ('world:time', '0:1'),
    ('world:date', '31-02-2026'),
    ('world:date', '29-02-2026'),
    ('world:date', '2026-01-01'),
    ('world:date', '1.1.2026'),
    ('world:date', '01.01.2026 evening'),
    ('world:date', 'Second Moon, day 1'),
    ('world:day', '-1'),
    ('world:day', '+1'),
    ('world:day', '1.0'),
    ('world:day', 'RP_Day 1'),
    ('world:day', true),
    ('world:day', 1.5),
    ('world:time', ['10:5']),
    ('world:date', ['01-01-2026']),
    ('world:day', ['00']),
    ('world:day', {'value': '0'}),
    ('world:day', null),
  ]) {
    test('does not repair invalid, ambiguous, or backward $key=$value', () {
      final result = parser.parse(
        ledgerClockExport([
          ledgerClockSet(key, value),
          if (key != 'world:day') ledgerClockSet('world:day', '00'),
          ledgerClockSet('world:location', 'gate'),
        ]),
        clockPolicy: morning,
      );
      expect(result.export!.ops.map((op) => op.key), ['world:location']);
      expect(result.rejectedOps, hasLength(key == 'world:day' ? 1 : 2));
    });
  }

  test(
    'explicit normalized date and day disagreement still rejects all clocks',
    () {
      for (final (date, day) in [
        ('02-01-2026', '02'),
        ('01-01-2026', '01'),
        ('31-12-2025', '00'),
      ]) {
        final result = parser.parse(
          ledgerClockExport([
            ledgerClockSet('world:date', date),
            ledgerClockSet('world:day', day),
            ledgerClockSet('world:time', '10:5'),
            ledgerClockSet('world:location', 'gate'),
          ]),
          clockPolicy: morning,
        );
        expect(result.export!.ops.single.key, 'world:location');
        expect(result.rejectedOps, hasLength(3));
      }
    },
  );

  test(
    'unknown opcode, deletes, and equal normalized duplicates stay atomic',
    () {
      for (final bad in [
        [
          {'op': 'explode', 'key': 'world:date', 'value': '01-01-2026'},
        ],
        [
          {'op': 'delete', 'key': 'world:date'},
        ],
        [ledgerClockSet('world:time', '10:05')],
        [ledgerClockSet('world:time', '10:5')],
      ]) {
        final result = parser.parse(
          ledgerClockExport([
            ledgerClockSet('world:time', '10:5'),
            ...bad,
            ledgerClockSet('world:day', '00'),
            ledgerClockSet('world:location', 'gate'),
          ]),
          clockPolicy: morning,
        );
        expect(result.export!.ops.single.key, 'world:location');
        expect(result.rejectedOps, hasLength(3));
      }
    },
  );

  test('reconciliation rejects even a fully valid normalized clock packet', () {
    final result = parser.parse(
      ledgerClockExport([
        ledgerClockSet('world:time', '0:2'),
        ledgerClockSet('world:date', '02-01-2026'),
        ledgerClockSet('world:day', '01'),
        ledgerClockSet('world:location', 'gate'),
      ]),
      clockPolicy: const LedgerClockPolicy.reconciliation(),
    );
    expect(result.export!.ops.single.key, 'world:location');
    expect(result.rejectedOps, hasLength(3));
    expect(result.rejectedOps.join('\n'), contains('reconciliation'));
  });

  test(
    'a planned prose value is not converted to the embedded clock number',
    () {
      final result = parser.parse(
        ledgerClockExport([
          {
            ...ledgerClockSet('world:time', '10:5 tomorrow'),
            'eventState': 'planned',
          },
          ledgerClockSet('world:date', '01-01-2026'),
          ledgerClockSet('world:day', '00'),
          ledgerClockSet('world:location', 'gate'),
        ]),
        clockPolicy: morning,
      );
      expect(result.export!.ops.single.key, 'world:location');
      expect(result.rejectedOps, hasLength(3));
    },
  );

  test('a normalized tuple still cannot move the RP day backward', () {
    final result = parser.parse(
      ledgerClockExport([
        ledgerClockSet('world:time', '10:5'),
        ledgerClockSet('world:date', '31-12-2025'),
        ledgerClockSet('world:day', '02'),
        ledgerClockSet('world:location', 'gate'),
      ]),
      clockPolicy: const LedgerClockPolicy.turn(
        current: GameTimeState(time: '10:00', date: '01.01.2026', day: 3),
      ),
    );
    expect(result.export!.ops.single.key, 'world:location');
    expect(result.rejectedOps, hasLength(3));
    expect(
      result.rejectedOps.join('\n'),
      contains('world:day cannot move backward'),
    );
  });

  test(
    'a malformed complete current calendar is not repaired by normalization',
    () {
      final result = parser.parse(
        ledgerClockExport([
          ledgerClockSet('world:time', '10:5'),
          ledgerClockSet('world:date', '01-03-2026'),
          ledgerClockSet('world:day', '00'),
          ledgerClockSet('world:location', 'gate'),
        ]),
        clockPolicy: const LedgerClockPolicy.turn(
          current: GameTimeState(time: '10:00', date: '31.02.2026', day: 0),
        ),
      );
      expect(result.export!.ops.single.key, 'world:location');
      expect(result.rejectedOps, hasLength(3));
      expect(result.rejectedOps.join('\n'), contains('valid calendar date'));
    },
  );

  test(
    'a numeric packet cannot bootstrap or complete a partial current clock',
    () {
      for (final current in const [
        GameTimeState(),
        GameTimeState(time: '10:00'),
        GameTimeState(time: '10:00', date: '01.01.2026'),
        GameTimeState(date: '01.01.2026', day: 0),
        GameTimeState(time: '10:00', day: 0),
      ]) {
        final result = parser.parse(
          ledgerClockExport([
            ledgerClockSet('world:time', '10:5'),
            ledgerClockSet('world:date', '01-01-2026'),
            ledgerClockSet('world:day', '00'),
            ledgerClockSet('world:location', 'gate'),
          ]),
          clockPolicy: LedgerClockPolicy.turn(current: current),
        );
        expect(result.export!.ops.single.key, 'world:location');
        expect(result.rejectedOps, hasLength(3));
        expect(
          result.rejectedOps.join('\n'),
          contains('complete current clock'),
        );
      }
    },
  );
}
