import 'package:flutter_test/flutter_test.dart';

import 'helpers/support_mutation_journal_fixture.dart' show JournalBarrier;

const deletionFailureCanary = 'SYNTHETIC_DELETE_PRIVATE_FAILURE_CANARY';
const reloadFailureCanary = 'SYNTHETIC_RELOAD_PRIVATE_FAILURE_CANARY';

bool isBulkSessionReload(String event) => RegExp(
  r'^select:SELECT \* FROM "?support_sessions"? ORDER BY\b',
  caseSensitive: false,
).hasMatch(event);

/// Observes the ORIGINAL delivered Drift transaction, then fails only the bulk
/// workspace read. Neither callback substitutes a deletion result or SQL write.
final class ThemeDeletionPostCommitFailure {
  ThemeDeletionPostCommitFailure({
    required this.targetAbsent,
    this.commitGate,
    this.reloadGate,
    this.failCommitDelivery = false,
  });

  final Future<bool> Function() targetAbsent;
  final JournalBarrier? commitGate, reloadGate;
  final bool failCommitDelivery;
  int commits = 0, reloadQueries = 0, failures = 0;
  bool committed = false;

  Future<void> afterCommit() async {
    commits++;
    expect(await targetAbsent(), isTrue);
    committed = true;
    await commitGate?.wait();
    if (failCommitDelivery) {
      failures++;
      throw StateError(deletionFailureCanary);
    }
  }

  Future<void> sqlEvent(String event) async {
    if (!committed || failCommitDelivery || !isBulkSessionReload(event)) return;
    reloadQueries++;
    if (failures != 0) return;
    await reloadGate?.wait();
    failures++;
    throw StateError(reloadFailureCanary);
  }
}

final Matcher payloadFreeFailure = allOf(
  isA<String>(),
  isNot(isEmpty),
  isNot(contains(deletionFailureCanary)),
  isNot(contains(reloadFailureCanary)),
  isNot(contains('SYNTHETIC_SQL_PRIVATE_FAILURE_CANARY')),
  isNot(contains('support_sessions')),
  isNot(contains('support_mutation_journal')),
);
