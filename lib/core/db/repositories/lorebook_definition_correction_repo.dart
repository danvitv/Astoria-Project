import 'dart:convert';

import '../../services/card_rewriter/card_rewriter_contracts.dart';
import '../../services/card_rewriter/effective_canon_assembler.dart';
import '../../services/card_rewriter/effective_canon_read_repository.dart';
import '../../services/card_rewriter/saved_card_lorebook_rerouter.dart';
import '../../utils/id_generator.dart';
import '../../utils/time_helpers.dart';
import '../app_db.dart';
import 'lorebook_repo.dart';
import 'manual_rewrite_apply_repo.dart';
import 'manual_rewrite_job_repo.dart';
import 'session_lorebook_evolution_repo.dart';

/// An explicit user canon correction, not automated evolution. Applies only a
/// separate definition patch, then re-anchors a still-pending proposal without
/// applying its other changes or rewriting immutable evidence/history.
class LorebookDefinitionCorrectionRepo {
  const LorebookDefinitionCorrectionRepo({
    required this.db,
    required this.canonReader,
    required this.jobs,
    required this.apply,
  });

  final AppDatabase db;
  final EffectiveCanonReadRepository canonReader;
  final ManualRewriteJobRepo jobs;
  final ManualRewriteApplyRepo apply;

