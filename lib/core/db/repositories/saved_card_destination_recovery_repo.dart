import 'dart:convert';

import '../../services/card_rewriter/card_rewrite_operation_parser.dart';
import '../../services/card_rewriter/card_rewriter_contracts.dart';
import '../../services/card_rewriter/saved_card_lorebook_rerouter.dart';
import '../../utils/cast_helpers.dart';
import '../app_db.dart';
import 'card_evolution_repo.dart';
import 'card_evolution_writer_call_repo.dart';

/// User-requested salvage of saved outputs. Completed calls remain immutable;
/// the regular finalizer still owns evidence/canon checks and proposal creation.
class SavedCardDestinationRecoveryRepo {
  const SavedCardDestinationRecoveryRepo({
    required this.db,
    required this.evolution,
    required this.calls,
  });

  final AppDatabase db;
  final CardEvolutionRepo evolution;
  final CardEvolutionWriterCallRepo calls;

  Future<CardEvolutionFinalizeOutcome> recover({
    required String claimId,
    required String sessionId,
    required String ownerId,
    required int now,
  }) async {
    try {
      return await db.transaction(() async {
        final claim = await evolution.getClaimById(claimId);
        if (claim == null ||
            claim.sessionId != sessionId ||
            claim.status != 'failed' ||
            claim.failureCode != 'invalidCardObservationTarget' ||
            claim.selectedInputJson == null ||
            computeHash(claim.selectedInputJson!) != claim.inputHash) {
          return const CardEvolutionFinalizeOutcome('notRecoverable');
        }
        final chain = await calls.readChain(claimId);
        for (var index = 0; index < chain.length; index++) {
          final row = chain[index];
          if (row.ordinal != index + 1 ||
              row.status != 'completed' ||
              row.sessionId != sessionId ||
              computeHash(row.prompt) != row.promptHash ||
              row.responseText == null ||
              computeHash(row.responseText!) != row.responseHash) {
            return const CardEvolutionFinalizeOutcome('invalidSavedChain');
          }
        }
        final cardCalls = chain
            .where(
              (row) =>
                  (row.stage == 'card_writer' || row.stage == 'card_repair') &&
                  row.parserCode == 'accepted',
            )
            .toList();
        final loreCalls = chain
            .where(
              (row) =>
                  row.stage == 'lorebook_writer' &&
                  row.parserCode == 'accepted',
            )
            .toList();
        if (cardCalls.length != 1 ||
            loreCalls.length != 1 ||
            chain.last.id != loreCalls.single.id ||
            cardCalls.single.ordinal >= loreCalls.single.ordinal) {
          return const CardEvolutionFinalizeOutcome('unsupportedSavedChain');
        }
        final cardCall = cardCalls.single;
        final loreCall = loreCalls.single;
        final card = CardRewriteOperationParser.parseEvolutionBatch(
          cardCall.responseText!,
        );
        final lore = CardRewriteOperationParser.parseLorebookEvolutionBatch(
          loreCall.responseText!,
        );
        if (card == null ||
            card.isEmpty ||
            lore == null ||
            lore.isEmpty ||
            _encode(card) != cardCall.resultJson ||
            _encode(lore) != loreCall.resultJson) {
          return const CardEvolutionFinalizeOutcome('savedResponseMismatch');
        }
        final repaired = SavedCardLorebookRerouter.reroute(
          cardOperations: card,
          loreOperations: lore,
          selectedInputJson: claim.selectedInputJson!,
        );
        final acquired = await evolution.claimFailedWriter(
          claimId: claimId,
          ownerId: ownerId,
          now: now,
          leaseSeconds: 300,
        );
        if (!acquired.isClaimed) {
          throw _RecoveryRollback(CardEvolutionFinalizeOutcome(acquired.kind));
        }
        final result = await evolution.finalize(
          claimId: claimId,
          ownerId: ownerId,
          now: now,
          operations: repaired,
          modelOutput: jsonEncode({
            'card': cardCall.responseText,
            'lorebook': loreCall.responseText,
            'recovery': {
              'kind': 'userRequestedCardToLorebookReroute',
              'cardCallId': cardCall.id,
              'lorebookCallId': loreCall.id,
              'originalFailure': claim.failureCode,
              'originalFailureDetail': claim.failureDetail,
              'originalFailedAt': claim.failedAt,
              'originalCardOperations': jsonDecode(cardCall.resultJson!),
              'repairedOperations': jsonDecode(_encode(repaired)),
            },
          }),
        );
        if (!result.isPersisted) throw _RecoveryRollback(result);
        return result;
      });
    } on _RecoveryRollback catch (failure) {
      return failure.outcome;
    }
  }

  static String _encode(Iterable<RewriteOperationSnapshot> operations) =>
      jsonEncode([
        for (final operation in operations)
          jsonDecode(RewriteOperationSnapshotCodec.encode(operation)),
      ]);
}

class _RecoveryRollback implements Exception {
  const _RecoveryRollback(this.outcome);
  final CardEvolutionFinalizeOutcome outcome;
}
