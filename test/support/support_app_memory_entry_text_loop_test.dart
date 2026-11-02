import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/memory_entry_revisions.dart';
import 'package:glaze_flutter/core/models/memory_source_manifest.dart';
import 'package:glaze_flutter/core/state/chat_source_mutation_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/lorebook_embedding_provider.dart';
import 'package:glaze_flutter/core/state/memory_book_ops_provider.dart';
import 'package:glaze_flutter/core/state/memory_settings_provider.dart';
import 'package:glaze_flutter/features/chat/widgets/memory_books_tab.dart';
import 'package:glaze_flutter/features/chat/state/chat_native_owner_registry.dart';
import 'package:glaze_flutter/features/memory/state/memory_draft_jobs_provider.dart';
import 'package:glaze_flutter/features/memory/state/memory_native_entry_owner.dart';
import 'package:glaze_flutter/features/support_assistant/support_assistant_screen.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_composer_bar.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';

import 'support_app_domain_loop_fixture.dart';

const _entry = 'exact-native-memory';
const _before = 'Original approved text.\nSecond paragraph.';
const _after = ' Exact revised text.\n\nWhitespace is part of the edit. ';

MemoryNativeEntryOwner? _captureOriginalMemory(Ref ref) => ref
    .read(memoryNativeEntryOwnerRegistryProvider)
    .existing(DomainLoopFixture.session, originContainer: ref.container);

// Localized test seam calls only the passive production lookup. It neither
// constructs an owner/controller/adapter nor reloads any source provider.
final _memoryOriginProbe = Provider<MemoryNativeEntryOwner?>(
  _captureOriginalMemory,
);

