import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/game_time.dart';
import 'package:glaze_flutter/core/llm/ledger/ledger_output_recovery.dart';
import 'package:glaze_flutter/core/llm/studio_ledger_export_parser.dart';
import 'package:glaze_flutter/core/models/studio_ledger_export.dart';

import 'fixtures/ledger_clock_exports.dart';

void main() {
  const recovery = LedgerOutputRecovery();
  const parser = StudioLedgerExportParser();
  const morning = LedgerClockPolicy.turn(
    current: GameTimeState(time: '10:00', date: '01.01.2026', day: 0),
  );
  const midnight = LedgerClockPolicy.turn(
    current: GameTimeState(time: '23:59', date: '01.01.2026', day: 0),
  );
  const closingTag = '</glaze_memory_export>';

  final sourceOps = [
    ledgerClockSet('world:time', '10:5'),
    ledgerClockSet('world:location', 'gate'),
  ];
  final original = ledgerClockExport(sourceOps).replaceFirst(closingTag, '');

  StudioLedgerExport parseRepair(
    List<Map<String, Object?>> ops, {
    List<LedgerKnowledgeFact> facts = const [],
  }) {
    final raw =
        '<glaze_memory_export>${jsonEncode({'ops': ops, 'knowledgeFacts': facts.map((fact) => fact.toJson()).toList()})}</glaze_memory_export>';
    final parsed = parser.parse(raw, clockPolicy: morning);
    expect(parsed.export, isNotNull);
    expect(parsed.rejectedOps, isEmpty);
    return parsed.export!;
  }

  test(
    'closing-tag-only repair retains canonical time and unrelated location',
    () {
      final incomplete = parser.parse(original, clockPolicy: morning);
      expect(incomplete.failure, LedgerParseFailure.incompleteJson);
      expect(incomplete.export, isNull);

      final repaired = parser.parse(
        '$original$closingTag',
        clockPolicy: morning,
      );
      expect(repaired.rejectedOps, isEmpty);
      expect(repaired.export!.ops, [
        LedgerOp.fromJson(sourceOps[0]).copyWith(value: '10:05'),
        LedgerOp.fromJson(sourceOps[1]),
      ]);
      expect(
        recovery.repairPreservesStructuredEvidence(original, repaired.export!),
        isTrue,
      );
    },
  );

  test('closing-tag-only repair retains a fully normalized midnight tuple', () {
    final ops = [
      ledgerClockSet('world:date', '02-01-2026'),
      ledgerClockSet('world:day', '01'),
      ledgerClockSet('world:time', '0:2'),
      ledgerClockSet('world:location', 'gate'),
    ];
    final source = ledgerClockExport(ops).replaceFirst(closingTag, '');
    final repaired = parser.parse('$source$closingTag', clockPolicy: midnight);
    expect(repaired.rejectedOps, isEmpty);
    expect(repaired.export!.ops, [
      LedgerOp.fromJson(ops[0]).copyWith(value: '02.01.2026'),
      LedgerOp.fromJson(ops[1]).copyWith(value: '1'),
      LedgerOp.fromJson(ops[2]).copyWith(value: '00:02'),
      LedgerOp.fromJson(ops[3]),
    ]);
    expect(
      recovery.repairPreservesStructuredEvidence(source, repaired.export!),
      isTrue,
    );
  });

  test('closing-tag-only repair retains same-day numeric spellings', () {
    final ops = [
      ledgerClockSet('world:time', '10:5'),
      ledgerClockSet('world:date', '01-01-2026'),
      ledgerClockSet('world:day', '00'),
      ledgerClockSet('world:location', 'gate'),
    ];
    final source = ledgerClockExport(ops).replaceFirst(closingTag, '');
    final repaired = parser.parse('$source$closingTag', clockPolicy: morning);
    expect(repaired.rejectedOps, isEmpty);
    expect(repaired.export!.ops.map((op) => op.value), [
      '10:05',
      '01.01.2026',
      '0',
      'gate',
    ]);
    expect(
      recovery.repairPreservesStructuredEvidence(source, repaired.export!),
      isTrue,
    );
  });

  for (final changed in ['10:6', '11:05']) {
    test('changed numeric meaning $changed is not source evidence', () {
      final repaired = parseRepair([
        {...sourceOps[0], 'value': changed},
        sourceOps[1],
      ]);
      expect(
        recovery.repairPreservesStructuredEvidence(original, repaired),
        isFalse,
      );
    });
  }

  test('coordinated date/day advance is still invented numeric meaning', () {
    final ops = [
      ledgerClockSet('world:date', '02-01-2026'),
      ledgerClockSet('world:day', '01'),
      ledgerClockSet('world:time', '0:2'),
      sourceOps[1],
    ];
    final source = ledgerClockExport(ops).replaceFirst(closingTag, '');
    final repaired = parser.parse(
      ledgerClockExport([
        {...ops[0], 'value': '03-01-2026'},
        {...ops[1], 'value': '02'},
        ops[2],
        ops[3],
      ]),
      clockPolicy: midnight,
    );
    expect(repaired.rejectedOps, isEmpty);
    expect(repaired.export!.ops, hasLength(4));
    expect(
      recovery.repairPreservesStructuredEvidence(source, repaired.export!),
      isFalse,
    );
  });

  for (final (field, value) in [
    ('key', 'world:current_conditions'),
    ('evidence', 'Invented elapsed-time evidence'),
    ('eventState', 'unknown'),
  ]) {
    test('clock normalization does not relax source $field equality', () {
      final repaired = parseRepair([
        {...sourceOps[0], field: value},
        sourceOps[1],
      ]);
      expect(
        recovery.repairPreservesStructuredEvidence(original, repaired),
        isFalse,
      );
    });
  }

  test(
    'operation code remains exact even for unrelated accepted operations',
    () {
      final repaired = parseRepair([
        sourceOps[0],
        {...sourceOps[1], 'op': 'delete'},
      ]);
      expect(
        recovery.repairPreservesStructuredEvidence(original, repaired),
        isFalse,
      );
    },
  );

  test('inserted operation rejects the entire otherwise-equivalent export', () {
    final repaired = parseRepair([
      ...sourceOps,
      ledgerClockSet('scene.immediate_thread', 'invented'),
    ]);
    expect(
      recovery.repairPreservesStructuredEvidence(original, repaired),
      isFalse,
    );
  });

  const fact = LedgerKnowledgeFact(
    knowerKey: 'entity:alice',
    subjectKey: 'entity:bob',
    predicate: 'heard_claim',
    object: 'Synthetic claim',
  );

  test(
    'inserted knowledge fact is not authorized by numeric clock equivalence',
    () {
      final repaired = parseRepair(sourceOps, facts: [fact]);
      expect(
        recovery.repairPreservesStructuredEvidence(original, repaired),
        isFalse,
      );
    },
  );

  test(
    'unchanged facts still match strictly; changed fact content still fails',
    () {
      final source =
          '<glaze_memory_export>${jsonEncode({
            'ops': sourceOps,
            'knowledgeFacts': [fact.toJson()],
          })}';
      final repaired = parser.parse('$source$closingTag', clockPolicy: morning);
      expect(repaired.rejectedOps, isEmpty);
      expect(repaired.export!.knowledgeFacts, [fact]);
      expect(
        recovery.repairPreservesStructuredEvidence(source, repaired.export!),
        isTrue,
      );
      final changed = parseRepair(
        sourceOps,
        facts: [fact.copyWith(object: 'Invented claim')],
      );
      expect(
        recovery.repairPreservesStructuredEvidence(source, changed),
        isFalse,
      );
    },
  );

  for (final (key, raw, canonical) in <(String, Object?, String)>[
    ('world:time', 'at 10:5', '10:05'),
    ('world:time', '+5 minutes', '10:05'),
    ('world:time', '10:05:00', '10:05'),
    ('world:time', '24:00', '10:05'),
    ('world:time', ['10:5'], '10:05'),
    ('world:time', {'value': '10:5'}, '10:05'),
    ('world:time', 1005, '10:05'),
    ('world:date', 'On 01-01-2026', '01.01.2026'),
    ('world:date', '31-02-2026', '01.01.2026'),
    ('world:day', ['00'], '0'),
    ('world:day', {'value': '0'}, '0'),
    ('world:day', true, '0'),
    ('world:day', 0, '0'),
    ('world:day', 0.0, '0'),
    ('world:day', null, '0'),
  ]) {
    test('prose/invalid source type $key=$raw cannot authorize a number', () {
      final source = ledgerClockExport([
        ledgerClockSet(key, raw),
        sourceOps[1],
      ]).replaceFirst(closingTag, '');
      final repaired = parseRepair([
        ledgerClockSet(key, canonical),
        sourceOps[1],
      ]);
      expect(
        recovery.repairPreservesStructuredEvidence(source, repaired),
        isFalse,
      );
    });
  }

  for (final (field, raw) in <(String, Object?)>[
    ('op', ['set']),
    ('key', ['world:time']),
    ('evidence', ['Synthetic elapsed-time estimate']),
    ('eventState', ['completed']),
    ('evidence', true),
    ('eventState', 1),
  ]) {
    test('strict source metadata decoding is preserved for $field=$raw', () {
      final source = ledgerClockExport([
        {...sourceOps[0], field: raw},
        sourceOps[1],
      ]).replaceFirst(closingTag, '');
      final repaired = parseRepair(sourceOps);
      expect(
        recovery.repairPreservesStructuredEvidence(source, repaired),
        isFalse,
      );
    });
  }

  for (final (sourceValue, repairedValue) in [
    ('gate', 'Gate'),
    (' gate ', 'gate'),
    ('01', '1'),
  ]) {
    test(
      'unrelated value remains exact: $sourceValue is not $repairedValue',
      () {
        final source = ledgerClockExport([
          sourceOps[0],
          {...sourceOps[1], 'value': sourceValue},
        ]).replaceFirst(closingTag, '');
        final repaired = parseRepair([
          sourceOps[0],
          {...sourceOps[1], 'value': repairedValue},
        ]);
        expect(
          recovery.repairPreservesStructuredEvidence(source, repaired),
          isFalse,
        );
      },
    );
  }

  test('empty-export evidence still requires explicit empty source arrays', () {
    expect(
      recovery.repairPreservesStructuredEvidence(
        original,
        const StudioLedgerExport(),
      ),
      isFalse,
    );
    expect(
      recovery.repairPreservesStructuredEvidence(
        '<glaze_memory_export>{"ops":[],"knowledgeFacts":[]}',
        const StudioLedgerExport(),
      ),
      isTrue,
    );
  });
}
