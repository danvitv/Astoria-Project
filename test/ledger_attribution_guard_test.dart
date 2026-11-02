import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/ledger/ledger_attribution_guard.dart';
import 'package:glaze_flutter/core/models/studio_ledger_export.dart';
import 'package:glaze_flutter/core/models/tracker.dart';

const _akaneKey = 'npc:Акане Курокава.attitude_to_user';
const _kanaKey = 'npc:Кана Арима.attitude_to_user';
const _akaneClaim =
    'Считает, что поехала с ним не ради машины, а чтобы '
    'побыть наедине; ценит внимание без зрителей. '
    'На её колени можно положить голову в любой день.';
const _kanaClaim =
    'У капота Skyline смягчилась: позволила притянуть себя '
    'за плечо, смеялась, скрепила договор мизинцем. '
    'Вход в их круг не измеряется дорогими подарками.';

void main() {
  const trackers = [
    Tracker(
      sessionId: 's',
      name: _akaneKey,
      value: _akaneClaim,
      scope: 'ledger',
    ),
    Tracker(sessionId: 's', name: _kanaKey, value: _kanaClaim, scope: 'ledger'),
  ];
  void validate(
    String value, {
    String source = 'Кана у капота смеялась и скрепила договор мизинцем.',
    List<Tracker> prior = trackers,
  }) => LedgerAttributionGuard.validate(
    ops: [LedgerOp(op: 'set', key: _kanaKey, value: value)],
    priorTrackers: prior,
    sourceText: source,
  );

  test('rejects Akane private-ride prose newly copied into Kana', () {
    expect(
      () => validate('$_akaneClaim $_kanaClaim'),
      throwsA(isA<LedgerAttributionConflict>()),
    );
  });

  test('preserves real Kana hood conversation and new relationship choice', () {
    expect(
      () => validate('$_kanaClaim Кана согласилась начать отношения.'),
      returnsNormally,
    );
  });

  test('does not erase established owned state just because NPC is absent', () {
    expect(
      () => validate(
        '$_akaneClaim $_kanaClaim',
        prior: [
          trackers[0],
          trackers[1].copyWith(value: '$_akaneClaim $_kanaClaim'),
        ],
      ),
      returnsNormally,
    );
  });

  test('allows shared scene when both independent subjects participate', () {
    expect(
      () => validate(
        '$_akaneClaim $_kanaClaim',
        source: 'Кана и Акане вместе рассказали о поездке.',
      ),
      returnsNormally,
    );
  });

  test('allows exact new source evidence, including explicit user retcon', () {
    expect(
      () => validate(
        '$_akaneClaim $_kanaClaim',
        source: '[OOC: Это также было с Каной: $_akaneClaim]',
      ),
      returnsNormally,
    );
  });

  test('short generic friendliness is not treated as copied intimacy', () {
    expect(
      () => validate('Доброжелательна, благодарна и доверяет ему.'),
      returnsNormally,
    );
  });

  test('non-relationship ops and deletes are unaffected', () {
    expect(
      () => LedgerAttributionGuard.validate(
        ops: const [
          LedgerOp(op: 'set', key: 'world:location', value: _akaneClaim),
          LedgerOp(op: 'delete', key: _kanaKey),
        ],
        priorTrackers: trackers,
        sourceText: '',
      ),
      returnsNormally,
    );
  });
}
