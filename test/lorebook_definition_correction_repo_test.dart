import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/applied_canon_transition_repo.dart';
import 'package:glaze_flutter/core/db/repositories/canon_transition_fact_ref_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_knowledge_fact_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_revision_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_session_baseline_repo.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_raw_tracker_state_reader.dart';
import 'package:glaze_flutter/core/db/repositories/lorebook_definition_correction_repo.dart';
import 'package:glaze_flutter/core/db/repositories/lorebook_repo.dart';
import 'package:glaze_flutter/core/db/repositories/manual_rewrite_apply_repo.dart';
import 'package:glaze_flutter/core/db/repositories/manual_rewrite_job_repo.dart';
import 'package:glaze_flutter/core/db/repositories/session_lorebook_evolution_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_assembler.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_read_repository.dart';

const _age = 'adult 18+, exact age unspecified';
const _base = 'Miyako, $_age. She manages the agency.';
const _current = 'Miyako, $_age. She manages the agency with growing trust.';
const _liaison = 'Miyako and Danvi keep their liaison private.';

class _RejectRebase extends ManualRewriteJobRepo {
  _RejectRebase(AppDatabase db)
    : super(db: db, rawTrackerStateReader: LedgerRawTrackerStateReader(db));

  @override
  Future<RewriteOperationMutationOutcome> editAndRevalidate({
    required String operationId,
    required int expectedCurrentRevision,
    required String newSnapshotJson,
    List<ManualRewriteEvidenceDraft> evidence = const [],
  }) async => const RewriteOperationMutationOutcome.notFound();
}

