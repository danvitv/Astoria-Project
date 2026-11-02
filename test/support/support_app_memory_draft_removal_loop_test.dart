import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/features/chat/state/chat_native_owner_registry.dart';
import 'package:glaze_flutter/features/memory/state/memory_native_entry_owner.dart';
import 'package:glaze_flutter/features/memory/state/memory_active_drafts_provider.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';

import 'support_app_memory_draft_removal_fixture.dart';

void main() {
  for (final position in ['first', 'middle', 'last', 'sole']) {
    domainLoopTest(
      'MODEL removal $position discovery, raw token preservation and fresh exact Undo',
      (tester, f) async {
        await seedDraftText(
          tester,
          f,
          draftRaw: (raw) => arrangeRemovalDrafts(
            raw.replaceFirst(
              '"unknownNumber": 1.2300e+02',
              '"privateCredential": ${jsonEncode(f.screen.core.boundSyntheticSecret)}, '
                  '"unknownNumber": 1.2300e+02',
            ),
            position,
          ),
        );
        final tab = await mountDraftMemory(tester, f);
        try {
          final before = await draftTextRow(tester, f),
              owner = draftMemoryOwner(f);
          final originalDrafts = owner.readBook()!.pendingDrafts;
          draftNonEgressControls(f);
          f.script(
            f.screen.core.call('astoria_session_integrity', {
              'operation': 'discover',
            }),
            next: (round) {
              if (round == 2) {
                final record = (f.lastData()['records'] as List)
                    .cast<Map<Object?, Object?>>()
                    .singleWhere(
                      (r) => r['sessionId'] == DomainLoopFixture.session,
                    );
                return f.screen.core.call('astoria_memory_inspect', {
                  'sessionId': record['sessionId'],
                  'view': 'drafts',
                }, id: 'removal_discovery');
              }
              if (round == 3) {
                final item = (f.lastData()['items'] as List)
                    .cast<Map<Object?, Object?>>()
                    .singleWhere((r) => r['draftId'] == draftTextId);
                expect(item['status'], 'pending_approval');
                expect(item['vectorSearch'], false);
                return f.screen.core.call('astoria_memory_draft_delete', {
                  'sessionId': DomainLoopFixture.session,
                  'draftId': item['draftId'],
                }, id: 'remove_discovered_one');
              }
              expect(round, 4);
              expect(f.lastResult()['effect'], 'persisted');
              return f.screen.core.answer('One discovered draft removed.');
            },
          );
          await startDraftRemoval(tester, f);
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
          expect(preview, contains('"delete":true'));
          expect(preview, contains('"affectedRecords":1'));
          expect(preview, isNot(contains('unknownDraft')));
          expect(preview, isNot(contains(DomainLoopFixture.private)));
          await f.apply(tester);
          final deleted = await f.finish(tester);
          expect(deleted.body, contains('изменение сохранено'));
          expect(draftMemoryOwner(f), same(owner));
          expect(owner.cachedDraft(draftTextId), isNull);
          preservedRemovalRow(
            before,
            await draftTextRow(tester, f),
            expectedRemovedArray(before.pendingDraftsJson, position),
          );
          final records = await configurationAction(
            tester,
            () => f.screen.core.native.repo.getMutationsForSession(
              f.screen.core.native.session,
            ),
          );
          expect(records.single.domain, 'memory.draft.delete');
          expect(records.single.status, 'applied');
          final nativeBefore =
              jsonDecode(
                    SupportMutationEvidence.decode(records.single.beforeJson)!,
                  )
                  as Map;
          expect(
            nativeBefore['removedRaw'],
            contains('"unknownNumber": 1.2300e+02'),
          );
          expect(nativeBefore['removedRaw'], contains('unknownDraft'));
          expect(
            nativeBefore['removedRaw'],
            contains(f.screen.core.boundSyntheticSecret),
          );
          expect(nativeBefore['arrayHash'], hasLength(64));
          expect(
            utf8
                .encode(
                  SupportMutationEvidence.decode(records.single.beforeJson)!,
                )
                .length,
            lessThanOrEqualTo(8192),
          );
          scriptRemovalUndo(f);
          await startDraftRemoval(tester, f, undo: true);
          await f.apply(tester);
          final undone = await f.finish(tester);
          expect(undone.body, contains('изменение сохранено'));
          expect(await draftTextRow(tester, f), before);
          expect(owner.readBook()!.pendingDrafts, originalDrafts);
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
          expect(
            journal.single.beforeCiphertext,
            isNot(contains(DomainLoopFixture.private)),
          );
          expect(
            journal.single.beforeCiphertext,
            isNot(contains(f.screen.core.boundSyntheticSecret)),
          );
          expect(
            await configurationAction(
              tester,
              () => db.select(db.embeddings).get(),
            ),
            isEmpty,
          );
          f.noEgress('${deleted.body}${undone.body}');
        } finally {
          await unmountDraftMemory(tester, tab);
        }
      },
    );
  }

  for (final mode in [
    'noOwner',
    'absent',
    'pendingGeneration',
    'error',
    'needsRegeneration',
    'vector',
    'agentic',
    'studioLedger',
    'generating',
  ]) {
    domainLoopTest(
      'MODEL removal $mode refuses without effects or new ownership',
      (tester, f) async {
        await seedDraftText(
          tester,
          f,
          status: switch (mode) {
            'pendingGeneration' => 'pending_generation',
            'error' => 'error',
            'needsRegeneration' => 'needs_regeneration',
            _ => 'pending_approval',
          },
          vector: mode == 'vector',
          draftRaw: (raw) => switch (mode) {
            'absent' => raw.replaceFirst(draftTextId, 'different-id'),
            'agentic' => raw.replaceFirst('scan_chat', 'agentic'),
            'studioLedger' => raw.replaceFirst('scan_chat', 'studio_ledger'),
            _ => raw,
          },
        );
        final tab = mode == 'noOwner'
            ? null
            : await mountDraftMemory(tester, f);
        final lease = mode == 'generating'
            ? await configurationAction(
                tester,
                () => f.screen.core.container
                    .read(memoryActiveDraftsProvider.notifier)
                    .acquire(DomainLoopFixture.session),
              )
            : null;
        try {
          final before = await draftTextRow(tester, f);
          f.script(
            f.screen.core.call(
              'astoria_memory_draft_delete',
              draftRemovalArguments(),
            ),
            next: (_) {
              expect(f.lastResult()['code'], 'unavailable');
              return f.screen.core.answer('No eligible original draft.');
            },
          );
          await startDraftRemoval(tester, f, confirmation: false);
          final reply = await f.finish(tester);
          expect(await draftTextRow(tester, f), before);
          await noDraftJournal(tester, f);
          f.noEgress(reply.body);
        } finally {
          lease?.release();
          if (tab != null) await unmountDraftMemory(tester, tab);
        }
      },
    );
  }

  for (final mode in [
    'duplicateId',
    'escapedDuplicateKey',
    'count129',
    'targetOverflow',
    'blobOverflow',
    'evidenceOverflow',
    'preview257',
    'secretBody',
    'settingsOverflow',
    'settingsVector',
  ]) {
    domainLoopTest('MODEL removal $mode is bounded PRE-effect refusal', (
      tester,
      f,
    ) async {
      await seedDraftText(
        tester,
        f,
        content: mode == 'preview257'
            ? List.filled(255, 'a').join()
            : mode == 'secretBody'
            ? f.screen.core.boundSyntheticSecret
            : draftTextBefore,
        draftRaw: (raw) {
          if (mode == 'duplicateId')
            return raw.replaceFirst('sibling-draft', draftTextId);
          if (mode == 'escapedDuplicateKey')
            return raw.replaceFirst(
              '"id": "$draftTextId"',
              '"id": "$draftTextId", "\\u0069d": "$draftTextId"',
            );
          final drafts = jsonDecode(raw) as List;
          if (mode == 'count129') {
            for (var n = drafts.length; n < 129; n++) {
              drafts.add({'id': 'sibling-$n', 'content': ''});
            }
          } else if (const {
            'targetOverflow',
            'blobOverflow',
            'evidenceOverflow',
          }.contains(mode)) {
            final map =
                (mode == 'blobOverflow' ? drafts.last : drafts.first) as Map;
            map['padding'] = List.filled(
              mode == 'targetOverflow'
                  ? 131073
                  : mode == 'blobOverflow'
                  ? 524289
                  : 8193,
              'p',
            ).join();
          }
          return jsonEncode(drafts);
        },
      );
      if (mode.startsWith('settings')) {
        await configurationAction(tester, () async {
          final db = f.screen.core.native.db;
          await (db.update(
            db.memoryBookRows,
          )..where((t) => t.sessionId.equals(DomainLoopFixture.session))).write(
            MemoryBookRowsCompanion(
              settingsJson: Value(
                mode == 'settingsOverflow'
                    ? jsonEncode({'padding': List.filled(65537, 'p').join()})
                    : '{"vectorSearchEnabled":true}',
              ),
            ),
          );
        });
      }
      final tab = await mountDraftMemory(tester, f);
      try {
        final before = await draftTextRow(tester, f);
        final cache = mode == 'settingsVector'
            ? null
            : draftMemoryOwner(f).readBook();
        f.script(
          f.screen.core.call(
            'astoria_memory_draft_delete',
            draftRemovalArguments(),
          ),
          next: (_) {
            expect(f.lastResult()['code'], 'unavailable');
            return f.screen.core.answer('Bounded exact removal refused.');
          },
        );
        await startDraftRemoval(tester, f, confirmation: false);
        final reply = await f.finish(tester);
        expect(await draftTextRow(tester, f), before);
        if (mode != 'settingsVector')
          expect(draftMemoryOwner(f).readBook(), same(cache));
        await noDraftJournal(tester, f);
        f.noEgress(reply.body);
      } finally {
        await unmountDraftMemory(tester, tab);
      }
    });
  }

  for (final mode in [
    'cancel',
    'ordinaryWriterABA',
    'generationABA',
    'rawContradiction',
    'ownerReplacement',
  ]) {
    domainLoopTest(
      'MODEL removal $mode after confirmation preserves raw state',
      (tester, f) async {
        await seedDraftText(tester, f);
        var tab = await mountDraftMemory(tester, f);
        try {
          f.script(
            f.screen.core.call(
              'astoria_memory_draft_delete',
              draftRemovalArguments(),
            ),
          );
          await startDraftRemoval(tester, f);
          final accept = find.byKey(
            const ValueKey('support_tool_confirmation_accept'),
          );
          final route = ModalRoute.of<void>(tester.element(accept))!;
          final expired = tester.widget<GlazeActionButton>(accept).onTap!;
          if (mode == 'ordinaryWriterABA') {
            await configurationAction(
              tester,
              () => draftMemoryOwner(f).repo.mutateDraft(
                sessionId: DomainLoopFixture.session,
                draftId: draftTextId,
                mutate: (d) => d,
              ),
            );
          } else if (mode == 'generationABA') {
            await configurationAction(tester, () async {
              f.screen.core.container
                  .read(memoryActiveDraftsProvider.notifier)
                  .acquire(DomainLoopFixture.session)
                  .release();
            });
          } else if (mode == 'rawContradiction') {
            final row = await draftTextRow(tester, f);
            await configurationAction(tester, () async {
              final db = f.screen.core.native.db;
              await (db.update(db.memoryBookRows)..where(
                    (t) => t.sessionId.equals(DomainLoopFixture.session),
                  ))
                  .write(
                    MemoryBookRowsCompanion(
                      pendingDraftsJson: Value(' ${row.pendingDraftsJson}'),
                    ),
                  );
            });
          } else if (mode == 'ownerReplacement') {
            await unmountDraftMemory(tester, tab);
            tab = await mountDraftMemory(tester, f);
          }
          final before = await draftTextRow(tester, f);
          if (mode == 'cancel') {
            await f.cancel(tester);
          } else {
            await configurationAction(tester, expired);
            await tester.pump();
            if (route.isCurrent) {
              await f.cancel(tester);
            } else {
              // Acceptance pops synchronously, but native confirmation joins
              // this exact route's disposal after its reverse animation.
              await tester.pump(
                route.reverseTransitionDuration +
                    const Duration(microseconds: 1),
              );
            }
            expect(route.isCurrent, false);
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

  for (final undo in [false, true]) {
    for (final matching in [false, true]) {
      domainLoopTest(
        'MODEL ${undo ? 'Undo' : 'delete'} any ${matching ? 'matching' : 'unrelated'} alias at SQL retires issuer',
        (tester, f) async {
          await seedDraftText(tester, f);
          final tab = await mountDraftMemory(tester, f),
              sql = f.screen.core.native.sql;
          try {
            if (undo) {
              f.script(
                f.screen.core.call(
                  'astoria_memory_draft_delete',
                  draftRemovalArguments(),
                ),
              );
              await startDraftRemoval(tester, f);
              await f.apply(tester);
              await f.finish(tester);
              scriptRemovalUndo(f);
            } else {
              f.script(
                f.screen.core.call(
                  'astoria_memory_draft_delete',
                  draftRemovalArguments(),
                ),
              );
            }
            final before = await draftTextRow(tester, f),
                cache = draftMemoryOwner(f).readBook();
            await startDraftRemoval(tester, f, undo: undo);
            var changed = false;
            sql.afterWrite = (s) async {
              if (!changed &&
                  s.trimLeft().toLowerCase().startsWith(
                    'update memory_book_rows',
                  )) {
                changed = true;
                f.screen.core.native.redaction.registerSecret(
                  matching
                      ? draftTextBefore
                      : 'SYNTHETIC_UNRELATED_REMOVAL_ALIAS',
                );
              }
            };
            await f.apply(tester);
            final reply = await f.finish(tester);
            sql.afterWrite = null;
            expect(changed, true);
            expect(await draftTextRow(tester, f), before);
            expect(draftMemoryOwner(f).readBook(), same(cache));
            if (!undo) await noDraftJournal(tester, f);
            expect(reply.body, isNot(contains('изменение сохранено')));
            f.noEgress(reply.body);
          } finally {
            sql.afterWrite = null;
            await unmountDraftMemory(tester, tab);
          }
        },
      );
    }
  }

  for (final undo in [false, true]) {
    domainLoopTest(
      'MODEL removal actual outer COMMIT late ordinary writer before ${undo ? 'Undo' : 'delete'} publication',
      (tester, f) async {
        await seedDraftText(tester, f);
        final tab = await mountDraftMemory(tester, f),
            sql = f.screen.core.native.sql;
        Future<void>? ordinaryWriter;
        String? oldHandle;
        try {
          final owner = draftMemoryOwner(f);
          if (undo) {
            f.script(
              f.screen.core.call(
                'astoria_memory_draft_delete',
                draftRemovalArguments(),
              ),
            );
            await startDraftRemoval(tester, f);
            await f.apply(tester);
            await f.finish(tester);
            scriptRemovalUndo(f, handle: (id) => oldHandle = id);
          } else {
            f.script(
              f.screen.core.call(
                'astoria_memory_draft_delete',
                draftRemovalArguments(),
              ),
              next: (_) {
                final result = f.lastResult(), data = result['data'] as Map;
                expect(result['effect'], 'persisted');
                expect(data['refreshPending'], true);
                expect(data.containsKey('receipt'), false);
                return f.screen.core.answer('Persisted, cache awaits refresh.');
              },
            );
          }
          final cache = owner.readBook();
          await startDraftRemoval(tester, f, undo: undo);
          var written = false, fired = false;
          sql.afterWrite = (s) async {
            if (s.trimLeft().toLowerCase().startsWith(
              'update memory_book_rows',
            ))
              written = true;
          };
          await configurationAction(tester, () async {
            final originalZone = Zone.current;
            sql.afterOuterSend = () async {
              if (!written || fired) return;
              fired = true;
              sql.afterOuterSend = null;
              ordinaryWriter = originalZone.run(
                () => owner.repo.updateSettings(
                  DomainLoopFixture.session,
                  cache!.settings,
                ),
              );
            };
          });
          await f.apply(tester);
          final reply = await f.finish(tester);
          await configurationAction(tester, () => ordinaryWriter!);
          sql.afterWrite = null;
          expect(fired, true);
          expect(owner.readBook(), same(cache));
          final row = await draftTextRow(tester, f);
          expect(
            (jsonDecode(row.pendingDraftsJson) as List).any(
              (d) => d['id'] == draftTextId,
            ),
            undo,
          );
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
          f.script(
            f.screen.core.call('astoria_memory_draft_delete_receipts', {}),
            next: (round) {
              if (round == 2) {
                expect(f.lastData()['records'], isEmpty);
                return f.screen.core.call('astoria_memory_draft_delete_undo', {
                  'receipt':
                      oldHandle ?? 'repair-${List.filled(32, 'a').join()}',
                }, id: 'retired_removal_undo');
              }
              expect(f.lastResult()['code'], 'unavailable');
              return f.screen.core.answer('No old Undo authority.');
            },
          );
          await startDraftRemoval(tester, f, confirmation: false, undo: true);
          final stale = await f.finish(tester);
          expect(await draftTextRow(tester, f), row);
          expect(owner.readBook(), same(cache));
          f.noEgress('${reply.body}${stale.body}');
        } finally {
          sql.afterWrite = null;
          sql.afterOuterSend = null;
          if (ordinaryWriter != null)
            await configurationAction(tester, () => ordinaryWriter!);
          await unmountDraftMemory(tester, tab);
        }
      },
    );
  }

  for (final mode in [
    'cancel',
    'rawSiblingChange',
    'deleteReinsertABA',
    'sourceAlias',
    'freshPreviewStale',
  ]) {
    domainLoopTest(
      'MODEL genuine removal Undo $mode cannot restore stale authority',
      (tester, f) async {
        await seedDraftText(tester, f);
        final tab = await mountDraftMemory(tester, f);
        try {
          f.script(
            f.screen.core.call(
              'astoria_memory_draft_delete',
              draftRemovalArguments(),
            ),
          );
          await startDraftRemoval(tester, f);
          await f.apply(tester);
          final deleted = await f.finish(tester);
          final owner = draftMemoryOwner(f),
              removedRow = await draftTextRow(tester, f);
          String? handle;
          scriptRemovalUndo(f, handle: (id) => handle = id);
          await startDraftRemoval(tester, f, undo: true);
          final accept = find.byKey(
            const ValueKey('support_tool_confirmation_accept'),
          );
          final route = ModalRoute.of<void>(tester.element(accept))!;
          final expiredApply = tester.widget<GlazeActionButton>(accept).onTap!;
          if (mode == 'cancel') {
            await f.cancel(tester);
            await f.finish(tester);
            expect(await draftTextRow(tester, f), removedRow);
            // A cancelled fresh confirmation preserves genuine live Undo.
            scriptRemovalUndo(f, handle: (id) => expect(id, handle));
            await startDraftRemoval(tester, f, undo: true);
            await f.apply(tester);
            final undone = await f.finish(tester);
            expect(owner.cachedDraft(draftTextId)!.content, draftTextBefore);
            f.noEgress('${deleted.body}${undone.body}');
            return;
          }
          if (mode == 'rawSiblingChange') {
            await configurationAction(tester, () async {
              final db = f.screen.core.native.db;
              await (db.update(db.memoryBookRows)..where(
                    (t) => t.sessionId.equals(DomainLoopFixture.session),
                  ))
                  .write(
                    MemoryBookRowsCompanion(
                      pendingDraftsJson: Value(
                        ' ${removedRow.pendingDraftsJson}',
                      ),
                    ),
                  );
            });
          } else if (mode == 'deleteReinsertABA') {
            await configurationAction(tester, () async {
              await owner.repo.deleteBySessionId(DomainLoopFixture.session);
              await owner.repo.put(owner.readBook()!);
            });
          } else if (mode == 'sourceAlias') {
            f.screen.core.native.redaction.registerSecret(
              'SYNTHETIC_UNRELATED_UNDO_ALIAS',
            );
          } else {
            await configurationAction(
              tester,
              () => owner.repo.updateSettings(
                DomainLoopFixture.session,
                owner.readBook()!.settings,
              ),
            );
          }
          final before = await draftTextRow(tester, f),
              cache = owner.readBook();
          await configurationAction(tester, expiredApply);
          await tester.pump();
          if (route.isCurrent) {
            await f.cancel(tester);
          } else {
            await tester.pump(
              route.reverseTransitionDuration +
                  const Duration(microseconds: 1),
            );
          }
          expect(route.isCurrent, false);
          final reply = await f.finish(tester);
          expect(reply.body, isNot(contains('изменение сохранено')));
          expect(await draftTextRow(tester, f), before);
          expect(owner.readBook(), same(cache));
          final db = f.screen.core.native.db;
          final journal = await configurationAction(
            tester,
            () => db.select(db.supportMutationJournal).get(),
          );
          expect(journal.single.status, 'applied');
          f.noEgress('${deleted.body}${reply.body}');
        } finally {
          await unmountDraftMemory(tester, tab);
        }
      },
    );
  }

  for (final overflow in [false, true]) {
    domainLoopTest(
      'NATIVE removal exact private evidence ${overflow ? '8193 refuses' : '8192 allows full raw Undo'}',
      (tester, f) async {
        await seedDraftText(
          tester,
          f,
          draftRaw: (_) {
            final target = <String, Object?>{
              'id': draftTextId,
              'content': draftTextBefore,
              'status': 'pending_approval',
              'source': 'scan_chat',
              'padding': '',
            };
            final base = jsonEncode({
              'v': 1,
              'session': DomainLoopFixture.session,
              'draft': draftTextId,
              'index': 0,
              'at': 1,
              'arrayHash': List.filled(64, '0').join(),
              'removedRaw': '${jsonEncode(target)},',
            });
            final room = 8192 + (overflow ? 1 : 0) - utf8.encode(base).length;
            target['padding'] =
                List.filled(room ~/ 2, 'Ж').join() + (room.isOdd ? 'p' : '');
            return '[${jsonEncode(target)},{"id":"sibling","content":""}]';
          },
        );
        final tab = await mountDraftMemory(tester, f);
        try {
          final owner = draftMemoryOwner(f),
              before = await draftTextRow(tester, f);
          final current = draftNativeCurrent(f);
          final observed = await configurationAction(
            tester,
            () => owner.observeDraftRemoval(draftTextId, current),
          );
          if (overflow) {
            expect(observed, isNull);
            await noDraftJournal(tester, f);
          } else {
            expect(observed, isNotNull);
            final receipt = await configurationAction(
              tester,
              () => owner.removeDraft(
                observed: observed!,
                queueRevision: owner.queue.revision,
                support: f.screen.core.native.repo,
                parentSession: f.screen.core.native.session,
                operationId: 'bounded-exact-native-removal',
                sourceCurrent: current,
              ),
            );
            expect(receipt, isNotNull);
            final records = await configurationAction(
              tester,
              () => f.screen.core.native.repo.getMutationsForSession(
                f.screen.core.native.session,
              ),
            );
            expect(
              utf8
                  .encode(
                    SupportMutationEvidence.decode(records.single.beforeJson)!,
                  )
                  .length,
              8192,
            );
            final absence = await configurationAction(
              tester,
              () => owner.observeDraftRemovalUndo(receipt!, current),
            );
            expect(absence, isNotNull);
            final restored = await configurationAction(
              tester,
              () => owner.undoDraftRemoval(
                receipt: receipt!,
                observed: absence!,
                queueRevision: owner.queue.revision,
                support: f.screen.core.native.repo,
                parentSession: f.screen.core.native.session,
                sourceCurrent: current,
              ),
            );
            expect(restored, isNotNull);
            expect(restored!.current, true);
          }
          expect(await draftTextRow(tester, f), before);
          f.noEgress();
        } finally {
          await unmountDraftMemory(tester, tab);
        }
      },
    );
  }

  for (final fault in [
    'falseCAS',
    'commitSend',
    'commitDelivery',
    'publicationLoss',
  ]) {
    domainLoopTest(
      'MODEL removal $fault preserves fact classification and never retries unknown delivery',
      (tester, f) async {
        await seedDraftText(tester, f);
        final tab = await mountDraftMemory(tester, f),
            sql = f.screen.core.native.sql;
        try {
          final owner = draftMemoryOwner(f),
              before = await draftTextRow(tester, f);
          final cache = owner.readBook(), db = f.screen.core.native.db;
          f.script(
            f.screen.core.call(
              'astoria_memory_draft_delete',
              draftRemovalArguments(),
            ),
          );
          await startDraftRemoval(tester, f);
          var written = false, fired = false, updates = 0;
          sql.afterWrite = (s) async {
            final statement = s.trimLeft().toLowerCase();
            if (statement.startsWith('update memory_book_rows')) {
              written = true;
              updates++;
            }
            if (fault == 'falseCAS' &&
                !fired &&
                statement.startsWith('insert') &&
                statement.contains('support_mutation_journal')) {
              fired = true;
              await (db.update(db.memoryBookRows)..where(
                    (t) => t.sessionId.equals(DomainLoopFixture.session),
                  ))
                  .write(
                    MemoryBookRowsCompanion(
                      pendingDraftsJson: Value(' ${before.pendingDraftsJson}'),
                    ),
                  );
            }
          };
          Future<void> commitFault() async {
            if (!written || fired) return;
            fired = true;
            if (fault == 'publicationLoss') {
              // Original native guard loses publication only AFTER real COMMIT.
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
          expect(owner.readBook(), same(cache));
          if (fault == 'commitDelivery' || fault == 'publicationLoss') {
            expect(
              (jsonDecode((await draftTextRow(tester, f)).pendingDraftsJson)
                      as List)
                  .any((d) => d['id'] == draftTextId),
              false,
            );
            expect(
              (await configurationAction(
                tester,
                () => db.select(db.supportMutationJournal).get(),
              )).single.status,
              'applied',
            );
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
          if (fault == 'commitDelivery') expect(updates, 1);
          f.script(
            f.screen.core.call('astoria_memory_draft_delete_receipts', {}),
            next: (_) {
              expect(f.lastData()['records'], isEmpty);
              return f.screen.core.answer(
                'No current returned Undo authority.',
              );
            },
          );
          await startDraftRemoval(tester, f, confirmation: false);
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
