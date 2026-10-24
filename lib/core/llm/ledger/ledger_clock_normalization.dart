import '../../models/studio_ledger_export.dart';
import '../game_time.dart';

/// Canonicalizes numeric clock values using the clock's existing strict parser.
/// Invalid values remain unchanged so tuple validation still rejects them.
abstract final class LedgerClockNormalization {
  static LedgerOp normalizeOp(LedgerOp op) {
    if (op.op != 'set') return op;
    final parsed = GameTimeState.parse(
      time: op.key == GameTimeState.timeKey ? op.value : '',
      date: op.key == GameTimeState.dateKey ? op.value : '',
      day: op.key == GameTimeState.dayKey ? op.value : '',
    );
    final value = switch (op.key) {
      GameTimeState.timeKey => parsed.time,
      GameTimeState.dateKey => parsed.date,
      GameTimeState.dayKey => parsed.day?.toString(),
      _ => null,
    };
    return value == null || value == op.value ? op : op.copyWith(value: value);
  }
}