void main() {
  late AppDatabase db;
  late EffectiveCanonReadRepository reader;
  late ManualRewriteJobRepo jobs;
  late String original;
  late String unrelated;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final characters = CharacterRepo(db);
    final revisions = CharacterRevisionRepo(db);
    final card = Character(
      id: 'c',
      name: 'Card',
      description: 'Unchanged card.',
    );
    await characters.put(card);
    await revisions.insert(
      CharacterRevisionRecord(
        characterId: 'c',
        revision: 1,
        revisionHash: CardCanonicalizer.sha256(card),
        parentRevisionHash: '',
        snapshotJson: jsonEncode(card.toJson()),
        createdAt: 1,
      ),
    );
    await ChatRepo(db).put(
      ChatSession(
        id: 's',
        characterId: 'c',
        sessionIndex: 0,
        updatedAt: 2,
        messages: [
          ChatMessage(id: 'a', role: 'assistant', content: 'Accepted turn.'),
          ChatMessage(id: 'u', role: 'user', content: 'Continue.'),
        ],
      ),
    );
    await LorebookRepo(db).put(
      const Lorebook(
        id: 'book',
        name: 'Book',
        entries: [
          LorebookEntry(id: 'miyako', content: _base),
          LorebookEntry(id: 'aqua', content: 'Aqua is focused.'),
        ],
      ),
    );
    await db.transaction(() async {
      expect(
        await SessionLorebookEvolutionRepo(db).applyPatchesInTransaction(
          sessionId: 's',
          lorebookId: 'book',
          entryId: 'miyako',
          baseContent: _base,
          expectedContentHash: CardCanonicalizer.scalarSha256(_base),
          patches: [
            LorebookAnchoredPatch(
              anchor: _base,
              anchorSha256: CardCanonicalizer.scalarSha256(_base),
              value: _current,
            ),
          ],
        ),
        isTrue,
      );
    });
    reader = EffectiveCanonReadRepository(
      db: db,
      characterRepo: characters,
      revisionRepo: revisions,
      baselineRepo: CharacterSessionBaselineRepo(db),
      factRepo: CharacterKnowledgeFactRepo(db),
      transitionRepo: AppliedCanonTransitionRepo(db),
      transitionFactRefRepo: CanonTransitionFactRefRepo(db),
    );
    jobs = ManualRewriteJobRepo(
      db: db,
      rawTrackerStateReader: LedgerRawTrackerStateReader(db),
    );
    final input = EffectiveCanonReadRepository.withInitialLineage(
      await reader.readInTransaction(sessionId: 's', characterId: 'c'),
    );
    final stable = const EffectiveCanonAssembler().assemble(
      input,
      stampVolatileState: false,
    );
    original = RewriteOperationSnapshotCodec.encode(
      LorebookRewriteOperationSnapshot(
        lorebookId: 'book',
        entryId: 'miyako',
        baseContent: _base,
        expectedContentHash: CardCanonicalizer.scalarSha256(_current),
        patches: [
          LorebookAnchoredPatch(
            anchor: _current,
            anchorSha256: CardCanonicalizer.scalarSha256(_current),
            value: '$_current\n\n$_liaison',
          ),
        ],
      ),
    );
    unrelated = RewriteOperationSnapshotCodec.encode(
      LorebookRewriteOperationSnapshot(
        lorebookId: 'book',
        entryId: 'aqua',
        baseContent: 'Aqua is focused.',
        expectedContentHash: CardCanonicalizer.scalarSha256('Aqua is focused.'),
        patches: [
          LorebookAnchoredPatch(
            anchor: 'Aqua is focused.',
            anchorSha256: CardCanonicalizer.scalarSha256('Aqua is focused.'),
            value: 'Aqua is focused and trusting.',
          ),
        ],
      ),
    );
    await db.transaction(
      () => jobs.insertPendingInTransaction(
        jobId: 'pending',
        chatSessionId: 's',
        characterId: 'c',
        requestJson: '{}',
        requestKey: 'pending',
        basisRevision: stable.effectiveRevision.number,
        basisRevisionHash: stable.effectiveRevision.hash,
        canonStamp: stable.identity,
        operations: [
          ManualRewriteOperationDraft(id: 'miyako-op', snapshotJson: original),
          ManualRewriteOperationDraft(id: 'aqua-op', snapshotJson: unrelated),
        ],
        now: 3,
      ),
    );
  });
  tearDown(() => db.close());

  Future<String> correct({
    ManualRewriteJobRepo? overrideJobs,
    String expected = _current,
    String replacement = '38 years old',
  }) =>
      LorebookDefinitionCorrectionRepo(
        db: db,
        canonReader: reader,
        jobs: overrideJobs ?? jobs,
        apply: ManualRewriteApplyRepo(db: db, canonReader: reader),
      ).correctAndRebasePending(
        sessionId: 's',
        lorebookId: 'book',
        entryId: 'miyako',
        expectedBaseContent: _base,
        expectedCurrentContent: expected,
        pendingJobId: 'pending',
        pendingOperationId: 'miyako-op',
        expectedPendingRevision: 1,
        anchor: _age,
        value: replacement,
      );

  test(
    'applies only age, preserves base/history and rebases pending liaison',
    () async {
      final chatBefore = jsonEncode(
        (await ChatRepo(db).getById('s'))!.toJson(),
      );
      final cardBefore = jsonEncode(
        (await CharacterRepo(db).getById('c'))!.toJson(),
      );
      final jobId = await correct();
      final overlay = (await SessionLorebookEvolutionRepo(
        db,
      ).getByTarget(sessionId: 's', lorebookId: 'book', entryId: 'miyako'))!;
      final next = _current.replaceFirst(_age, '38 years old');
      expect(overlay.content, next);
      expect(overlay.baseContent, _base);
      expect(overlay.content, isNot(contains(_liaison)));
      final book = (await LorebookRepo(db).getById('book'))!;
      expect(
        book.entries.first.content,
        _base.replaceFirst(_age, '38 years old'),
      );
      expect(book.entries.last.content, 'Aqua is focused.');
      final pending = (await jobs.getJobSnapshot('pending'))!;
      expect(pending.job.status, 'pending');
      final miyako = pending.operations.firstWhere(
        (view) => view.operation.id == 'miyako-op',
      );
      expect(miyako.operation.currentRevision, 2);
      expect(miyako.operation.decision, 'pending');
      expect(miyako.operation.validationStatus, 'valid');
      final decoded =
          RewriteOperationSnapshotCodec.tryDecode(
                jsonDecode(miyako.currentSnapshotJson),
              )
              as LorebookRewriteOperationSnapshot;
      expect(decoded.baseContent, _base);
      expect(decoded.patches.single.anchor, next);
      expect(decoded.patches.single.value, '$next\n\n$_liaison');
      expect(
        pending.operations
            .firstWhere((view) => view.operation.id == 'aqua-op')
            .currentSnapshotJson,
        unrelated,
      );
      final oldRevision = (await db.select(db.rewriteOperationRevisions).get())
          .firstWhere(
            (row) => row.rewriteOperationId == 'miyako-op' && row.revision == 1,
          );
      expect(oldRevision.snapshotJson, original);
      expect((await jobs.getJobSnapshot(jobId))!.job.status, 'applied');
      expect(
        await db.select(db.sessionLorebookRevisionRows).get(),
        hasLength(1),
      );
      expect(
        await db.select(db.sessionLorebookEmbeddingJobRows).get(),
        hasLength(1),
      );
      expect(await db.select(db.characterRevisionRows).get(), hasLength(1));
      expect(
        jsonEncode((await ChatRepo(db).getById('s'))!.toJson()),
        chatBefore,
      );
      expect(
        jsonEncode((await CharacterRepo(db).getById('c'))!.toJson()),
        cardBefore,
      );
    },
  );

  test(
    'failure after age apply rolls back age, checkpoint, book and proposal',
    () async {
      await expectLater(
        correct(overrideJobs: _RejectRebase(db)),
        throwsStateError,
      );
      final overlay = (await SessionLorebookEvolutionRepo(
        db,
      ).getByTarget(sessionId: 's', lorebookId: 'book', entryId: 'miyako'))!;
      expect(overlay.content, _current);
      expect(
        (await LorebookRepo(db).getById('book'))!.entries.first.content,
        _base,
      );
      expect(await db.select(db.rewriteJobs).get(), hasLength(1));
      expect(await db.select(db.sessionCanonCheckpointRows).get(), isEmpty);
      expect(await db.select(db.sessionLorebookRevisionRows).get(), isEmpty);
      expect(
        await db.select(db.sessionLorebookEmbeddingJobRows).get(),
        isEmpty,
      );
      expect(
        (await jobs.getJobSnapshot('pending'))!.operations
            .firstWhere((view) => view.operation.id == 'miyako-op')
            .currentSnapshotJson,
        original,
      );
    },
  );

  test('stale definition is rejected before writing', () async {
    await expectLater(correct(expected: 'Different'), throwsStateError);
    expect(await db.select(db.rewriteJobs).get(), hasLength(1));
  });

  test('canonical correction cannot add or drop macros', () async {
    await expectLater(
      correct(replacement: '38 years old {{user}}'),
      throwsFormatException,
    );
    expect(await db.select(db.rewriteJobs).get(), hasLength(1));
  });

  test('an already reviewed proposal is not silently rewritten', () async {
    await jobs.setDecision(
      operationId: 'miyako-op',
      expectedCurrentRevision: 1,
      expectedDecision: 'pending',
      decision: 'approved',
    );
    await expectLater(correct(), throwsStateError);
    expect(
      (await jobs.getJobSnapshot('pending'))!.operations
          .firstWhere((view) => view.operation.id == 'miyako-op')
          .operation
          .decision,
      'approved',
    );
  });
}
