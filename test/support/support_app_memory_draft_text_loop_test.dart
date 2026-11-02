import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/memory_book_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/chat_source_mutation_provider.dart';
import 'package:glaze_flutter/features/chat/state/chat_native_owner_registry.dart';
import 'package:glaze_flutter/features/memory/state/memory_native_entry_owner.dart';
import 'package:glaze_flutter/features/memory/state/memory_active_drafts_provider.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';

import 'support_app_memory_draft_text_fixture.dart';

void main() {
  domainLoopTest(
    'MODEL draft ID discovery, exact raw content CAS and retained fresh Undo',
    (tester, f) async {
      await seedDraftText(tester, f);
      final tab = await mountDraftMemory(tester, f);
      try {
        draftNonEgressControls(f);
        final owner = draftMemoryOwner(f),
            before = await draftTextRow(tester, f);
        f.script(
          f.screen.core.call('astoria_session_integrity', {
            'operation': 'discover',
          }),
          next: (round) {
            if (round == 2) {
              final records = f.lastData()['records'] as List;
              final target = records.cast<Map<Object?, Object?>>().singleWhere(
                (r) => r['sessionId'] == DomainLoopFixture.session,
              );
              return f.screen.core.call('astoria_memory_inspect', {
                'sessionId': target['sessionId'],
                'view': 'drafts',
              }, id: 'discover_existing_draft');
            }
            final items = f.lastData()['items'] as List;
            final draft = items.cast<Map<Object?, Object?>>().singleWhere(
              (d) => d['draftId'] == draftTextId,
            );
            expect(draft['status'], 'pending_approval');
            expect(draft['vectorSearch'], false);
            return f.screen.core.call('astoria_memory_draft_text_edit', {
              'sessionId': DomainLoopFixture.session,
              'draftId': draft['draftId'],
              'content': draftTextAfter,
            }, id: 'edit_discovered_exact_draft');
          },
        );
        await startDraftText(tester, f);
        final preview = tester
            .widget<Text>(
              find.descendant(
                of: find.byKey(
                  const ValueKey('support_tool_confirmation_preview'),
                ),
                matching: find.byType(Text),
              ),
            )
            .data!;
        expect(preview, contains(jsonEncode(jsonEncode(draftTextBefore))));
        expect(preview, contains(jsonEncode(jsonEncode(draftTextAfter))));
        await f.apply(tester);
        final reply = await f.finish(tester);
        expect(reply.body, contains('изменение сохранено'));
        expect(draftMemoryOwner(f), same(owner));
        expect(owner.cachedDraft(draftTextId)!.content, draftTextAfter);
        preservedDraftText(
          before,
          await draftTextRow(tester, f),
          draftTextAfter,
        );
        final evidence = await configurationAction(
          tester,
          () => f.screen.core.native.repo.getMutationsForSession(
            f.screen.core.native.session,
          ),
        );
        expect(evidence.single.domain, 'memory.draft.text');
        expect(evidence.single.status, 'applied');
        expect(
          RegExp(
            r'^memory-draft-[a-f0-9]{64}$',
          ).hasMatch(evidence.single.targetId),
          true,
        );
        expect(
          (jsonDecode(
                SupportMutationEvidence.decode(evidence.single.beforeJson)!,
              )
              as Map)['content'],
          draftTextBefore,
        );
        expect(
          (jsonDecode(
                SupportMutationEvidence.decode(evidence.single.afterJson)!,
              )
              as Map)['content'],
          draftTextAfter,
        );
        f.script(
          f.screen.core.call('astoria_memory_draft_text_receipts', {}),
          next: (_) {
            final records = f.lastData()['records'] as List;
            expect(records, hasLength(1));
            return f.screen.core.call('astoria_memory_draft_text_undo', {
              'receipt': (records.single as Map)['receipt'],
            }, id: 'fresh_original_draft_undo');
          },
        );
        await startDraftText(tester, f, undo: true);
        await f.apply(tester);
        final undone = await f.finish(tester);
        expect(undone.body, contains('изменение сохранено'));
        expect(await draftTextRow(tester, f), before);
        expect(owner.cachedDraft(draftTextId)!.content, draftTextBefore);
        final db = f.screen.core.native.db;
        final journal = await configurationAction(
          tester,
          () => db.select(db.supportMutationJournal).get(),
        );
        expect(journal.single.status, 'undone');
        expect(
          journal.single.beforeCiphertext,
          isNot(contains(draftTextBefore)),
        );
        expect(journal.single.afterCiphertext, isNot(contains(draftTextAfter)));
        expect(
          await configurationAction(
            tester,
            () => db.select(db.embeddings).get(),
          ),
          isEmpty,
        );
        f.noEgress('${reply.body}${undone.body}');
        draftNonEgressControls(f);
      } finally {
        await unmountDraftMemory(tester, tab);
      }
    },
  );

  for (final mode in ['noOwner', 'pendingGeneration', 'vectorEnabled']) {
    domainLoopTest(
      'MODEL draft text $mode is unavailable without new ownership or network',
      (tester, f) async {
        await seedDraftText(
          tester,
          f,
          status: mode == 'pendingGeneration'
              ? 'pending_generation'
              : 'pending_approval',
          vector: mode == 'vectorEnabled',
        );
        final tab = mode == 'noOwner'
            ? null
            : await mountDraftMemory(tester, f);
        try {
          final before = await draftTextRow(tester, f);
          f.script(
            f.screen.core.call(
              'astoria_memory_draft_text_edit',
              draftTextArguments(),
            ),
            next: (_) {
              expect(f.lastResult()['code'], 'unavailable');
              return f.screen.core.answer(
                'No eligible original pending-approval draft.',
              );
            },
          );
          await startDraftText(tester, f, confirmation: false);
          final reply = await f.finish(tester);
          expect(await draftTextRow(tester, f), before);
          await noDraftJournal(tester, f);
          f.noEgress(reply.body);
        } finally {
          if (tab != null) await unmountDraftMemory(tester, tab);
        }
      },
    );
  }

  for (final mode in ['decline', 'originalWriterABA', 'activeDraftLeaseABA']) {
    domainLoopTest(
      'MODEL draft $mode after preview cannot persist or retain Undo',
      (tester, f) async {
        await seedDraftText(tester, f);
        final tab = await mountDraftMemory(tester, f);
        try {
          f.script(
            f.screen.core.call(
              'astoria_memory_draft_text_edit',
              draftTextArguments(),
            ),
          );
          await startDraftText(tester, f);
          final accept = find.byKey(
            const ValueKey('support_tool_confirmation_accept'),
          );
          final route = ModalRoute.of<void>(tester.element(accept))!;
          final expiredApply = tester.widget<GlazeActionButton>(accept).onTap!;
          if (mode == 'originalWriterABA') {
            await configurationAction(tester, () async {
              final repo = f.screen.core.container.read(memoryBookRepoProvider);
              // Ordinary queued draft job writes retire native setup tickets even
              // when the typed draft is equal. This is the original repo seam.
              await repo.mutateDraft(
                sessionId: DomainLoopFixture.session,
                draftId: draftTextId,
                mutate: (d) => d,
              );
            });
          } else if (mode == 'activeDraftLeaseABA') {
            await configurationAction(tester, () async {
              final lease = f.screen.core.container
                  .read(memoryActiveDraftsProvider.notifier)
                  .acquire(DomainLoopFixture.session);
              lease.release();
            });
          }
          final before = await draftTextRow(tester, f);
          if (mode != 'decline') {
            await configurationAction(tester, expiredApply);
            await tester.pump();
            if (route.isCurrent) await f.cancel(tester);
          } else {
            await f.cancel(tester);
          }
          final reply = await f.finish(tester);
          expect(reply.body, isNot(contains('изменение сохранено')));
          expect(await draftTextRow(tester, f), before);
          await noDraftJournal(tester, f);
          f.noEgress(reply.body);
        } finally {
          await unmountDraftMemory(tester, tab);
        }
      },
    );
  }

  for (final matching in [false, true]) {
    domainLoopTest(
      'MODEL current-policy ${matching ? 'matching' : 'unrelated'} alias at draft SQL',
      (tester, f) async {
        await seedDraftText(tester, f);
        final tab = await mountDraftMemory(tester, f);
        final sql = f.screen.core.native.sql;
        try {
          final before = await draftTextRow(tester, f);
          f.script(
            f.screen.core.call(
              'astoria_memory_draft_text_edit',
              draftTextArguments(),
            ),
          );
          await startDraftText(tester, f);
          var changed = false;
          sql.afterWrite = (statement) async {
            if (!changed &&
                statement.trimLeft().toLowerCase().startsWith(
                  'update memory_book_rows',
                )) {
              changed = true;
              // Every new alias replaces the original Send redactor snapshot.
              // Its issuer retires even when this exact text remains safe; do
              // not renew native authority under the replacement policy.
              f.screen.core.native.redaction.registerSecret(
                matching ? draftTextAfter : 'SYNTHETIC_UNRELATED_DRAFT_ALIAS',
              );
            }
          };
          await f.apply(tester);
          final reply = await f.finish(tester);
          sql.afterWrite = null;
          expect(changed, true);
          expect(await draftTextRow(tester, f), before);
          await noDraftJournal(tester, f);
          expect(reply.body, isNot(contains('изменение сохранено')));
          f.noEgress(reply.body);
        } finally {
          sql.afterWrite = null;
          await unmountDraftMemory(tester, tab);
        }
      },
    );
  }

  domainLoopTest(
    'MODEL retained draft receipt retires on ordinary draft job write; guessed Undo grants nothing',
    (tester, f) async {
      await seedDraftText(tester, f);
      final tab = await mountDraftMemory(tester, f);
      try {
        f.script(
          f.screen.core.call(
            'astoria_memory_draft_text_edit',
            draftTextArguments(),
          ),
        );
        await startDraftText(tester, f);
        await f.apply(tester);
        final edited = await f.finish(tester);
        expect(edited.body, contains('изменение сохранено'));
        await configurationAction(
          tester,
          () => f.screen.core.container
              .read(memoryBookRepoProvider)
              .mutateDraft(
                sessionId: DomainLoopFixture.session,
                draftId: draftTextId,
                mutate: (draft) => draft,
              ),
        );
        final before = await draftTextRow(tester, f);
        f.script(
          f.screen.core.call('astoria_memory_draft_text_receipts', {}),
          next: (round) {
            if (round == 2) {
              expect(f.lastData()['records'], isEmpty);
              return f.screen.core.call('astoria_memory_draft_text_undo', {
                'receipt': 'repair-${List.filled(32, 'a').join()}',
              }, id: 'guessed_draft_undo');
            }
            expect(f.lastResult()['code'], 'unavailable');
            return f.screen.core.answer('No current original draft receipt.');
          },
        );
        await startDraftText(tester, f, confirmation: false, undo: true);
        final reply = await f.finish(tester);
        expect(await draftTextRow(tester, f), before);
        final journal = await configurationAction(
          tester,
          () => f.screen.core.native.db
              .select(f.screen.core.native.db.supportMutationJournal)
              .get(),
        );
        expect(journal.single.status, 'applied');
        f.noEgress('${edited.body}${reply.body}');
      } finally {
        await unmountDraftMemory(tester, tab);
      }
    },
  );

  for (final side in ['before', 'after']) {
    domainLoopTest(
      'NATIVE draft $side UTF-8 evidence overflow is defined no-effect, not uncertain IO',
      (tester, f) async {
        final oversized = List.filled(4096, 'Ж').join();
        await seedDraftText(
          tester,
          f,
          content: side == 'before' ? oversized : draftTextBefore,
        );
        final tab = await mountDraftMemory(tester, f);
        try {
          final owner = draftMemoryOwner(f),
              before = await draftTextRow(tester, f);
          final c = f.screen.core.container;
          final chatOwners = c.read(chatNativeOwnerRegistryProvider);
          final chat = chatOwners.existing(DomainLoopFixture.session)!;
          final mutations = c.read(chatSourceMutationRegistryProvider);
          final checkpoint = mutations.sessionCheckpoint(
            DomainLoopFixture.session,
          );
          final nativeLifetime = owner.captureNativeGuard();
          bool current() =>
              nativeLifetime() &&
              chatOwners.retains(chat, DomainLoopFixture.session) &&
              !mutations.isSessionPending(DomainLoopFixture.session) &&
              identical(
                mutations.sessionCheckpoint(DomainLoopFixture.session),
                checkpoint,
              );
          final revision = owner.queue.revision,
              cached = owner.cachedDraft(draftTextId);
          // The unchanged public 256-character preview cap is not enlarged.
          // Exercise the actual original native owner for this inner limit.
          final observed = await configurationAction(
            tester,
            () => owner.observeDraft(draftTextId, current),
          );
          expect(observed, isNotNull);
          final receipt = await configurationAction(
            tester,
            () => owner.reviseDraftText(
              observed: observed!,
              queueRevision: revision,
              content: side == 'after' ? oversized : draftTextAfter,
              support: f.screen.core.native.repo,
              parentSession: f.screen.core.native.session,
              operationId: 'synthetic-draft-evidence-overflow',
              sourceCurrent: current,
            ),
          );
          expect(receipt, isNull);
          expect(owner.cachedDraft(draftTextId), same(cached));
          expect(await draftTextRow(tester, f), before);
          expect(observed!.current, false);
          await noDraftJournal(tester, f);
          f.noEgress();
        } finally {
          await unmountDraftMemory(tester, tab);
        }
      },
    );
  }

  for (final undo in [false, true]) {
    domainLoopTest(
      'MODEL native actual outer COMMIT then ordinary repo admission before ${undo ? 'Undo' : 'Apply'} publication',
      (tester, f) async {
        await seedDraftText(tester, f);
        final tab = await mountDraftMemory(tester, f);
        final sql = f.screen.core.native.sql;
        Future<bool>? ordinaryWriter;
        try {
          final owner = draftMemoryOwner(f);
          String? oldHandle;
          var appliedBody = '';
          if (undo) {
            f.script(
              f.screen.core.call(
                'astoria_memory_draft_text_edit',
                draftTextArguments(),
              ),
            );
            await startDraftText(tester, f);
            await f.apply(tester);
            appliedBody = (await f.finish(tester)).body;
            expect(appliedBody, contains('изменение сохранено'));
          }
          final cacheBefore = owner.cachedDraft(draftTextId);
          final queueBefore = owner.queue.revision;
          final c = f.screen.core.container;
          final mutations = c.read(chatSourceMutationRegistryProvider);
          Object? sourceAtCommit;
          final name = undo
              ? 'astoria_memory_draft_text_undo'
              : 'astoria_memory_draft_text_edit';
          if (undo) {
            f.script(
              f.screen.core.call('astoria_memory_draft_text_receipts', {}),
              next: (round) {
                if (round == 2) {
                  final records = f.lastData()['records'] as List;
                  expect(records, hasLength(1));
                  oldHandle = (records.single as Map)['receipt'] as String;
                  return f.screen.core.call(name, {
                    'receipt': oldHandle,
                  }, id: 'genuine_late_draft_undo');
                }
                final result = f.lastResult();
                expect(result['effect'], 'persisted');
                expect((result['data'] as Map)['refreshPending'], true);
                return f.screen.core.answer(
                  'Saved; original cache awaits refresh.',
                );
              },
            );
          } else {
            f.script(
              f.screen.core.call(name, draftTextArguments()),
              next: (_) {
                final result = f.lastResult();
                expect(result['effect'], 'persisted');
                final data = result['data'] as Map;
                expect(data['refreshPending'], true);
                expect(data.containsKey('receipt'), false);
                return f.screen.core.answer(
                  'Saved; original cache awaits refresh.',
                );
              },
            );
          }
          await startDraftText(tester, f, undo: undo);
          var written = false, fired = false;
          sql.afterWrite = (statement) async {
            if (statement.trimLeft().toLowerCase().startsWith(
              'update memory_book_rows',
            )) {
              written = true;
            }
          };
          await configurationAction(tester, () async {
            // Capture the original finite fixture zone OUTSIDE the transaction.
            // afterOuterSend runs only after the real SQLite outer COMMIT. Admit
            // an ordinary repo writer synchronously before returning its result,
            // but do not join a new transaction while the old one is unwinding.
            final originalZone = Zone.current;
            sql.afterOuterSend = () async {
              if (!written || fired) return;
              fired = true;
              sql.afterOuterSend = null;
              // The native effect itself advances the source checkpoint before
              // SQL. Observe its committed checkpoint BEFORE the late ordinary
              // admission, rather than comparing with the pre-Send checkpoint.
              sourceAtCommit = mutations.sessionCheckpoint(
                DomainLoopFixture.session,
              );
              ordinaryWriter = originalZone.run(
                () => owner.repo.mutateDraft(
                  sessionId: DomainLoopFixture.session,
                  draftId: draftTextId,
                  mutate: (draft) => draft,
                ),
              );
            };
          });
          await f.apply(tester);
          final reply = await f.finish(tester);
          await configurationAction(tester, () => ordinaryWriter!);
          sql.afterWrite = null;
          expect(fired, true);
          expect(owner.cachedDraft(draftTextId), same(cacheBefore));
          expect(owner.queue.revision, queueBefore + 2);
          expect(sourceAtCommit, isNotNull);
          expect(
            mutations.sessionCheckpoint(DomainLoopFixture.session),
            same(sourceAtCommit),
          );
          final row = await draftTextRow(tester, f);
          final target = (jsonDecode(row.pendingDraftsJson) as List)
              .cast<Map<Object?, Object?>>()
              .singleWhere((draft) => draft['id'] == draftTextId);
          expect(target['content'], undo ? draftTextBefore : draftTextAfter);
          expect(target['status'], 'pending_approval');
          final db = f.screen.core.native.db;
          final journal = await configurationAction(
            tester,
            () => db.select(db.supportMutationJournal).get(),
          );
          expect(journal.single.status, undo ? 'undone' : 'applied');
          expect(reply.body, contains('изменение сохранено'));
          expect(
            reply.body,
            contains('обновление нативных представлений ожидается'),
          );
          expect(reply.body, isNot(contains('storageUncertain')));
          f.script(
            f.screen.core.call('astoria_memory_draft_text_receipts', {}),
            next: (round) {
              if (round == 2) {
                expect(f.lastData()['records'], isEmpty);
                return f.screen.core.call(
                  'astoria_memory_draft_text_undo',
                  {
                    'receipt':
                        oldHandle ?? 'repair-${List.filled(32, 'a').join()}',
                  },
                  id: 'retry_retired_original_draft_undo',
                );
              }
              expect(f.lastResult()['code'], 'unavailable');
              return f.screen.core.answer('No old Undo authority.');
            },
          );
          await startDraftText(tester, f, confirmation: false, undo: true);
          final retained = await f.finish(tester);
          expect(await draftTextRow(tester, f), row);
          expect(
            await configurationAction(
              tester,
              () => db.select(db.supportMutationJournal).get(),
            ),
            journal,
          );
          expect(owner.cachedDraft(draftTextId), same(cacheBefore));
          f.noEgress('$appliedBody${reply.body}${retained.body}');
        } finally {
          sql.afterWrite = null;
          sql.afterOuterSend = null;
          if (ordinaryWriter != null) {
            await configurationAction(tester, () => ordinaryWriter!);
          }
          await unmountDraftMemory(tester, tab);
        }
      },
    );
  }

  domainLoopTest(
    'MODEL escaped content/key in a non-first target changes only its raw string token',
    (tester, f) async {
      const beforeContent = ' Quote "x", slash \\, newline\nЖ. ';
      const afterContent = '\tEdited "y" \\ path.\n';
      await seedDraftText(
        tester,
        f,
        content: beforeContent,
        draftRaw: (raw) {
          final split = raw.indexOf('\n  },\n  {') + '\n  }'.length;
          final first = raw.substring(raw.indexOf('{'), split);
          final sibling = raw.substring(
            split + ','.length,
            raw.lastIndexOf(']'),
          );
          return '[ $sibling,\n${first.replaceFirst('"content":', r'"\u0063ontent":')}\n]';
        },
      );
      final tab = await mountDraftMemory(tester, f);
      try {
        final before = await draftTextRow(tester, f);
        final owner = draftMemoryOwner(f);
        f.script(
          f.screen.core.call(
            'astoria_memory_draft_text_edit',
            draftTextArguments(afterContent),
          ),
        );
        await startDraftText(tester, f);
        await f.apply(tester);
        final applied = await f.finish(tester);
        final after = await draftTextRow(tester, f);
        expect(
          after,
          before.copyWith(
            pendingDraftsJson: before.pendingDraftsJson.replaceFirst(
              jsonEncode(beforeContent),
              jsonEncode(afterContent),
            ),
          ),
        );
        expect(owner.cachedDraft(draftTextId)!.content, afterContent);
        f.script(
          f.screen.core.call('astoria_memory_draft_text_receipts', {}),
          next: (_) {
            final records = f.lastData()['records'] as List;
            return f.screen.core.call('astoria_memory_draft_text_undo', {
              'receipt': (records.single as Map)['receipt'],
            }, id: 'escaped_nonfirst_draft_undo');
          },
        );
        await startDraftText(tester, f, undo: true);
        await f.apply(tester);
        final undone = await f.finish(tester);
        expect(await draftTextRow(tester, f), before);
        expect(owner.cachedDraft(draftTextId)!.content, beforeContent);
        f.noEgress('${applied.body}${undone.body}');
      } finally {
        await unmountDraftMemory(tester, tab);
      }
    },
  );

  for (final duplicate in ['contentKey', 'idKey', 'nestedKey', 'draftId']) {
    domainLoopTest(
      'NATIVE duplicate $duplicate cannot grant raw-span draft authority',
      (tester, f) async {
        await seedDraftText(
          tester,
          f,
          draftRaw: (raw) {
            switch (duplicate) {
              case 'contentKey':
                return raw.replaceFirst(
                  '"content": ${jsonEncode(draftTextBefore)}',
                  '"content": ${jsonEncode(draftTextBefore)}, '
                      '"\\u0063ontent": ${jsonEncode(draftTextBefore)}',
                );
              case 'idKey':
                return raw.replaceFirst(
                  '"id": "$draftTextId"',
                  '"id": "$draftTextId", "\\u0069d": "$draftTextId"',
                );
              case 'nestedKey':
                return raw.replaceFirst(
                  '"unknownNumber": 1.2300e+02',
                  r'"unknownNumber": 1.2300e+02, "duplicateNested": {"k": 1, "\u006b": 1}',
                );
              default:
                return raw.replaceFirst('"sibling-draft"', '"$draftTextId"');
            }
          },
        );
        final tab = await mountDraftMemory(tester, f);
        try {
          final owner = draftMemoryOwner(f),
              before = await draftTextRow(tester, f);
          final cached = owner.readBook();
          final current = draftNativeCurrent(f);
          final observed = await configurationAction(
            tester,
            () => owner.repo.observeNativeDraft(
              sessionId: DomainLoopFixture.session,
              draftId: draftTextId,
              isCurrent: current,
            ),
          );
          expect(observed, isNull);
          expect(await draftTextRow(tester, f), before);
          expect(owner.readBook(), same(cached));
          await noDraftJournal(tester, f);
          f.noEgress();
        } finally {
          await unmountDraftMemory(tester, tab);
        }
      },
    );
  }

  for (final bound in ['draftCount', 'targetBytes', 'blobBytes']) {
    for (final overflow in [false, true]) {
      domainLoopTest(
        'NATIVE $bound ${overflow ? 'one over' : 'exact inclusive cap'} has bounded raw draft admission',
        (tester, f) async {
          final cap = bound == 'draftCount'
              ? 128
              : bound == 'targetBytes'
              ? 131072
              : 524288;
          final size = cap + (overflow ? 1 : 0);
          await seedDraftText(
            tester,
            f,
            draftRaw: (raw) {
              final drafts = jsonDecode(raw) as List;
              if (bound == 'draftCount') {
                for (var n = drafts.length; n < size; n++) {
                  drafts.add({'id': 'bounded-sibling-$n', 'content': ''});
                }
              } else {
                final target =
                    (bound == 'targetBytes' ? drafts.first : drafts.last)
                        as Map;
                target['boundedPadding'] = '';
                final used = utf8
                    .encode(
                      bound == 'targetBytes'
                          ? jsonEncode(drafts.first)
                          : jsonEncode(drafts),
                    )
                    .length;
                final remaining = size - used;
                // Actual UTF-8 bytes, not Dart string length, define these caps.
                target['boundedPadding'] =
                    List.filled(remaining ~/ 2, 'Ж').join() +
                    (remaining.isOdd ? 'p' : '');
              }
              return jsonEncode(drafts);
            },
          );
          final tab = await mountDraftMemory(tester, f);
          try {
            final owner = draftMemoryOwner(f);
            final before = await draftTextRow(tester, f);
            final cached = owner.readBook();
            final rawDrafts = jsonDecode(before.pendingDraftsJson) as List;
            expect(
              bound == 'draftCount'
                  ? rawDrafts.length
                  : utf8
                        .encode(
                          bound == 'targetBytes'
                              ? jsonEncode(rawDrafts.first)
                              : before.pendingDraftsJson,
                        )
                        .length,
              size,
            );
            final current = draftNativeCurrent(f);
            var observed = await configurationAction(
              tester,
              () => owner.repo.observeNativeDraft(
                sessionId: DomainLoopFixture.session,
                draftId: draftTextId,
                isCurrent: current,
              ),
            );
            if (overflow) {
              expect(observed, isNull);
              expect(owner.readBook(), same(cached));
              expect(await draftTextRow(tester, f), before);
              await noDraftJournal(tester, f);
            } else {
              expect(observed, isNotNull);
              if (bound != 'draftCount') {
                // At the inclusive raw-byte limit, prospective growth must be
                // a known no-effect before edit SQL/journal reservation, not IO
                // uncertainty. A fresh observation follows the retired attempt.
                final tooLarge = await configurationAction(
                  tester,
                  () => owner.reviseDraftText(
                    observed: observed!,
                    queueRevision: owner.queue.revision,
                    content: '${draftTextBefore}x',
                    support: f.screen.core.native.repo,
                    parentSession: f.screen.core.native.session,
                    operationId: 'bounded-growth-$bound',
                    sourceCurrent: current,
                  ),
                );
                expect(tooLarge, isNull);
                expect(owner.readBook(), same(cached));
                expect(await draftTextRow(tester, f), before);
                await noDraftJournal(tester, f);
                observed = await configurationAction(
                  tester,
                  () => owner.observeDraft(draftTextId, current),
                );
                expect(observed, isNotNull);
              }
              final receipt = await configurationAction(
                tester,
                () => owner.reviseDraftText(
                  observed: observed!,
                  queueRevision: owner.queue.revision,
                  content: 'short',
                  support: f.screen.core.native.repo,
                  parentSession: f.screen.core.native.session,
                  operationId: 'bounded-$bound',
                  sourceCurrent: current,
                ),
              );
              expect(receipt, isNotNull);
              final applied = receipt!;
              expect(applied.current, true);
              expect(
                await draftTextRow(tester, f),
                before.copyWith(
                  pendingDraftsJson: before.pendingDraftsJson.replaceFirst(
                    jsonEncode(draftTextBefore),
                    jsonEncode('short'),
                  ),
                ),
              );
              final undoObserved = await configurationAction(
                tester,
                () => owner.observeDraft(draftTextId, current),
              );
              final restored = await configurationAction(
                tester,
                () => owner.undoDraftText(
                  receipt: applied,
                  observed: undoObserved!,
                  queueRevision: owner.queue.revision,
                  support: f.screen.core.native.repo,
                  parentSession: f.screen.core.native.session,
                  sourceCurrent: current,
                ),
              );
              expect(restored, isNotNull);
              expect(restored!.current, true);
              expect(restored.after.content, draftTextBefore);
              expect(await draftTextRow(tester, f), before);
              expect(owner.cachedDraft(draftTextId)!.content, draftTextBefore);
            }
            f.noEgress();
          } finally {
            await unmountDraftMemory(tester, tab);
          }
        },
      );
    }
  }

  for (final preview in ['exact256', 'after257', 'before257', 'escaped258']) {
    domainLoopTest(
      'MODEL $preview respects the unchanged 256 exact JSON-literal preview cap',
      (tester, f) async {
        final beforeContent = preview == 'before257'
            ? List.filled(255, 'b').join()
            : draftTextBefore;
        final afterContent = preview == 'escaped258'
            ? List.filled(128, '\\').join()
            : List.filled(preview == 'after257' ? 255 : 254, 'a').join();
        expect(
          jsonEncode(
            preview == 'before257' ? beforeContent : afterContent,
          ).length,
          preview == 'exact256'
              ? 256
              : preview == 'escaped258'
              ? 258
              : 257,
        );
        await seedDraftText(tester, f, content: beforeContent);
        final tab = await mountDraftMemory(tester, f);
        try {
          final before = await draftTextRow(tester, f);
          final cached = draftMemoryOwner(f).cachedDraft(draftTextId);
          f.script(
            f.screen.core.call(
              'astoria_memory_draft_text_edit',
              draftTextArguments(afterContent),
            ),
            next: (_) {
              if (preview != 'exact256') {
                expect(f.lastResult()['code'], 'unavailable');
              }
              return f.screen.core.answer('Exact finite preview checked.');
            },
          );
          await startDraftText(tester, f, confirmation: preview == 'exact256');
          if (preview == 'exact256') await f.apply(tester);
          final reply = await f.finish(tester);
          if (preview == 'exact256') {
            preservedDraftText(
              before,
              await draftTextRow(tester, f),
              afterContent,
            );
            expect(
              draftMemoryOwner(f).cachedDraft(draftTextId)!.content,
              afterContent,
            );
          } else {
            expect(await draftTextRow(tester, f), before);
            expect(draftMemoryOwner(f).cachedDraft(draftTextId), same(cached));
            await noDraftJournal(tester, f);
          }
          f.noEgress(reply.body);
        } finally {
          await unmountDraftMemory(tester, tab);
        }
      },
    );
  }

  domainLoopTest(
    'MODEL receipt pruning keeps live Undo on decline and removes only retired genuine authority',
    (tester, f) async {
      await seedDraftText(tester, f);
      final tab = await mountDraftMemory(tester, f);
      try {
        f.script(
          f.screen.core.call(
            'astoria_memory_draft_text_edit',
            draftTextArguments(),
          ),
        );
        await startDraftText(tester, f);
        await f.apply(tester);
        final applied = await f.finish(tester);
        final firstRow = await draftTextRow(tester, f);
        final owner = draftMemoryOwner(f),
            cached = owner.cachedDraft(draftTextId);
        String? firstHandle;
        f.script(
          f.screen.core.call('astoria_memory_draft_text_receipts', {}),
          next: (round) {
            if (round != 2) {
              expect(round, 3);
              expect(f.lastResult()['code'], 'denied');
              return f.screen.core.answer('Replacement declined.');
            }
            final records = f.lastData()['records'] as List;
            expect(records, hasLength(1));
            firstHandle = (records.single as Map)['receipt'] as String;
            return f.screen.core.call(
              'astoria_memory_draft_text_edit',
              draftTextArguments('Declined replacement.'),
              id: 'declined_receipt_capacity_prepare',
            );
          },
        );
        await startDraftText(tester, f);
        await f.cancel(tester);
        final declined = await f.finish(tester);
        expect(await draftTextRow(tester, f), firstRow);
        expect(owner.cachedDraft(draftTextId), same(cached));
        final db = f.screen.core.native.db;
        expect(
          (await configurationAction(
            tester,
            () => db.select(db.supportMutationJournal).get(),
          )).length,
          1,
        );
        f.script(
          f.screen.core.call('astoria_memory_draft_text_receipts', {}),
          next: (round) {
            if (round != 2) {
              expect(round, 3);
              expect(f.lastResult()['code'], 'completed');
              return f.screen.core.answer('Replacement completed.');
            }
            final records = f.lastData()['records'] as List;
            expect(records, hasLength(1));
            expect((records.single as Map)['receipt'], firstHandle);
            return f.screen.core.call(
              'astoria_memory_draft_text_edit',
              draftTextArguments('Genuine replacement.'),
              id: 'new_genuine_draft_receipt',
            );
          },
        );
        await startDraftText(tester, f);
        await f.apply(tester);
        final replaced = await f.finish(tester);
        final secondRow = await draftTextRow(tester, f);
        f.script(
          f.screen.core.call('astoria_memory_draft_text_receipts', {}),
          next: (round) {
            if (round == 2) {
              final records = f.lastData()['records'] as List;
              expect(records, hasLength(1));
              expect((records.single as Map)['receipt'], isNot(firstHandle));
              return f.screen.core.call(
                'astoria_memory_draft_text_undo',
                {'receipt': firstHandle},
                id: 'pruned_retired_draft_receipt',
              );
            }
            expect(f.lastResult()['code'], 'unavailable');
            return f.screen.core.answer('Only current genuine Undo remains.');
          },
        );
        await startDraftText(tester, f, confirmation: false, undo: true);
        final retained = await f.finish(tester);
        expect(await draftTextRow(tester, f), secondRow);
        final journal = await configurationAction(
          tester,
          () => db.select(db.supportMutationJournal).get(),
        );
        expect(journal, hasLength(2));
        expect(journal.every((record) => record.status == 'applied'), true);
        f.noEgress(
          '${applied.body}${declined.body}${replaced.body}${retained.body}',
        );
      } finally {
        await unmountDraftMemory(tester, tab);
      }
    },
  );

  for (final fault in [
    'falseCAS',
    'commitSend',
    'commitDelivery',
    'publicationLoss',
  ]) {
    domainLoopTest(
      'MODEL draft $fault distinguishes rollback, uncertain delivery and actual saved fact',
      (tester, f) async {
        await seedDraftText(tester, f);
        final tab = await mountDraftMemory(tester, f);
        final sql = f.screen.core.native.sql, db = f.screen.core.native.db;
        try {
          final owner = draftMemoryOwner(f),
              before = await draftTextRow(tester, f);
          final cacheBefore = owner.cachedDraft(draftTextId);
          f.script(
            f.screen.core.call(
              'astoria_memory_draft_text_edit',
              draftTextArguments(),
            ),
          );
          await startDraftText(tester, f);
          var written = false, fired = false;
          sql.afterWrite = (statement) async {
            final s = statement.trimLeft().toLowerCase();
            if (s.startsWith('update memory_book_rows')) written = true;
            if (fault == 'falseCAS' &&
                !fired &&
                s.startsWith('insert') &&
                s.contains('support_mutation_journal')) {
              fired = true;
              await (db.update(db.memoryBookRows)..where(
                    (t) => t.sessionId.equals(DomainLoopFixture.session),
                  ))
                  .write(
                    MemoryBookRowsCompanion(
                      pendingDraftsJson: Value(
                        before.pendingDraftsJson.replaceFirst(
                          draftTextId,
                          'raw-competing-draft',
                        ),
                      ),
                    ),
                  );
            }
          };
          Future<void> commitFault() async {
            if (!written || fired) return;
            fired = true;
            if (fault == 'publicationLoss') {
              f.screen.core.container
                  .read(chatNativeOwnerRegistryProvider)
                  .existing(DomainLoopFixture.session)!
                  .queue
                  .beginPublication();
            } else {
              throw StateError(DomainLoopFixture.private);
            }
          }

          if (fault == 'commitSend') sql.beforeOuterSend = commitFault;
          if (fault == 'commitDelivery' || fault == 'publicationLoss')
            sql.afterOuterSend = commitFault;
          await f.apply(tester);
          final reply = await f.finish(tester);
          sql.afterWrite = null;
          sql.beforeOuterSend = null;
          sql.afterOuterSend = null;
          expect(fired, true);
          expect(owner.cachedDraft(draftTextId), same(cacheBefore));
          if (fault == 'commitDelivery' || fault == 'publicationLoss') {
            preservedDraftText(
              before,
              await draftTextRow(tester, f),
              draftTextAfter,
            );
            final journal = await configurationAction(
              tester,
              () => db.select(db.supportMutationJournal).get(),
            );
            expect(journal.single.status, 'applied');
          } else {
            expect(await draftTextRow(tester, f), before);
            await noDraftJournal(tester, f);
          }
          expect(
            reply.body,
            fault == 'publicationLoss'
                ? contains('изменение сохранено')
                : isNot(contains('изменение сохранено')),
          );
          f.script(
            f.screen.core.call('astoria_memory_draft_text_receipts', {}),
            next: (_) {
              expect(f.lastData()['records'], isEmpty);
              return f.screen.core.answer(
                'No current returned draft-text Undo authority.',
              );
            },
          );
          await startDraftText(tester, f, confirmation: false);
          final retained = await f.finish(tester);
          f.noEgress('${reply.body}${retained.body}');
        } finally {
          sql.afterWrite = null;
          sql.beforeOuterSend = null;
          sql.afterOuterSend = null;
          await unmountDraftMemory(tester, tab);
        }
      },
    );
  }
}