void main() {
  domainLoopTest(
    'MODEL exact original Memory text revision and fresh retained Undo append history',
    (tester, f) async {
      await _seed(tester, f);
      final tab = await _mount(tester, f);
      try {
        _nonEgressControls(f);
        final c = f.screen.core.container, db = f.screen.core.native.db;
        final owner = c
            .read(memoryNativeEntryOwnerRegistryProvider)
            .existing(DomainLoopFixture.session, originContainer: c)!;
        expect(owner.originContainer, same(c));
        final before = await _row(tester, f);
        final rawBefore = (jsonDecode(before.entriesJson) as List).first as Map;
        final historyBefore = (rawBefore['revisions'] as List).toList();
        f.script(
          f.screen.core.call('astoria_memory_entry_text_revise', _arguments()),
        );
        await f.start(tester);
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
        expect(preview, contains('appendOnlyHistory'));
        expect(preview, contains(jsonEncode(jsonEncode(_before))));
        expect(preview, contains(jsonEncode(jsonEncode(_after))));
        await f.apply(tester);
        final editedReply = await f.finish(tester);
        expect(editedReply.body, contains('изменение сохранено'));
        expect(owner.cached(_entry)!.content, _after);
        expect(
          c
              .read(memoryNativeEntryOwnerRegistryProvider)
              .existing(DomainLoopFixture.session, originContainer: c),
          same(owner),
        );
        final edited = await _row(tester, f);
        final rawEdited = (jsonDecode(edited.entriesJson) as List).first as Map;
        final historyEdited = rawEdited['revisions'] as List;
        expect(
          historyEdited.take(historyBefore.length).toList(),
          historyBefore,
        );
        expect(historyEdited.length, historyBefore.length + 1);
        _preserved(before, edited);
        var journal = await configurationAction(
          tester,
          () => db.select(db.supportMutationJournal).get(),
        );
        expect(journal.single.domain, 'memory.entry.text');
        expect(journal.single.status, 'applied');
        final pair = jsonEncode([DomainLoopFixture.session, _entry]);
        expect(
          journal.single.targetId,
          'memory-entry-${sha256.convert(utf8.encode(pair))}',
        );
        expect(
          RegExp(
            r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$',
          ).hasMatch(journal.single.targetId),
          true,
        );
        final evidence = await configurationAction(
          tester,
          () => f.screen.core.native.repo.getMutationsForSession(
            f.screen.core.native.session,
          ),
        );
        for (final encoded in [
          evidence.single.beforeJson,
          evidence.single.afterJson,
        ]) {
          final native =
              jsonDecode(SupportMutationEvidence.decode(encoded)!) as Map;
          expect(native['session'], DomainLoopFixture.session);
          expect(native['entry'], _entry);
          expect(
            native['content'],
            encoded == evidence.single.beforeJson ? _before : _after,
          );
        }
        expect(journal.single.beforeCiphertext, isNot(contains(_before)));
        expect(journal.single.afterCiphertext, isNot(contains(_after)));

        f.script(
          f.screen.core.call('astoria_memory_entry_text_receipts', {}),
          next: (_) {
            final records = f.lastData()['records'] as List;
            expect(records, hasLength(1));
            return f.screen.core.call('astoria_memory_entry_text_undo', {
              'receipt': (records.single as Map)['receipt'],
            }, id: 'fresh_memory_text_undo');
          },
        );
        await f.start(tester);
        await f.apply(tester);
        final undoneReply = await f.finish(tester);
        expect(undoneReply.body, contains('изменение сохранено'));
        final undone = await _row(tester, f);
        final rawUndone = (jsonDecode(undone.entriesJson) as List).first as Map;
        final historyUndone = rawUndone['revisions'] as List;
        expect(rawUndone['content'], _before);
        expect(owner.cached(_entry)!.content, _before);
        expect(
          historyUndone.take(historyEdited.length).toList(),
          historyEdited,
        );
        expect(historyUndone.length, historyEdited.length + 1);
        expect(
          rawUndone['activeRevisionId'],
          isNot(rawBefore['activeRevisionId']),
        );
        expect((historyUndone.last as Map)['reason'], 'assistant_text_undo');
        _preserved(before, undone);
        journal = await configurationAction(
          tester,
          () => db.select(db.supportMutationJournal).get(),
        );
        expect(journal.single.status, 'undone');
        expect(journal.single.targetId, evidence.single.targetId);
        expect(
          await configurationAction(
            tester,
            () => db.select(db.embeddings).get(),
          ),
          isEmpty,
        );
        f.noEgress('${editedReply.body}${undoneReply.body}');
        _nonEgressControls(f);
      } finally {
        await _unmount(tester, tab);
      }
    },
  );

  for (final mode in [
    'declined',
    'staleEntry',
    'sourceABA',
    'nativeWriterABA',
    'disposedTab',
  ]) {
    domainLoopTest(
      'MODEL Memory text $mode after exact preview grants no edit or journal',
      (tester, f) async {
        await _seed(tester, f);
        final tab = await _mount(tester, f);
        var removed = false;
        try {
          final c = f.screen.core.container;
          final before = await _row(tester, f);
          f.script(
            f.screen.core.call(
              'astoria_memory_entry_text_revise',
              _arguments(),
            ),
          );
          await f.start(tester);
          final accept = find.byKey(
            const ValueKey('support_tool_confirmation_accept'),
          );
          final route = ModalRoute.of<void>(tester.element(accept))!;
          final expiredApply = tester.widget<GlazeActionButton>(accept).onTap!;
          if (mode == 'disposedTab') {
            await _unmount(tester, tab);
            removed = true;
          } else if (mode == 'sourceABA') {
            await configurationAction(tester, () async {
              final mutations = c.read(chatSourceMutationRegistryProvider);
              for (var n = 0; n < 2; n++) {
                mutations.beginMutation(sessionId: DomainLoopFixture.session)();
              }
            });
          } else if (mode == 'nativeWriterABA') {
            await configurationAction(tester, () async {
              final repo = c.read(memoryBookRepoProvider);
              final original = (await repo.getBySessionId(
                DomainLoopFixture.session,
              ))!;
              await repo.put(
                original,
              ); // Equal authoritative writes retire the exact ticket.
              await repo.put(original);
            });
          } else if (mode == 'staleEntry') {
            await configurationAction(tester, () async {
              final repo = c.read(memoryBookRepoProvider);
              final book = (await repo.getBySessionId(
                DomainLoopFixture.session,
              ))!;
              final entry = book.entries.first;
              await repo.reviseEntry(
                sessionId: book.sessionId,
                expected: entry,
                proposed: entry.copyWith(
                  content: 'Competing approved revision',
                ),
              );
            });
          }
          final immediatelyBefore = await _row(tester, f);
          if (mode == 'declined') {
            await f.cancel(tester);
          } else {
            // The original expired gesture cannot admit a write or dismiss the
            // original sheet. Only its native Cancel closes that retained route.
            await configurationAction(tester, expiredApply);
            await tester.pump();
            if (route.isCurrent) await f.cancel(tester);
          }
          await tester.pump(route.reverseTransitionDuration);
          await tester.pump(const Duration(microseconds: 1));
          expect(route.isCurrent, false);
          final reply = await f.finish(tester);
          expect(reply.body, isNot(contains('изменение сохранено')));
          expect(await _row(tester, f), immediatelyBefore);
          if (mode == 'declined' ||
              mode == 'sourceABA' ||
              mode == 'disposedTab') {
            expect(immediatelyBefore, before);
          }
          await _noJournal(tester, f);
          f.noEgress(reply.body);
        } finally {
          if (!removed) await _unmount(tester, tab);
        }
      },
    );
  }

  for (final retirement in ['nativeWriter', 'sourceABA', 'ownerABA']) {
    domainLoopTest(
      'MODEL genuine Memory receipt is retired by $retirement and cannot be guessed',
      (tester, f) async {
        await _seed(tester, f);
        final tab = await _mount(tester, f);
        try {
          f.script(
            f.screen.core.call(
              'astoria_memory_entry_text_revise',
              _arguments(),
            ),
          );
          await f.start(tester);
          await f.apply(tester);
          final edited = await f.finish(tester);
          expect(edited.body, contains('изменение сохранено'));
          await configurationAction(tester, () async {
            final c = f.screen.core.container;
            if (retirement == 'nativeWriter') {
              final repo = c.read(memoryBookRepoProvider);
              final observation = (await repo.observeForControl(
                DomainLoopFixture.session,
              ))!;
              await repo.patchSettingsForControl(
                expected: observation,
                fields: {'enabled': observation.book.settings.enabled},
                isCurrent: () => true,
              );
            } else if (retirement == 'sourceABA') {
              final mutations = c.read(chatSourceMutationRegistryProvider);
              for (var n = 0; n < 2; n++) {
                mutations.beginMutation(sessionId: DomainLoopFixture.session)();
              }
            } else {
              await c
                  .read(chatNativeOwnerRegistryProvider)
                  .beforeSessionSelection();
              await c
                  .read(chatNativeOwnerRegistryProvider)
                  .beforeSessionSelection();
            }
          });
          f.script(
            f.screen.core.call('astoria_memory_entry_text_receipts', {}),
            next: (round) {
              if (round == 2) {
                expect(f.lastData()['records'], isEmpty);
                return f.screen.core.call('astoria_memory_entry_text_undo', {
                  'receipt': 'repair-${List.filled(32, 'a').join()}',
                }, id: 'guessed_memory_undo');
              }
              expect(f.lastResult()['code'], 'unavailable');
              return f.screen.core.answer(
                'No current original Memory receipt.',
              );
            },
          );
          await f.start(tester, confirmation: false);
          final reply = await f.finish(tester);
          expect(
            ((jsonDecode((await _row(tester, f)).entriesJson) as List).first
                as Map)['content'],
            _after,
          );
          final journal = await configurationAction(
            tester,
            () => f.screen.core.native.db
                .select(f.screen.core.native.db.supportMutationJournal)
                .get(),
          );
          expect(journal.single.status, 'applied');
          f.noEgress('${edited.body}${reply.body}');
        } finally {
          await _unmount(tester, tab);
        }
      },
    );
  }

  domainLoopTest(
    'MODEL original owner ABA at provisional Memory update rolls back edit AND encrypted journal',
    (tester, f) async {
      await _seed(tester, f);
      final tab = await _mount(tester, f);
      try {
        final before = await _row(tester, f);
        f.script(
          f.screen.core.call('astoria_memory_entry_text_revise', _arguments()),
        );
        await f.start(tester);
        var changed = false;
        f.screen.core.native.sql.afterWrite = (statement) async {
          if (!changed &&
              statement.trimLeft().toLowerCase().startsWith(
                'update memory_book_rows',
              )) {
            changed = true;
            await f.screen.core.container
                .read(chatNativeOwnerRegistryProvider)
                .beforeSessionSelection();
          }
        };
        await f.apply(tester);
        final reply = await f.finish(tester);
        f.screen.core.native.sql.afterWrite = null;
        expect(changed, true);
        expect(await _row(tester, f), before);
        await _noJournal(tester, f);
        expect(reply.body, isNot(contains('изменение сохранено')));
        f.noEgress(reply.body);
      } finally {
        await _unmount(tester, tab);
      }
    },
  );

  domainLoopTest(
    'MODEL original composer Stop before Memory Apply grants no write',
    (tester, f) async {
      await _seed(tester, f);
      final tab = await _mount(tester, f);
      try {
        final before = await _row(tester, f);
        f.script(
          f.screen.core.call('astoria_memory_entry_text_revise', _arguments()),
        );
        await f.start(tester);
        final stopButton = find.byKey(
          const ValueKey('support_composer_stop_btn'),
          skipOffstage: false,
        );
        final stop = tester.widget<IconButton>(stopButton).onPressed!;
        final composer = tester.widget<SupportComposerBar>(
          find.byType(SupportComposerBar, skipOffstage: false),
        );
        expect(identical(stop, composer.onStop), true);
        final route = ModalRoute.of<void>(
          tester.element(
            find.byKey(const ValueKey('support_tool_confirmation_accept')),
          ),
        )!;
        await configurationAction(tester, stop);
        await tester.pump();
        await tester.pump(route.reverseTransitionDuration);
        await tester.pump(const Duration(microseconds: 1));
        final reply = await f.finish(tester);
        expect(reply.status, 'stopped');
        expect(await _row(tester, f), before);
        await _noJournal(tester, f);
        f.noEgress(reply.body);
      } finally {
        await _unmount(tester, tab);
      }
    },
  );

  for (final childOwner in [false, true]) {
    domainLoopTest(
      'NATIVE actual ${childOwner ? 'child' : 'root'} Memory origin refuses all other scope callers',
      (tester, f) async {
        await _seed(tester, f);
        f.screen.core.isolation.extraAllowed.add(_memoryOriginProbe);
        final tab = await _mount(
          tester,
          f,
          childScope: childOwner,
          expectOwner: !childOwner,
        );
        final root = f.screen.core.container;
        final origin = ProviderScope.containerOf(
          tester.element(find.byType(MemoryBooksTab, skipOffstage: false)),
          listen: false,
        );
        final sibling = ProviderContainer(
          parent: root,
          overrides: [_memoryOriginProbe.overrideWith(_captureOriginalMemory)],
        );
        final child = ProviderContainer(
          parent: root,
          overrides: [_memoryOriginProbe.overrideWith(_captureOriginalMemory)],
        );
        try {
          final registry = root.read(memoryNativeEntryOwnerRegistryProvider);
          expect(
            sibling.read(memoryNativeEntryOwnerRegistryProvider),
            same(registry),
          );
          expect(
            child.read(memoryNativeEntryOwnerRegistryProvider),
            same(registry),
          );
          final original = registry.existing(
            DomainLoopFixture.session,
            originContainer: origin,
          )!;
          expect(original.originContainer, same(origin));
          expect(origin.read(_memoryOriginProbe), same(original));
          for (final caller in [sibling, child, if (childOwner) root]) {
            expect(caller.read(_memoryOriginProbe), isNull);
            expect(
              registry.existing(
                DomainLoopFixture.session,
                originContainer: caller,
              ),
              isNull,
            );
          }
          expect(original.current, true); // Foreign lookups do not retire A.
          if (childOwner) {
            final before = await _row(tester, f);
            final reads = f.screen.core.native.sql.observations.length;
            f.script(
              f.screen.core.call(
                'astoria_memory_entry_text_revise',
                _arguments(),
              ),
              next: (_) {
                expect(f.lastResult()['code'], 'unavailable');
                return f.screen.core.answer('Different original Memory scope.');
              },
            );
            await f.start(tester, confirmation: false);
            final reply = await f.finish(tester);
            expect(
              f.screen.core.native.sql.observations
                  .skip(reads)
                  .any(
                    (read) =>
                        read.statement.contains('SELECT e.key AS entry_index'),
                  ),
              false,
            );
            expect(await _row(tester, f), before);
            await _noJournal(tester, f);
            f.noEgress(reply.body);
          }
        } finally {
          child.dispose();
          sibling.dispose();
          await _unmount(tester, tab);
        }
      },
    );
  }

  for (final bound in ['entryApply', 'entryUndo', 'bookApply', 'bookUndo']) {
    domainLoopTest(
      'MODEL serialized $bound room refuses before Memory write AND journal reservation',
      (tester, f) async {
        await _seed(tester, f);
        await _nearLimit(tester, f, bound);
        final tab = await _mount(tester, f);
        try {
          final before = await _row(tester, f);
          f.script(
            f.screen.core.call(
              'astoria_memory_entry_text_revise',
              _arguments(),
            ),
          );
          await f.start(tester);
          final writes = f.screen.core.native.sql.writes.length;
          await f.apply(tester);
          final reply = await f.finish(tester);
          expect(reply.body, isNot(contains('изменение сохранено')));
          expect(await _row(tester, f), before);
          await _noJournal(tester, f);
          expect(
            f.screen.core.native.sql.writes
                .skip(writes)
                .any(
                  (sql) =>
                      sql.toLowerCase().contains('update memory_book_rows') ||
                      sql.toLowerCase().contains(
                        'into "support_mutation_journal"',
                      ) ||
                      sql.toLowerCase().contains(
                        'into support_mutation_journal',
                      ),
                ),
            false,
          );
          f.noEgress(reply.body);
        } finally {
          await _unmount(tester, tab);
        }
      },
    );
  }

  for (final side in ['before', 'after']) {
    for (final encoding in ['ascii', 'multibyte', 'escaping']) {
      domainLoopTest(
        'NATIVE $side $encoding evidence overflow refuses before journal AND entry write',
        (tester, f) async {
          final oversized = switch (encoding) {
            'ascii' => List.filled(8192, 'a').join(),
            'multibyte' => List.filled(4096, 'Ж').join(),
            _ => List.filled(4096, '"').join(),
          };
          final contentBefore = side == 'before' ? oversized : _before;
          final contentAfter = side == 'after' ? oversized : _after;
          await _seed(tester, f, content: contentBefore);
          final tab = await _mount(tester, f);
          try {
            _nonEgressControls(f);
            final before = await _row(tester, f);
            final entries = jsonDecode(before.entriesJson) as List;
            final original = MemoryEntry.fromJson(
              Map<String, dynamic>.from(entries.first as Map),
            );
            final next = MemoryEntryRevisions.prepare(
              original.copyWith(content: contentAfter),
              original,
              author: 'user',
              reviewer: 'user',
              reason: 'assistant_text_edit',
            );
            int evidenceBytes(MemoryEntry entry) => utf8
                .encode(
                  jsonEncode({
                    'v': 1,
                    'session': DomainLoopFixture.session,
                    'entry': entry.id,
                    'revision': entry.activeRevisionId,
                    'content': entry.content,
                  }),
                )
                .length;
            expect(original.content.length, lessThanOrEqualTo(8192));
            expect(next.content.length, lessThanOrEqualTo(8192));
            expect(
              utf8.encode(jsonEncode(entries.first)).length,
              lessThanOrEqualTo(131072),
            );
            expect(
              utf8.encode(before.entriesJson).length,
              lessThanOrEqualTo(524288),
            );
            expect(
              evidenceBytes(side == 'before' ? original : next),
              greaterThan(SupportMutationEvidence.maxNativeBytes),
            );
            expect(
              evidenceBytes(side == 'before' ? next : original),
              lessThanOrEqualTo(SupportMutationEvidence.maxNativeBytes),
            );
            // Long text exceeds the unchanged public metadata-preview limit.
            // Exercise the real original native owner, not an enlarged preview
            // policy, synthetic receipt/controller or replacement adapter.
            final c = f.screen.core.container;
            final owner = c
                .read(memoryNativeEntryOwnerRegistryProvider)
                .existing(DomainLoopFixture.session, originContainer: c)!;
            final chatOwners = c.read(chatNativeOwnerRegistryProvider);
            final chat = chatOwners.existing(DomainLoopFixture.session)!;
            final mutations = c.read(chatSourceMutationRegistryProvider);
            final checkpoint = mutations.sessionCheckpoint(
              DomainLoopFixture.session,
            );
            final nativeGuard = owner.captureNativeGuard();
            bool current() =>
                nativeGuard() &&
                chatOwners.retains(chat, DomainLoopFixture.session) &&
                !mutations.isSessionPending(DomainLoopFixture.session) &&
                identical(
                  mutations.sessionCheckpoint(DomainLoopFixture.session),
                  checkpoint,
                );
            final revision = owner.queue.revision;
            final cacheBefore = owner.cached(_entry);
            final writes = f.screen.core.native.sql.writes.length;
            final observed = await configurationAction(
              tester,
              () => owner.observe(_entry, current),
            );
            expect(observed, isNotNull);
            expect(observed!.entry, original);
            expect(current(), true);
            final refused = await configurationAction(
              tester,
              () => owner.revise(
                observed: observed,
                queueRevision: revision,
                content: contentAfter,
                support: f.screen.core.native.repo,
                parentSession: f.screen.core.native.session,
                operationId: 'oversized-memory-evidence',
                sourceCurrent: current,
              ),
            );
            // Null is the port's defined no-effect refusal (mapped to conflict),
            // not a thrown MemoryNativeEntryStorageException/storageUncertain.
            expect(refused, isNull);
            expect(observed.current, false);
            expect(current(), true);
            expect(owner.queue.revision, revision + 2);
            expect(owner.cached(_entry), same(cacheBefore));
            expect(await _row(tester, f), before);
            await _noJournal(tester, f);
            f.script(
              f.screen.core.call('astoria_memory_entry_text_receipts', {}),
              next: (_) {
                final result = f.lastResult();
                expect(result['code'], 'completed');
                expect(result['code'], isNot('storageUncertain'));
                expect(result['effect'], 'none');
                expect((result['data'] as Map)['records'], isEmpty);
                return f.screen.core.answer(
                  'No native Memory receipt was granted.',
                );
              },
            );
            await f.start(tester, confirmation: false);
            final reply = await f.finish(tester);
            expect(reply.body, isNot(contains('изменение сохранено')));
            expect(await _row(tester, f), before);
            await _noJournal(tester, f);
            expect(
              f.screen.core.native.sql.writes.skip(writes).any((sql) {
                final statement = sql.toLowerCase();
                return statement.contains('memory_book_rows') ||
                    statement.contains('support_mutation_journal');
              }),
              false,
            );
            f.noEgress(reply.body);
            _nonEgressControls(f);
          } finally {
            await _unmount(tester, tab);
          }
        },
      );
    }
  }

  for (final undo in [false, true]) {
    for (final fault in [
      'journalReserve',
      'journalSettle',
      'entryWrite',
      'commitSend',
      'commitDelivery',
    ]) {
      domainLoopTest(
        'MODEL exact Memory ${undo ? 'Undo' : 'Apply'} $fault fault does not invent success or retry authority',
        (tester, f) async {
          await _seed(tester, f);
          final tab = await _mount(tester, f);
          final sql = f.screen.core.native.sql;
          try {
            final owner = f.screen.core.container
                .read(memoryNativeEntryOwnerRegistryProvider)
                .existing(
                  DomainLoopFixture.session,
                  originContainer: f.screen.core.container,
                )!;
            if (undo) {
              f.script(
                f.screen.core.call(
                  'astoria_memory_entry_text_revise',
                  _arguments(),
                ),
              );
              await f.start(tester);
              await f.apply(tester);
              expect(
                (await f.finish(tester)).body,
                contains('изменение сохранено'),
              );
              f.script(
                f.screen.core.call('astoria_memory_entry_text_receipts', {}),
                next: (_) {
                  final records = f.lastData()['records'] as List;
                  expect(records, hasLength(1));
                  return f.screen.core.call(
                    'astoria_memory_entry_text_undo',
                    {'receipt': (records.single as Map)['receipt']},
                    id: 'faulted_genuine_memory_undo',
                  );
                },
              );
            } else {
              f.script(
                f.screen.core.call(
                  'astoria_memory_entry_text_revise',
                  _arguments(),
                ),
              );
            }
            final before = await _row(tester, f);
            final cacheBefore = owner.cached(_entry);
            final journalBefore = await configurationAction(
              tester,
              () => f.screen.core.native.db
                  .select(f.screen.core.native.db.supportMutationJournal)
                  .get(),
            );
            await f.start(tester);
            var faults = 0;
            var memoryWritten = false;
            Future<void> fail() async {
              faults++;
              throw StateError(DomainLoopFixture.private);
            }

            sql.afterWrite = (statement) async {
              final s = statement.trimLeft().toLowerCase();
              final memory = s.startsWith('update memory_book_rows');
              if (memory) memoryWritten = true;
              final journal = s.contains('support_mutation_journal');
              final reserve =
                  journal &&
                  !memoryWritten &&
                  s.startsWith(undo ? 'update' : 'insert');
              final settle = journal && memoryWritten && s.startsWith('update');
              if (faults == 0 &&
                  ((fault == 'entryWrite' && memory) ||
                      (fault == 'journalReserve' && reserve) ||
                      (fault == 'journalSettle' && settle)))
                await fail();
            };
            Future<void> failCommit() async {
              if (memoryWritten && faults == 0) await fail();
            }

            if (fault == 'commitSend') sql.beforeOuterSend = failCommit;
            if (fault == 'commitDelivery') sql.afterOuterSend = failCommit;
            await f.apply(tester);
            final reply = await f.finish(tester);
            sql.afterWrite = null;
            sql.beforeOuterSend = null;
            sql.afterOuterSend = null;
            expect(faults, 1);
            expect(reply.body, isNot(contains('изменение сохранено')));
            expect(owner.cached(_entry), same(cacheBefore));
            final after = await _row(tester, f);
            if (fault == 'commitDelivery') {
              expect(
                (jsonDecode(after.entriesJson) as List).first['content'],
                undo ? _before : _after,
              );
              _preserved(before, after);
              final journal = await configurationAction(
                tester,
                () => f.screen.core.native.db
                    .select(f.screen.core.native.db.supportMutationJournal)
                    .get(),
              );
              expect(journal.single.status, undo ? 'undone' : 'applied');
            } else {
              expect(after, before);
              final journal = await configurationAction(
                tester,
                () => f.screen.core.native.db
                    .select(f.screen.core.native.db.supportMutationJournal)
                    .get(),
              );
              expect(journal, journalBefore);
            }
            f.script(
              f.screen.core.call('astoria_memory_entry_text_receipts', {}),
              next: (_) {
                expect(f.lastData()['records'], isEmpty);
                return f.screen.core.answer(
                  'No genuine returned Memory receipt.',
                );
              },
            );
            await f.start(tester, confirmation: false);
            final retained = await f.finish(tester);
            expect(await _row(tester, f), after);
            expect(faults, 1);
            f.noEgress('${reply.body}${retained.body}');
          } finally {
            sql.afterWrite = null;
            sql.beforeOuterSend = null;
            sql.afterOuterSend = null;
            await _unmount(tester, tab);
          }
        },
      );
    }
  }

  for (final undo in [false, true]) {
    domainLoopTest(
      'MODEL Memory ${undo ? 'Undo' : 'Apply'} publication loss AFTER actual commit retains joint durable fact, not Undo authority',
      (tester, f) async {
        await _seed(tester, f);
        final tab = await _mount(tester, f);
        final sql = f.screen.core.native.sql;
        try {
          final c = f.screen.core.container;
          final owner = c
              .read(memoryNativeEntryOwnerRegistryProvider)
              .existing(DomainLoopFixture.session, originContainer: c)!;
          _nonEgressControls(f);
          String? undoHandle;
          var appliedBody = '';
          if (undo) {
            f.script(
              f.screen.core.call(
                'astoria_memory_entry_text_revise',
                _arguments(),
              ),
            );
            await f.start(tester);
            await f.apply(tester);
            appliedBody = (await f.finish(tester)).body;
            expect(appliedBody, contains('изменение сохранено'));
            f.noEgress(appliedBody);
          }
          final before = await _row(tester, f);
          final cacheBefore = owner.cached(_entry);
          final historyBefore =
              ((jsonDecode(before.entriesJson) as List).first['revisions']
                      as List)
                  .toList();
          if (undo) {
            f.script(
              f.screen.core.call('astoria_memory_entry_text_receipts', {}),
              next: (_) {
                final records = f.lastData()['records'] as List;
                expect(records, hasLength(1));
                undoHandle = (records.single as Map)['receipt'] as String;
                return f.screen.core.call(
                  'astoria_memory_entry_text_undo',
                  {'receipt': undoHandle},
                  id: 'publication_lost_genuine_memory_undo',
                );
              },
            );
          } else {
            f.script(
              f.screen.core.call(
                'astoria_memory_entry_text_revise',
                _arguments(),
              ),
            );
          }
          await f.start(tester);
          var written = false;
          var lost = 0;
          sql.afterWrite = (statement) async {
            if (statement.trimLeft().toLowerCase().startsWith(
              'update memory_book_rows',
            ))
              written = true;
          };
          sql.afterOuterSend = () async {
            if (written && lost == 0) {
              lost++;
              c
                  .read(chatNativeOwnerRegistryProvider)
                  .existing(DomainLoopFixture.session)!
                  .queue
                  .beginPublication();
            }
          };
          final postsBeforeApply = f.screen.core.wire.length;
          await f.apply(tester);
          final reply = await f.finish(tester);
          sql.afterWrite = null;
          sql.afterOuterSend = null;
          expect(lost, 1);
          expect(owner.cached(_entry), same(cacheBefore));
          expect(owner.cached(_entry)!.content, undo ? _after : _before);
          final after = await _row(tester, f);
          final rawAfter = (jsonDecode(after.entriesJson) as List).first as Map;
          expect(rawAfter['content'], undo ? _before : _after);
          final historyAfter = rawAfter['revisions'] as List;
          expect(
            historyAfter.take(historyBefore.length).toList(),
            historyBefore,
          );
          expect(historyAfter.length, historyBefore.length + 1);
          expect(
            (historyAfter.last as Map)['reason'],
            undo ? 'assistant_text_undo' : 'assistant_text_edit',
          );
          _preserved(before, after);
          final journal = await configurationAction(
            tester,
            () => f.screen.core.native.db
                .select(f.screen.core.native.db.supportMutationJournal)
                .get(),
          );
          expect(journal.single.status, undo ? 'undone' : 'applied');
          expect(reply.body, contains('изменение сохранено'));
          // Retirement prevents another provider POST; lastResult would read a
          // previous read receipt (Undo) or have no tool message at all (Apply).
          // The original native receipt is settled into the durable answer.
          final name = undo
              ? 'astoria_memory_entry_text_undo'
              : 'astoria_memory_entry_text_revise';
          expect(
            reply.body,
            contains(
              '$name: cancelled; изменение сохранено; '
              'обновление нативных представлений ожидается',
            ),
          );
          expect(reply.status, 'stopped');
          expect(reply.body, isNot(contains('storageUncertain')));
          expect(f.screen.core.wire.length, postsBeforeApply);
          f.noEgress('$appliedBody${reply.body}');
          _nonEgressControls(f);
          final writes = sql.writes.length;
          f.script(
            f.screen.core.call('astoria_memory_entry_text_receipts', {}),
            next: (round) {
              if (round == 2) {
                expect(f.lastData()['records'], isEmpty);
                if (undo) {
                  expect(undoHandle, isNotNull);
                  return f.screen.core.call(
                    'astoria_memory_entry_text_undo',
                    {'receipt': undoHandle},
                    id: 'retry_retired_publication_memory_undo',
                  );
                }
              } else {
                expect(f.lastResult()['code'], 'unavailable');
                expect(f.lastResult()['effect'], 'none');
              }
              return f.screen.core.answer(
                'Original publication retired; no current Undo.',
              );
            },
          );
          await f.start(tester, confirmation: false);
          final retained = await f.finish(tester);
          expect(await _row(tester, f), after);
          final journalAfterRetry = await configurationAction(
            tester,
            () => f.screen.core.native.db
                .select(f.screen.core.native.db.supportMutationJournal)
                .get(),
          );
          expect(journalAfterRetry, journal);
          expect(owner.cached(_entry), same(cacheBefore));
          expect(lost, 1);
          expect(
            sql.writes.skip(writes).any((statement) {
              final s = statement.toLowerCase();
              return s.contains('memory_book_rows') ||
                  s.contains('support_mutation_journal');
            }),
            false,
          );
          f.noEgress('$appliedBody${reply.body}${retained.body}');
          _nonEgressControls(f);
        } finally {
          sql.afterWrite = null;
          sql.afterOuterSend = null;
          await _unmount(tester, tab);
        }
      },
    );
  }

  for (final mode in ['noOwner', 'vectorEnabled', 'invalidHistory']) {
    domainLoopTest(
      'MODEL Memory text $mode refuses instead of inventing an owner or reindex',
      (tester, f) async {
        await _seed(
          tester,
          f,
          vector: mode == 'vectorEnabled',
          invalidHistory: mode == 'invalidHistory',
        );
        final tab = mode == 'noOwner'
            ? null
            : await _mount(tester, f, expectOwner: mode != 'vectorEnabled');
        try {
          final before = await _row(tester, f);
          f.script(
            f.screen.core.call(
              'astoria_memory_entry_text_revise',
              _arguments(),
            ),
            next: (_) {
              expect(f.lastResult()['code'], 'unavailable');
              return f.screen.core.answer(
                'The original Memory operation is unavailable.',
              );
            },
          );
          await f.start(tester, confirmation: false);
          final reply = await f.finish(tester);
          expect(await _row(tester, f), before);
          await _noJournal(tester, f);
          if (mode == 'noOwner')
            expect(
              f.screen.core.container
                  .read(memoryNativeEntryOwnerRegistryProvider)
                  .existing(
                    DomainLoopFixture.session,
                    originContainer: f.screen.core.container,
                  ),
              isNull,
            );
          f.noEgress(reply.body);
        } finally {
          if (tab != null) await _unmount(tester, tab);
        }
      },
    );
  }
}

