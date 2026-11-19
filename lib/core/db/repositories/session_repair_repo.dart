import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../llm/game_time.dart';
import '../../models/ledger_preset_instruction_defaults.dart';
import '../../models/chat_message.dart';
import '../../models/support_models.dart';
import '../app_db.dart';
import '../database_transaction_guard.dart';
import '../models/session_repair.dart';
import 'ledger_reconciliation_run_repo.dart';
import 'reconciliation_state_codec.dart';
import 'support_repo.dart';
import 'tracker_repo.dart';
import 'chat_message_storage_sql.dart';

part 'session_repair/contract.dart';
part 'session_repair/raw_store.dart';
part 'session_repair/inspection.dart';
part 'session_repair/ledger_validation.dart';
part 'session_repair/mutation_store.dart';
part 'session_repair/recorded_hash_inspection.dart';
part 'session_repair/ledger_analysis.dart';

/// Native-only, two-operation repair owner. Nothing here grants body disclosure,
/// mutation approval, source admission or a global mutex. The application must
/// synchronously begin the exact ChatSourceMutationRegistry mutation BEFORE its
/// first await, retain original DB/session/operation custody, and pass that live
/// identity guard. Queue ordering alone is not authority. After durable return,
/// refresh live Ledger/Collector/InfoBlocks and evict source/prompt identities
/// from the latest DB state; NEVER publish this private preview as a chat row.
final class SessionRepairRepo {
  SessionRepairRepo(this._db, this._support) : _raw = _RepairRawStore(_db);
  final AppDatabase _db;
  final SupportRepo _support;
  final _RepairRawStore _raw;
  static const journalDomain = 'session.repair';

  /// Fixed structural facts only. No private text is transferred out of SQLite.
  Future<Map<String, Object?>> inspectLedgerAnalysis({
    required String targetSessionId,
    required String supportSessionId,
    required bool Function() isCurrent,
  }) => _LedgerAnalysisReader(
    this,
  ).read(targetSessionId, supportSessionId, isCurrent);

  Future<SessionRepairInspection> inspect({
    required String targetSessionId,
    required String supportSessionId,
    required bool Function() isCurrent,
  }) => _RepairInspectionReader(
    this,
  ).inspect(targetSessionId, supportSessionId, isCurrent);

  /// Verifies recorded reconciliation hashes against their actual canonical
  /// content. This is not a caller-text hash utility or a narrative truth test.
  Future<SessionRecordedHashInspection> inspectRecordedHashes({
    required String targetSessionId,
    required String supportSessionId,
    required bool Function() isCurrent,
  }) => _RepairRecordedHashReader(
    this,
  ).inspect(targetSessionId, supportSessionId, isCurrent);

  Future<SessionRepairPreparation> prepareDeleteUnusedCollectorAttempt({
    required SessionRepairTarget target,
    required String operationId,
    required int createdAt,
    required bool Function() isCurrent,
  }) => _RepairMutationStore(
    this,
  ).prepare(target, operationId, createdAt, isCurrent, null);

  /// A native typed value, not tool JSON, SQL, a path or a generic operation.
  /// Only the exact existing natural key retained inside [target] is writable.
  Future<SessionRepairPreparation> prepareCorrectExistingLedgerValue({
    required SessionRepairTarget target,
    required String value,
    required String operationId,
    required int createdAt,
    required bool Function() isCurrent,
  }) => _RepairMutationStore(
    this,
  ).prepare(target, operationId, createdAt, isCurrent, value);

  Future<SessionRepairReceipt?> apply({
    required SessionRepairPlan plan,
    required bool Function() isCurrent,
  }) => _RepairMutationStore(this).apply(plan, isCurrent);

  /// Observe the SAME original parent before a later run's native confirmation.
  /// Its activity clock may have advanced; identity/settings may not. This proof
  /// is neither approval nor a restoration target and has no import/JSON path.
  Future<SessionRepairUndoObservation?> prepareUndo({
    required SessionRepairReceipt receipt,
    required String supportSessionId,
    required bool Function() isCurrent,
  }) => _RepairMutationStore(
    this,
  ).prepareUndo(receipt, supportSessionId, isCurrent);

  /// Fresh exact native approval is required; an old apply guard is deliberately
  /// not reused as Undo consent. Dependencies and exact after-image must match.
  /// A prepared parent is rechecked in full after confirmation/decryption. If
  /// omitted, the original full parent guard applies without any clock allowance.
  Future<SessionRepairReceipt?> undo({
    required SessionRepairReceipt receipt,
    required bool Function() isCurrent,
    SessionRepairUndoObservation? parentObservation,
  }) => _RepairMutationStore(this).undo(receipt, isCurrent, parentObservation);

  /// Explicit native body-source lease only. The lease owner must bind this
  /// exact plan, target session/record/hash, fields and source checkpoint. Astoria
  /// Send and mutation consent alone do not satisfy this callback. Never put the
  /// return into automatic LLM context. Raw malformed originals stay intact.
  Future<SessionRepairNativePreview?> readNativePreview({
    required SessionRepairPlan plan,
    required bool Function() hasExactBodySourceLease,
  }) async {
    bool current() =>
        identical(plan._owner, this) &&
        plan._current() &&
        hasExactBodySourceLease();
    try {
      return await _repairTransaction(_db, current, () async {
        _repairRequire(await _raw.matches(plan._before, current));
        return SessionRepairNativePreview._(plan);
      });
    } on _RepairRefused {
      return null;
    }
  }
}
