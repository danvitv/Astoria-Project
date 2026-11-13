import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/state/session_mutation_gate.dart';

void main() {
  test('foreground blocks apply until every nested claim settles', () {
    final gate = SessionMutationGate();
    final first = gate.tryForeground('a')!;
    final second = gate.tryForeground('a')!;
    expect(gate.tryApply('a'), isNull);
    first.release();
    first.release();
    expect(gate.tryApply('a'), isNull);
    second.release();
    expect(gate.tryApply('a'), isNotNull);
  });

  test('apply blocks foreground and duplicate apply, not other sessions', () {
    final gate = SessionMutationGate();
    final apply = gate.tryApply('a')!;
    expect(gate.tryForeground('a'), isNull);
    expect(gate.tryApply('a'), isNull);
    expect(gate.tryForeground('b'), isNotNull);
    apply.release();
    final newer = gate.tryApply('a')!;
    apply.release();
    expect(gate.tryForeground('a'), isNull);
    newer.release();
    expect(gate.tryForeground('a'), isNotNull);
  });

  test('disposal cannot be undone by a late release', () {
    final gate = SessionMutationGate();
    final lease = gate.tryApply('a')!;
    gate.dispose();
    lease.release();
    expect(gate.tryForeground('a'), isNull);
    expect(gate.tryApply('a'), isNull);
  });

  test(
    'selection and apply exclude each other before the target is loaded',
    () async {
      final gate = SessionMutationGate();
      final selection = gate.trySelection('c')!;
      expect(gate.tryApply('b', characterId: 'c'), isNull);
      selection.release();
      final apply = gate.tryApply('b', characterId: 'c')!;
      expect(gate.trySelection('c'), isNull);
      var resumed = false;
      final replacement = gate.waitSelection('c').then((lease) {
        resumed = true;
        return lease;
      });
      await Future<void>.value();
      expect(resumed, isFalse);
      expect(gate.trySelection('other'), isNotNull);
      apply.release();
      final loaded = await replacement;
      expect(loaded, isNotNull);
      expect(gate.tryApply('b', characterId: 'c'), isNull);
      loaded!.release();
      expect(gate.tryApply('b', characterId: 'c'), isNotNull);
    },
  );
}