  Future<String> correctAndRebasePending({
    required String sessionId,
    required String lorebookId,
    required String entryId,
    required String expectedBaseContent,
    required String expectedCurrentContent,
    required String pendingJobId,
    required String pendingOperationId,
    required int expectedPendingRevision,
    required String anchor,
    required String value,
    bool updateSharedDefinition = true,
  }) => db.transaction(() async {
    final books = LorebookRepo(db);
    final book = await books.getById(lorebookId);
    final matches = book?.entries
        .where((entry) => entry.id == entryId)
        .toList();
    if (book == null ||
        matches == null ||
        matches.length != 1 ||
        matches.single.content != expectedBaseContent) {
      throw StateError('Shared lore definition changed; retry correction');
    }
    final overlay = await SessionLorebookEvolutionRepo(db).getByTarget(
      sessionId: sessionId,
      lorebookId: lorebookId,
      entryId: entryId,
    );
    final current = overlay?.content ?? expectedBaseContent;
    if (current != expectedCurrentContent ||
        (overlay != null &&
            overlay.contentHash != CardCanonicalizer.scalarSha256(current))) {
      throw StateError('Session lore definition changed; retry correction');
    }
    final pending = await jobs.getJobSnapshot(pendingJobId);
    final views = pending?.operations
        .where((view) => view.operation.id == pendingOperationId)
        .toList();
    if (pending == null ||
        pending.job.status != 'pending' ||
        pending.job.chatSessionId != sessionId ||
        views == null ||
        views.length != 1) {
      throw StateError('Pending proposal is no longer available');
    }
    final view = views.single;
    final operation = RewriteOperationSnapshotCodec.tryDecode(
      jsonDecode(view.currentSnapshotJson),
    );
    if (view.operation.currentRevision != expectedPendingRevision ||
        view.operation.status != 'reviewable' ||
        view.operation.decision != 'pending' ||
        view.currentSnapshotJson != view.operation.operationJson ||
        operation is! LorebookRewriteOperationSnapshot ||
        operation.lorebookId != lorebookId ||
        operation.entryId != entryId ||
        operation.expectedContentHash !=
            CardCanonicalizer.scalarSha256(current)) {
      throw StateError('Pending lore proposal changed or its anchor is stale');
    }
    final nextCurrent = _replaceExact(current, anchor, value);
    final nextBase = updateSharedDefinition
        ? _replaceExact(expectedBaseContent, anchor, value)
        : expectedBaseContent;
    final proposed = SavedCardLorebookRerouter.applySavedPatches(
      operation,
      current,
    );
    final nextProposed = _replaceExact(proposed, anchor, value);
    final input = EffectiveCanonReadRepository.withInitialLineage(
      await canonReader.readInTransaction(
        sessionId: sessionId,
        characterId: pending.job.characterId,
      ),
    );
    const assembler = EffectiveCanonAssembler();
    final stable = assembler.assemble(input, stampVolatileState: false);
    if (stable.identity != pending.job.canonStamp) {
      throw StateError(
        'Pending proposal canon changed; correction cannot rebase it',
      );
    }
    final manual = assembler.assemble(input);
    final now = currentTimestampSeconds();
    final jobId = 'user-lore-correction-${generateId()}';
    final operationId = '$jobId:definition';
    final definition = LorebookRewriteOperationSnapshot(
      lorebookId: lorebookId,
      entryId: entryId,
      baseContent: overlay?.baseContent ?? expectedBaseContent,
      expectedContentHash: CardCanonicalizer.scalarSha256(current),
      patches: [
        LorebookAnchoredPatch(
          anchor: anchor,
          anchorSha256: CardCanonicalizer.scalarSha256(anchor),
          value: value,
        ),
      ],
    );
    await jobs.withPendingReviewSuspended<void>(
      jobId: pendingJobId,
      expectedVersion: pending.job.version,
      correction: () async {
        await jobs.insertPendingInTransaction(
          jobId: jobId,
          chatSessionId: sessionId,
          characterId: pending.job.characterId,
          requestJson: jsonEncode({
            'provenance': 'userDefinitionCorrection',
            'lorebookId': lorebookId,
            'entryId': entryId,
            'anchor': anchor,
            'value': value,
            'pendingProposalId': pendingJobId,
            'updateSharedDefinition': updateSharedDefinition,
          }),
          requestKey: jobId,
          basisRevision: manual.effectiveRevision.number,
          basisRevisionHash: manual.effectiveRevision.hash,
          canonStamp: manual.identity,
          operations: [
            ManualRewriteOperationDraft(
              id: operationId,
              snapshotJson: RewriteOperationSnapshotCodec.encode(definition),
            ),
          ],
          now: now,
        );
        final decision = await jobs.setDecision(
          operationId: operationId,
          expectedCurrentRevision: 1,
          expectedDecision: 'pending',
          decision: 'approved',
        );
        if (!decision.isUpdated) throw StateError('Definition approval failed');
        final ageJob = (await jobs.getJobSnapshot(jobId))!.job;
        final applied = await apply.applyApproved(
          jobId: jobId,
          expectedCanonStamp: manual.identity,
          expectedJobVersion: ageJob.version,
        );
        if (!applied.isApplied) {
          throw StateError('Definition correction blocked: ${applied.reason}');
        }
      },
    );
    if (updateSharedDefinition) {
      await books.put(
        book.copyWith(
          entries: [
            for (final entry in book.entries)
              entry.id == entryId ? entry.copyWith(content: nextBase) : entry,
          ],
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
    final actual = await SessionLorebookEvolutionRepo(db).getByTarget(
      sessionId: sessionId,
      lorebookId: lorebookId,
      entryId: entryId,
    );
    if (actual?.content != nextCurrent) {
      throw StateError('Unexpected corrected lore content');
    }
    final rebased = LorebookRewriteOperationSnapshot(
      lorebookId: lorebookId,
      entryId: entryId,
      baseContent: operation.baseContent,
      expectedContentHash: CardCanonicalizer.scalarSha256(nextCurrent),
      patches: [
        LorebookAnchoredPatch(
          anchor: nextCurrent,
          anchorSha256: CardCanonicalizer.scalarSha256(nextCurrent),
          value: nextProposed,
        ),
      ],
    );
    final edited = await jobs.editAndRevalidate(
      operationId: pendingOperationId,
      expectedCurrentRevision: expectedPendingRevision,
      newSnapshotJson: RewriteOperationSnapshotCodec.encode(rebased),
      evidence: [
        ManualRewriteEvidenceDraft(
          id: '$operationId:pending-rebase',
          evidenceJson: jsonEncode({
            'kind': 'userDefinitionCorrectionRebase',
            'definitionJobId': jobId,
            'oldSnapshotJson': view.currentSnapshotJson,
            'originalPendingRevision': expectedPendingRevision,
          }),
        ),
      ],
    );
    if (!edited.isUpdated || edited.operation?.validationStatus != 'valid') {
      throw StateError('Rebased pending proposal is invalid');
    }
    final afterInput = EffectiveCanonReadRepository.withInitialLineage(
      await canonReader.readInTransaction(
        sessionId: sessionId,
        characterId: pending.job.characterId,
      ),
    );
    if (assembler.assemble(afterInput, stampVolatileState: false).identity !=
        stable.identity) {
      throw StateError('Definition correction unexpectedly changed card canon');
    }
    return jobId;
  });

  static String _replaceExact(String text, String anchor, String value) {
    final start = text.indexOf(anchor);
    if (anchor.isEmpty ||
        start < 0 ||
        text.indexOf(anchor, start + 1) >= 0 ||
        !AnchoredScalarPatchValidator.preservesMacroTokens(anchor, value)) {
      throw const FormatException(
        'Definition anchor is missing, ambiguous or changes macros',
      );
    }
    return text.replaceRange(start, start + anchor.length, value);
  }
}