Map<String, Object?> _arguments() => {
  'sessionId': DomainLoopFixture.session,
  'entryId': _entry,
  'content': _after,
};

/// Negative controls for the SAME assertion before and after the real action.
/// They never send canaries, clear tripwire records, or admit a private provider.
void _nonEgressControls(DomainLoopFixture f) {
  for (final canary in [
    DomainLoopFixture.private,
    f.screen.core.boundSyntheticSecret,
    'SYNTHETIC_HIDDEN_PROMPT',
    'SYNTHETIC_EXCLUDED_BODY',
  ]) {
    expect(() => f.noEgress(canary), throwsA(isA<TestFailure>()));
  }
  f.noEgress();
}

Future<void> _nearLimit(
  WidgetTester tester,
  DomainLoopFixture f,
  String bound,
) => configurationAction(tester, () async {
  final db = f.screen.core.native.db;
  final query = db.select(db.memoryBookRows)
    ..where((t) => t.sessionId.equals(DomainLoopFixture.session));
  final row = await query.getSingle();
  final entries = jsonDecode(row.entriesJson) as List;
  final original = entries.first as Map<String, dynamic>;
  final stored = MemoryEntry.fromJson(original);
  final applied = MemoryEntryRevisions.prepare(
    stored.copyWith(content: _after),
    stored,
    author: 'user',
    reviewer: 'user',
    reason: 'assistant_text_edit',
  );
  final undone = MemoryEntryRevisions.prepare(
    applied.copyWith(content: _before),
    applied,
    author: 'user',
    reviewer: 'user',
    reason: 'assistant_text_undo',
  );
  Map<String, dynamic> raw(MemoryEntry next) => {
    ...original,
    'content': next.content,
    'activeRevisionId': next.activeRevisionId,
    'revisions': [
      ...original['revisions'] as List,
      ...next.revisions.skip(stored.revisions.length).map((r) => r.toJson()),
    ],
  };
  final appliedRaw = raw(applied), undoneRaw = raw(undone);
  final book = bound.startsWith('book');
  final undoOnly = bound.endsWith('Undo');
  final limit = book ? 524288 : 131072;
  int size(Map<String, dynamic> target) => utf8
      .encode(jsonEncode(book ? [target, ...entries.skip(1)] : target))
      .length;
  final padded = book ? entries[1] as Map<String, dynamic> : original;
  padded['serializedRoomPadding'] = '';
  if (!book) {
    appliedRaw['serializedRoomPadding'] = '';
    undoneRaw['serializedRoomPadding'] = '';
  }
  final needed = limit - size(appliedRaw) + (undoOnly ? -32 : 32);
  expect(needed, greaterThan(0));
  // Multibyte payload keeps these regressions about serialized UTF-8 bytes,
  // not Dart character counts or history length alone.
  final padding =
      '${List.filled(needed ~/ 2, 'Ж').join()}${needed.isOdd ? 'x' : ''}';
  padded['serializedRoomPadding'] = padding;
  if (!book) {
    appliedRaw['serializedRoomPadding'] = padding;
    undoneRaw['serializedRoomPadding'] = padding;
  }
  expect(size(original), lessThanOrEqualTo(limit));
  expect(utf8.encode(jsonEncode(original)).length, lessThanOrEqualTo(131072));
  expect(utf8.encode(jsonEncode(entries)).length, lessThanOrEqualTo(524288));
  expect(applied.revisions.length, lessThan(31));
  expect(size(appliedRaw), undoOnly ? lessThan(limit) : greaterThan(limit));
  expect(size(undoneRaw), greaterThan(limit));
  await (db.update(db.memoryBookRows)
        ..where((t) => t.sessionId.equals(DomainLoopFixture.session)))
      .write(MemoryBookRowsCompanion(entriesJson: Value(jsonEncode(entries))));
});

