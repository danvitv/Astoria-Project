import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/chat_source_mutation_provider.dart';
import 'package:glaze_flutter/features/card_rewrite/rewrite_review_provider.dart';
import 'package:glaze_flutter/features/card_rewrite/rewrite_review_screen.dart';
import 'package:glaze_flutter/features/chat/state/chat_native_owner_registry.dart';
import 'package:glaze_flutter/features/support_assistant/support_assistant_screen.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';

import 'support_app_rewrite_reject_fixture.dart';

void main() {
  domainLoopTest(
    'MODEL native Review -> Astoria metadata -> confirmed Reject -> HEADER Back -> fresh Undo',
    (tester, f) async {
      await seedNativeRewrite(tester, f);
      final navigator = await mountNativeRewrite(tester, f);
      try {
        final originalOwner = nativeRewriteOwner(f);
        final originalState = tester.state(
          find.byType(RewriteReviewScreen, skipOffstage: false),
        );
        expect(
          ProviderScope.containerOf(
            tester.element(
              find.byType(RewriteReviewScreen, skipOffstage: false),
            ),
            listen: false,
          ),
          same(f.screen.core.container),
        );
        expect(
          ProviderScope.containerOf(
            tester.element(find.byType(SupportAssistantScreen)),
            listen: false,
          ),
          same(f.screen.core.container),
        );
        final before = await nativeRewriteRow(tester, f),
            db = f.screen.core.native.db;
        final revisions = await configurationAction(
          tester,
          () => db.select(db.rewriteOperationRevisions).get(),
        );
        final evidence = await configurationAction(
          tester,
          () => db.select(db.rewriteEvidenceRows).get(),
        );
        f.script(
          f.screen.core.call('astoria_rewrite_review_receipts', {
            'operation': 'discover',
          }),
          next: (round) {
            if (round != 2) {
              return f.screen.core.answer('The exact rejection was saved.');
            }
            final record = (f.lastData()['records'] as List).single as Map;
            expect(record['job'], rewriteJobId);
            expect(record['operation'], rewriteOperationId);
            expect(record['version'], before.job.version);
            expect(record['from'], 'pending');
            return f.screen.core.call('astoria_rewrite_reject', {
              'jobId': record['job'],
              'operationId': record['operation'],
            }, id: 'reject_discovered_original');
          },
        );
        await startRewriteReject(tester, f);
        final preview = tester
            .widget<Text>(
              find.descendant(
                of: find.byKey(const Key('support_tool_confirmation_preview')),
                matching: find.byType(Text),
              ),
            )
            .data!;
        expect(preview, contains(rewriteJobId));
        expect(preview, contains(rewriteOperationId));
        expect(preview, contains('"from":"pending"'));
        expect(preview, contains('"to":"rejected"'));
        final exactConsequences = RegExp(
          r'Последствия: (\{[^\n]+\})\n',
        ).firstMatch(preview)!.group(1)!;
        expect(utf8.encode(exactConsequences).length, lessThanOrEqualTo(256));
        await f.apply(tester);
        final rejectedReply = await f.finish(tester),
            rejected = await nativeRewriteRow(tester, f);
        expect(
          rejected.job,
          before.job.copyWith(
            version: before.job.version + 1,
            updatedAt: rejected.job.updatedAt,
          ),
        );
        final opBefore = before.operations.single.operation,
            opAfter = rejected.operations.single.operation;
        expect(
          opAfter,
          opBefore.copyWith(
            decision: 'rejected',
            decisionRevision: opBefore.currentRevision,
            updatedAt: opAfter.updatedAt,
          ),
        );
        expect(rejectedReply.body, contains('изменение сохранено'));
        expect(originalState.mounted, true);
        expect(nativeRewriteOwner(f), same(originalOwner));
        final back = find
            .descendant(
              of: find.byType(SupportAssistantScreen),
              matching: find.byIcon(Icons.arrow_back_ios_new_rounded),
            )
            .hitTestable();
        await tester.tap(back);
        await tester.pumpAndSettle();
        expect(
          tester.state(find.byType(RewriteReviewScreen)),
          same(originalState),
        );
        expect(nativeRewriteOwner(f), same(originalOwner));
        // The mounted Review subscription resumes on HEADER Back. Join its
        // actual publication, not just fake-clock entrance animations, before
        // issuing a fresh Undo against the exact retained rejection rows.
        final published = Completer<void>();
        final originalWatcher = f.screen.core.container.listen(
          rewriteJobSnapshotProvider(rewriteJobId),
          (_, next) {
            final snapshot = next.asData?.value;
            if (!published.isCompleted &&
                snapshot != null &&
                snapshot.job == rejected.job &&
                snapshot.operations.any((view) => view.operation == opAfter)) {
              published.complete();
            }
          },
          fireImmediately: true,
        );
        try {
          await f.screen.join(tester, published.future);
          await tester.pump();
          expect(originalOwner.readLoaded()?.job, rejected.job);
          expect(originalOwner.selected()?.operation, opAfter);
          expect(nativeRewriteOwner(f), same(originalOwner));
        } finally {
          originalWatcher.close();
        }
        await tester.tap(find.byKey(const Key('rewrite-open-astoria')));
        await tester.pumpAndSettle();
        scriptRewriteUndo(f);
        await startRewriteReject(tester, f, undo: true);
        await f.apply(tester);
        final undoReply = await f.finish(tester),
            undone = await nativeRewriteRow(tester, f);
        expect(
          undone.job,
          before.job.copyWith(
            version: before.job.version + 2,
            updatedAt: undone.job.updatedAt,
          ),
        );
        expect(
          undone.operations.single.operation,
          opBefore.copyWith(
            updatedAt: undone.operations.single.operation.updatedAt,
          ),
        );
        expect(
          undone.operations.single.currentSnapshotJson,
          before.operations.single.currentSnapshotJson,
        );
        expect(
          await configurationAction(
            tester,
            () => db.select(db.rewriteOperationRevisions).get(),
          ),
          revisions,
        );
        expect(
          await configurationAction(
            tester,
            () => db.select(db.rewriteEvidenceRows).get(),
          ),
          evidence,
        );
        expect(
          await configurationAction(
            tester,
            () => db.select(db.appliedCanonTransitionRows).get(),
          ),
          isEmpty,
        );
        expect(
          await configurationAction(
            tester,
            () => db.select(db.embeddings).get(),
          ),
          isEmpty,
        );
        final journal = await configurationAction(
          tester,
          () => db.select(db.supportMutationJournal).get(),
        );
        expect(journal.single.status, 'undone');
        final saved = await configurationAction(
          tester,
          () => f.screen.core.native.repo.getMutationsForSession(
            f.screen.core.native.session,
          ),
        );
        expect(saved.single.domain, 'rewrite.reject');
        final private = SupportMutationEvidence.decode(
          saved.single.beforeJson,
        )!;
        expect(utf8.encode(private).length, lessThanOrEqualTo(8192));
        expect(jsonDecode(private)['decision'], 'pending');
        expect(
          jsonDecode(private)['decisionRevision'],
          opBefore.decisionRevision,
        );
        expect(journal.single.beforeCiphertext, isNot(contains(private)));
        expect(private, isNot(contains('SYNTHETIC_REWRITE_MODEL_TEXT')));
        rewriteNoEgress(f, '${rejectedReply.body}${undoReply.body}');
      } finally {
        await closeNativeRewrite(tester, navigator);
      }
    },
  );

  for (final mode in [
    'wrongJob',
    'wrongOperation',
    'noMountedOwner',
    'approved',
    'alreadyRejected',
    'longPreview',
  ]) {
    domainLoopTest(
      'MODEL rejection $mode is PRE-effect refusal without owner adoption',
      (tester, f) async {
        final id = mode == 'longPreview'
            ? List.filled(120, 'j').join()
            : rewriteJobId;
        final operation = mode == 'longPreview'
            ? List.filled(120, 'o').join()
            : rewriteOperationId;
        await seedNativeRewrite(tester, f, jobId: id, operationId: operation);
        final navigator = mode == 'noMountedOwner'
            ? null
            : await mountNativeRewrite(
                tester,
                f,
                jobId: id,
                operationId: operation,
              );
        try {
          if (mode == 'approved' || mode == 'alreadyRejected') {
            await configurationAction(
              tester,
              () => f.screen.core.container
                  .read(manualRewriteJobRepoProvider)
                  .setDecision(
                    operationId: operation,
                    expectedCurrentRevision: 1,
                    expectedDecision: 'pending',
                    decision: mode == 'approved' ? 'approved' : 'rejected',
                  ),
            );
            await tester.pump();
          }
          final before = await nativeRewriteRow(tester, f, id);
          f.script(
            f.screen.core.call('astoria_rewrite_reject', {
              'jobId': mode == 'wrongJob' ? 'not-the-loaded-job' : id,
              'operationId': mode == 'wrongOperation'
                  ? 'not-the-selected-operation'
                  : operation,
            }),
            next: (_) {
              expect(f.lastResult()['effect'], 'none');
              return f.screen.core.answer(
                'No eligible original pending decision.',
              );
            },
          );
          await startRewriteReject(tester, f, confirmation: false);
          final reply = await f.finish(tester);
          final after = await nativeRewriteRow(tester, f, id);
          expect(after.job, before.job);
          expect(
            after.operations.single.operation,
            before.operations.single.operation,
          );
          await noRewriteJournal(tester, f);
          rewriteNoEgress(f, reply.body);
        } finally {
          if (navigator != null) await closeNativeRewrite(tester, navigator);
        }
      },
    );
  }

  for (final mode in [
    'cancel',
    'staleConfirmedVersion',
    'jobABA',
    'decisionRevision',
    'revision',
    'appliedMarker',
    'jobStatus',
    'sourceWorkerABA',
    'selectionABA',
    'originalControllerReplacement',
    'aliasRepositoryReplacement',
  ]) {
    domainLoopTest(
      'MODEL rejection $mode after native confirmation never writes',
      (tester, f) async {
        await seedNativeRewrite(tester, f);
        final navigator = await mountNativeRewrite(tester, f);
        try {
          f.script(
            f.screen.core.call(
              'astoria_rewrite_reject',
              rewriteRejectArguments(),
            ),
          );
          await startRewriteReject(tester, f);
          final accept = find.byKey(
            const Key('support_tool_confirmation_accept'),
          );
          final expired = tester.widget<GlazeActionButton>(accept).onTap!;
          final route = ModalRoute.of<void>(tester.element(accept))!;
          final db = f.screen.core.native.db, c = f.screen.core.container;
          if (mode == 'jobABA') {
            final before = await nativeRewriteRow(tester, f);
            await configurationAction(
              tester,
              () => c
                  .read(manualRewriteJobRepoProvider)
                  .withPendingReviewSuspended(
                    jobId: rewriteJobId,
                    expectedVersion: before.job.version,
                    correction: () async => null,
                  ),
            );
          } else if (mode == 'sourceWorkerABA') {
            c
                .read(chatSourceMutationRegistryProvider)
                .beginMutation(sessionId: DomainLoopFixture.session)();
          } else if (mode == 'selectionABA') {
            final controller = c.read(
              rewriteReviewUiProvider(rewriteJobId).notifier,
            );
            controller.selectOperation(null);
            controller.selectOperation(rewriteOperationId);
          } else if (mode == 'originalControllerReplacement') {
            c.invalidate(rewriteReviewUiProvider(rewriteJobId));
          } else if (mode == 'aliasRepositoryReplacement') {
            c.invalidate(manualRewriteJobRepoProvider);
          } else if (mode == 'revision') {
            final before = await nativeRewriteRow(tester, f);
            await configurationAction(
              tester,
              () => c
                  .read(manualRewriteJobRepoProvider)
                  .editAndRevalidate(
                    operationId: rewriteOperationId,
                    expectedCurrentRevision: 1,
                    newSnapshotJson:
                        before.operations.single.currentSnapshotJson,
                  ),
            );
          } else if (mode != 'cancel') {
            await configurationAction(tester, () async {
              if (mode == 'staleConfirmedVersion' || mode == 'jobStatus') {
                await (db.update(
                  db.rewriteJobs,
                )..where((t) => t.id.equals(rewriteJobId))).write(
                  RewriteJobsCompanion(
                    version: mode == 'staleConfirmedVersion'
                        ? const Value(2)
                        : const Value.absent(),
                    status: mode == 'jobStatus'
                        ? const Value('failed')
                        : const Value.absent(),
                  ),
                );
              } else {
                await (db.update(
                  db.rewriteOperations,
                )..where((t) => t.id.equals(rewriteOperationId))).write(
                  RewriteOperationsCompanion(
                    decisionRevision: mode == 'decisionRevision'
                        ? const Value(1)
                        : const Value.absent(),
                    appliedCharacterRevision: mode == 'appliedMarker'
                        ? const Value(1)
                        : const Value.absent(),
                  ),
                );
              }
            });
          }
          final beforeAccept = await nativeRewriteRow(tester, f);
          if (mode == 'cancel') {
            await f.cancel(tester);
          } else {
            await configurationAction(tester, expired);
            await tester.pump();
            if (route.isCurrent) {
              await f.cancel(tester);
            } else {
              await tester.pump(
                route.reverseTransitionDuration +
                    const Duration(microseconds: 1),
              );
            }
          }
          final reply = await f.finish(tester),
              after = await nativeRewriteRow(tester, f);
          expect(after.job, beforeAccept.job);
          expect(
            after.operations.single.operation,
            beforeAccept.operations.single.operation,
          );
          await noRewriteJournal(tester, f);
          rewriteNoEgress(f, reply.body);
        } finally {
          await closeNativeRewrite(tester, navigator);
        }
      },
    );
  }

  for (final mode in [
    'repeatedDecision',
    'decisionABA',
    'freshPreviewStale',
    'cancel',
    'guessedReceipt',
  ]) {
    domainLoopTest(
      'MODEL retained rejection Undo $mode cannot renew old custody',
      (tester, f) async {
        await seedNativeRewrite(tester, f);
        final navigator = await mountNativeRewrite(tester, f);
        try {
          f.script(
            f.screen.core.call(
              'astoria_rewrite_reject',
              rewriteRejectArguments(),
            ),
          );
          await startRewriteReject(tester, f);
          await f.apply(tester);
          await f.finish(tester);
          final c = f.screen.core.container,
              repo = c.read(manualRewriteJobRepoProvider);
          await reopenNativeRewriteAfterRejection(tester, f);
          String? handle;
          scriptRewriteUndo(f, handle: (id) => handle = id);
          await startRewriteReject(tester, f, undo: true);
          final accept = find.byKey(
            const Key('support_tool_confirmation_accept'),
          );
          final expired = tester.widget<GlazeActionButton>(accept).onTap!;
          final route = ModalRoute.of<void>(tester.element(accept))!;
          if (mode == 'repeatedDecision' || mode == 'decisionABA') {
            await configurationAction(tester, () async {
              if (mode == 'decisionABA') {
                await repo.setDecision(
                  operationId: rewriteOperationId,
                  expectedCurrentRevision: 1,
                  expectedDecision: 'rejected',
                  decision: 'approved',
                );
              }
              await repo.setDecision(
                operationId: rewriteOperationId,
                expectedCurrentRevision: 1,
                expectedDecision: mode == 'decisionABA'
                    ? 'approved'
                    : 'rejected',
                decision: 'rejected',
              );
            });
          } else if (mode == 'freshPreviewStale') {
            c
                .read(chatSourceMutationRegistryProvider)
                .beginMutation(sessionId: DomainLoopFixture.session)();
          }
          final before = await nativeRewriteRow(tester, f);
          if (mode == 'cancel' || mode == 'guessedReceipt') {
            await f.cancel(tester);
          } else {
            await configurationAction(tester, expired);
            await tester.pump();
            if (route.isCurrent) {
              await f.cancel(tester);
            } else {
              await tester.pump(
                route.reverseTransitionDuration +
                    const Duration(microseconds: 1),
              );
            }
          }
          final reply = await f.finish(tester),
              after = await nativeRewriteRow(tester, f);
          expect(after.job, before.job);
          expect(
            after.operations.single.operation,
            before.operations.single.operation,
          );
          final journal = await configurationAction(
            tester,
            () => f.screen.core.native.db
                .select(f.screen.core.native.db.supportMutationJournal)
                .get(),
          );
          expect(journal.single.status, 'applied');
          if (mode == 'cancel') {
            // Cancelling a fresh confirmation neither consumes a retained slot
            // nor spends the original genuine receipt or queue/DB ticket.
            scriptRewriteUndo(f, handle: (id) => expect(id, handle));
            await startRewriteReject(tester, f, undo: true);
            await f.apply(tester);
            final freshUndo = await f.finish(tester),
                restored = await nativeRewriteRow(tester, f);
            expect(restored.operations.single.operation.decision, 'pending');
            expect(restored.job.version, before.job.version + 1);
            rewriteNoEgress(f, freshUndo.body);
          }
          if (mode == 'guessedReceipt') {
            f.script(
              f.screen.core.call('astoria_rewrite_reject_undo', {
                'receipt': 'repair-${List.filled(32, 'a').join()}',
              }),
              next: (_) {
                expect(f.lastResult()['code'], 'unavailable');
                return f.screen.core.answer(
                  'Guessed receipt cannot restore anything.',
                );
              },
            );
            await startRewriteReject(
              tester,
              f,
              undo: true,
              confirmation: false,
            );
            await f.finish(tester);
            expect(handle, isNotNull);
          }
          rewriteNoEgress(f, reply.body);
        } finally {
          await closeNativeRewrite(tester, navigator);
        }
      },
    );
  }

  for (final undo in [false, true]) {
    for (final matching in [false, true]) {
      domainLoopTest(
        'MODEL ${undo ? 'Undo' : 'Reject'} ${matching ? 'matching' : 'unrelated'} redactor alias at SQL retires original identity',
        (tester, f) async {
          await seedNativeRewrite(tester, f);
          final navigator = await mountNativeRewrite(tester, f),
              sql = f.screen.core.native.sql;
          try {
            if (undo) {
              f.script(
                f.screen.core.call(
                  'astoria_rewrite_reject',
                  rewriteRejectArguments(),
                ),
              );
              await startRewriteReject(tester, f);
              await f.apply(tester);
              await f.finish(tester);
              await reopenNativeRewriteAfterRejection(tester, f);
              scriptRewriteUndo(f);
            } else {
              f.script(
                f.screen.core.call(
                  'astoria_rewrite_reject',
                  rewriteRejectArguments(),
                ),
              );
            }
            await startRewriteReject(tester, f, undo: undo);
            final before = await nativeRewriteRow(tester, f);
            var fired = false;
            sql.afterWrite = (statement) async {
              if (!fired && isRewriteOperationUpdate(statement)) {
                fired = true;
                f.screen.core.native.redaction.registerSecret(
                  matching
                      ? rewriteOperationId
                      : 'SYNTHETIC_UNRELATED_REWRITE_ALIAS',
                );
              }
            };
            await f.apply(tester);
            final reply = await f.finish(tester);
            sql.afterWrite = null;
            expect(fired, true);
            final after = await nativeRewriteRow(tester, f),
                db = f.screen.core.native.db;
            expect(after.job, before.job);
            expect(
              after.operations.single.operation,
              before.operations.single.operation,
            );
            final journal = await configurationAction(
              tester,
              () => db.select(db.supportMutationJournal).get(),
            );
            expect(journal, undo ? hasLength(1) : isEmpty);
            if (undo) expect(journal.single.status, 'applied');
            rewriteNoEgress(f, reply.body);
          } finally {
            sql.afterWrite = null;
            await closeNativeRewrite(tester, navigator);
          }
        },
      );
    }
  }

  for (final undo in [false, true]) {
    for (final fault in [
      'preCommitRetire',
      'postPhysicalUnknown',
      'deliveredRetired',
      'lateOrdinaryWriter',
    ]) {
      domainLoopTest(
        'MODEL ${undo ? 'Undo' : 'Reject'} $fault preserves native fact/ticket distinction',
        (tester, f) async {
          await seedNativeRewrite(tester, f);
          final navigator = await mountNativeRewrite(tester, f),
              sql = f.screen.core.native.sql;
          Future<Object?>? ordinary;
          try {
            if (undo) {
              f.script(
                f.screen.core.call(
                  'astoria_rewrite_reject',
                  rewriteRejectArguments(),
                ),
              );
              await startRewriteReject(tester, f);
              await f.apply(tester);
              await f.finish(tester);
              await reopenNativeRewriteAfterRejection(tester, f);
              scriptRewriteUndo(f);
            } else {
              f.script(
                f.screen.core.call(
                  'astoria_rewrite_reject',
                  rewriteRejectArguments(),
                ),
              );
            }
            await startRewriteReject(tester, f, undo: undo);
            final before = await nativeRewriteRow(tester, f);
            var written = false, fired = false;
            sql.afterWrite = (statement) async {
              if (isRewriteOperationUpdate(statement)) {
                written = true;
              }
            };
            await configurationAction(tester, () async {
              final originalZone = Zone.current;
              Future<void> fire() async {
                if (!written || fired) return;
                fired = true;
                if (fault == 'postPhysicalUnknown') {
                  throw StateError(DomainLoopFixture.private);
                }
                if (fault == 'lateOrdinaryWriter') {
                  sql.afterOuterSend = null;
                  ordinary = originalZone.run(
                    () => f.screen.core.container
                        .read(manualRewriteJobRepoProvider)
                        .setDecision(
                          operationId: rewriteOperationId,
                          expectedCurrentRevision: 1,
                          expectedDecision: undo ? 'pending' : 'rejected',
                          decision: 'rejected',
                        ),
                  );
                } else {
                  f.screen.core.container
                      .read(chatNativeOwnerRegistryProvider)
                      .existing(DomainLoopFixture.session)!
                      .queue
                      .beginPublication();
                }
              }

              if (fault == 'preCommitRetire') {
                sql.beforeOuterSend = fire;
              } else {
                sql.afterOuterSend = fire;
              }
            });
            await f.apply(tester);
            final reply = await f.finish(tester);
            if (ordinary != null) {
              await configurationAction(tester, () => ordinary!);
            }
            sql.afterWrite = null;
            sql.beforeOuterSend = null;
            sql.afterOuterSend = null;
            expect(fired, true);
            final after = await nativeRewriteRow(tester, f),
                db = f.screen.core.native.db;
            final journal = await configurationAction(
              tester,
              () => db.select(db.supportMutationJournal).get(),
            );
            if (fault == 'preCommitRetire') {
              expect(after.job, before.job);
              expect(
                after.operations.single.operation,
                before.operations.single.operation,
              );
              expect(journal, undo ? hasLength(1) : isEmpty);
              if (undo) expect(journal.single.status, 'applied');
            } else {
              expect(journal.single.status, undo ? 'undone' : 'applied');
              expect(
                after.job.version,
                before.job.version + (fault == 'lateOrdinaryWriter' ? 2 : 1),
              );
              expect(
                after.operations.single.operation.decision,
                fault == 'lateOrdinaryWriter'
                    ? 'rejected'
                    : undo
                    ? 'pending'
                    : 'rejected',
              );
            }
            if (fault == 'deliveredRetired' || fault == 'lateOrdinaryWriter') {
              expect(reply.body, contains('изменение сохранено'));
              expect(
                reply.body,
                contains('обновление нативных представлений ожидается'),
              );
            } else {
              expect(reply.body, isNot(contains('изменение сохранено')));
            }
            f.script(
              f.screen.core.call('astoria_rewrite_review_receipts', {
                'operation': 'receipts',
              }),
              next: (_) {
                expect(f.lastData()['records'], isEmpty);
                return f.screen.core.answer(
                  'No retired native Undo ticket is adopted.',
                );
              },
            );
            await startRewriteReject(
              tester,
              f,
              confirmation: false,
              undo: true,
            );
            final retired = await f.finish(tester);
            rewriteNoEgress(f, '${reply.body}${retired.body}');
          } finally {
            sql.afterWrite = null;
            sql.beforeOuterSend = null;
            sql.afterOuterSend = null;
            if (ordinary != null) {
              await configurationAction(tester, () => ordinary!);
            }
            await closeNativeRewrite(tester, navigator);
          }
        },
      );
    }
  }
}