Future<void> _seed(
  WidgetTester tester,
  DomainLoopFixture f, {
  bool vector = false,
  bool invalidHistory = false,
  String content = _before,
}) => configurationAction(tester, () async {
  final c = f.screen.core.container, db = f.screen.core.native.db;
  final session = (await c
      .read(chatRepoProvider)
      .getById(DomainLoopFixture.session))!;
  final manifest = MemorySourceManifest.capture(
    session.id,
    [session.messages.first],
    [session.messages.first.id],
  );
  await c
      .read(memoryBookRepoProvider)
      .put(
        MemoryBook(
          id: 'memorybook_${session.id}',
          sessionId: session.id,
          settings: MemoryBookSettings(
            vectorSearchEnabled: vector,
            autoCreateEnabled: false,
            autoGenerateEnabled: false,
          ),
          entries: [
            MemoryEntry(
              id: _entry,
              title: 'Approved native entry',
              content: content,
              keys: const ['retained-key'],
              messageIds: [session.messages.first.id],
              sourceManifest: manifest,
            ),
            const MemoryEntry(
              id: 'unrelated-memory',
              title: 'Unrelated',
              content: 'Never replace this entry.',
            ),
          ],
          pendingDrafts: const [
            MemoryDraft(
              id: 'unrelated-draft',
              content: 'Unapproved; do not change.',
            ),
          ],
          lastProcessedMessageCount: 9,
        ),
      );
  final row = await (db.select(
    db.memoryBookRows,
  )..where((t) => t.sessionId.equals(session.id))).getSingle();
  final entries = jsonDecode(row.entriesJson) as List;
  final target = entries.first as Map<String, dynamic>;
  target['unknownEntry'] = {'preserve': 'synthetic native-only field'};
  ((target['revisions'] as List).first as Map)['unknownRevision'] = 'immutable';
  if (invalidHistory) target['activeRevisionId'] = 'not-the-last-revision';
  final settings = jsonDecode(row.settingsJson) as Map<String, dynamic>;
  settings['unknownSetting'] = {'preserve': true};
  await (db.update(
    db.memoryBookRows,
  )..where((t) => t.sessionId.equals(session.id))).write(
    MemoryBookRowsCompanion(
      entriesJson: Value(jsonEncode(entries)),
      settingsJson: Value(jsonEncode(settings)),
    ),
  );
});

/// Actual native MemoryBooksTab creates, loads and disposes its ORIGINAL widget-
/// local controller. Offstage only keeps Send accessible in the existing host;
/// it is not a synthetic owner/controller/receipt or a replacement authority graph.
Future<OverlayEntry> _mount(
  WidgetTester tester,
  DomainLoopFixture f, {
  bool expectOwner = true,
  bool childScope = false,
}) async {
  f.screen.core.isolation.extraAllowed.addAll({
    memoryBookOpsProvider,
    memoryDraftJobsProvider,
    memoryGlobalSettingsProvider,
    pipelineSettingsProvider,
    embeddingRepoProvider,
    vectorSearchAvailableProvider,
  });
  final context = tester.element(find.byType(SupportAssistantScreen));
  final overlay = OverlayEntry(
    builder: (_) => Offstage(
      child: Material(
        child: SizedBox(
          width: 800,
          height: 600,
          child: childScope
              ? ProviderScope(
                  overrides: [
                    vectorSearchAvailableProvider.overrideWithValue(false),
                    _memoryOriginProbe.overrideWith(_captureOriginalMemory),
                  ],
                  child: const MemoryBooksTab(
                    sessionId: DomainLoopFixture.session,
                    charId: DomainLoopFixture.character,
                  ),
                )
              : const MemoryBooksTab(
                  sessionId: DomainLoopFixture.session,
                  charId: DomainLoopFixture.character,
                ),
        ),
      ),
    ),
  );
  Overlay.of(context).insert(overlay);
  await tester.pump();
  for (var turn = 0; turn < 128; turn++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    final cards = find.descendant(
      of: find.byType(MemoryBooksTab, skipOffstage: false),
      matching: find.byType(ListView, skipOffstage: false),
    );
    if (cards.evaluate().isNotEmpty) break;
  }
  expect(find.byType(MemoryBooksTab, skipOffstage: false), findsOneWidget);
  expect(
    find.descendant(
      of: find.byType(MemoryBooksTab, skipOffstage: false),
      matching: find.byType(ListView, skipOffstage: false),
    ),
    findsOneWidget,
  );
  if (expectOwner)
    expect(
      f.screen.core.container
          .read(memoryNativeEntryOwnerRegistryProvider)
          .existing(
            DomainLoopFixture.session,
            originContainer: f.screen.core.container,
          ),
      isNotNull,
    );
  return overlay;
}

Future<void> _unmount(WidgetTester tester, OverlayEntry tab) async {
  tab.remove();
  await tester.pump();
  tab.dispose();
}

Future<MemoryBookRow> _row(WidgetTester tester, DomainLoopFixture f) =>
    configurationAction(
      tester,
      () =>
          (f.screen.core.native.db.select(
                f.screen.core.native.db.memoryBookRows,
              )..where((t) => t.sessionId.equals(DomainLoopFixture.session)))
              .getSingle(),
    );

Future<void> _noJournal(WidgetTester tester, DomainLoopFixture f) async {
  expect(
    await configurationAction(
      tester,
      () => f.screen.core.native.db
          .select(f.screen.core.native.db.supportMutationJournal)
          .get(),
    ),
    isEmpty,
  );
}

void _preserved(MemoryBookRow before, MemoryBookRow after) {
  expect(after.settingsJson, before.settingsJson);
  expect(after.pendingDraftsJson, before.pendingDraftsJson);
  expect(after.lastProcessedMessageCount, before.lastProcessedMessageCount);
  final a = jsonDecode(before.entriesJson) as List,
      b = jsonDecode(after.entriesJson) as List;
  expect(b.skip(1).toList(), a.skip(1).toList());
  final original = Map<String, dynamic>.from(a.first as Map);
  final changed = Map<String, dynamic>.from(b.first as Map);
  for (final key in ['content', 'activeRevisionId', 'revisions']) {
    original.remove(key);
    changed.remove(key);
  }
  expect(changed, original);
}
