import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/chat_source_mutation_provider.dart';
import 'package:glaze_flutter/core/state/character_provider.dart'
    show revealHiddenCharactersProvider;
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/state/chat_native_owner_registry.dart';
import 'package:glaze_flutter/features/chat_history/chat_history_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_composer_bar.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';

import 'support_app_domain_loop_fixture.dart';

void main() {
  domainLoopTest(
    'MODEL unselected session title cannot bootstrap a replacement owner',
    (tester, f) async {
      final core = f.screen.core, c = core.container;
      const unselected = 'domain-character_1';
      await configurationAction(
        tester,
        () => c
            .read(chatRepoProvider)
            .put(
              const ChatSession(
                id: unselected,
                characterId: DomainLoopFixture.character,
                sessionIndex: 1,
              ),
            ),
      );
      final owners = c.read(chatNativeOwnerRegistryProvider);
      final original = owners.loaded.single;
      f.script(
        core.call('astoria_session_rename', {
          'sessionId': unselected,
          'title': 'No owner',
        }),
        next: (_) {
          final result = f.lastResult();
          expect(result['code'], 'unavailable');
          expect(result['effect'], 'none');
          return core.answer(
            'The unselected session has no original idle owner.',
          );
        },
      );
      await f.start(tester, confirmation: false);
      final reply = await f.finish(tester);
      expect(owners.loaded.single, same(original));
      expect(original.sessionId(), DomainLoopFixture.session);
      expect(
        (await configurationAction(
          tester,
          () => c.read(chatRepoProvider).getById(unselected),
        ))!.sessionVars,
        isEmpty,
      );
      expect(
        await configurationAction(
          tester,
          () => core.native.db
              .select(core.native.db.supportMutationJournal)
              .get(),
        ),
        isEmpty,
      );
      f.noEgress(reply.body);
    },
  );

  for (final kind in ['absent', 'nullValue', 'empty', 'text']) {
    domainLoopTest(
      'MODEL title-only rename and fresh Undo preserve exact $kind title',
      (tester, f) async {
        final core = f.screen.core, c = core.container, db = core.native.db;
        final initial = <String, Object?>{
          'unrelated': 'Original variable',
          if (kind != 'absent')
            'sessionName': kind == 'nullValue'
                ? null
                : kind == 'empty'
                ? ''
                : 'Original title',
        };
        final before = await configurationAction(tester, () async {
          await (db.update(
            db.chatSessions,
          )..where((t) => t.sessionId.equals(DomainLoopFixture.session))).write(
            ChatSessionsCompanion(sessionVarsJson: Value(jsonEncode(initial))),
          );
          return (db.select(db.chatSessions)
                ..where((t) => t.sessionId.equals(DomainLoopFixture.session)))
              .getSingle();
        });
        final owners = c.read(chatNativeOwnerRegistryProvider);
        final original = owners.existing(DomainLoopFixture.session)!;
        f.script(
          core.call('astoria_session_rename', {
            'sessionId': DomainLoopFixture.session,
            'title': 'Exact supplied title',
          }),
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
        expect(
          preview,
          contains(
            '"beforeKind":"${kind == 'empty' || kind == 'text' ? 'text' : kind}"',
          ),
        );
        expect(preview, contains('"afterTitle":"Exact supplied title"'));
        // Preserve a legal unrelated edit AFTER original ROOT release and before
        // title CAS. A pre-ROOT source-stamp change is separately refused below;
        // never weaken immutable ROOT admission to make this positive case pass.
        var variableEdited = false;
        core.native.sql.afterSelect = (statement, _) async {
          if (!variableEdited &&
              statement.trimLeft().startsWith(
                'SELECT character_id, session_index,',
              )) {
            variableEdited = true;
            await c
                .read(chatRepoProvider)
                .updateSessionVarsJson(
                  DomainLoopFixture.session,
                  (vars) => {...vars, 'unrelated': 'Latest variable'},
                );
          }
        };
        final retainedApply = tester
            .widget<GlazeActionButton>(
              find.byKey(const ValueKey('support_tool_confirmation_accept')),
            )
            .onTap!;
        await f.apply(tester);
        final renamed = await f.finish(tester);
        core.native.sql.afterSelect = null;
        expect(variableEdited, true, reason: renamed.body);
        expect(renamed.status, 'stopped', reason: renamed.body);
        expect(renamed.body, contains('изменение сохранено'));
        expect(core.wire, hasLength(1));
        expect(owners.existing(DomainLoopFixture.session), same(original));
        final loaded = c.read(chatProvider(DomainLoopFixture.character)).value!;
        expect(
          loaded.session!.sessionVars['sessionName'],
          'Exact supplied title',
        );
        expect(loaded.session!.sessionVars['unrelated'], 'Latest variable');
        await configurationAction(tester, retainedApply);
        expect(core.wire, hasLength(1));
        final journal = await configurationAction(
          tester,
          () => db.select(db.supportMutationJournal).get(),
        );
        expect(journal.single.domain, 'session.title');
        expect(journal.single.status, 'applied');
        expect(journal.single.beforeCiphertext, isNotEmpty);
        expect(
          journal.single.beforeCiphertext,
          isNot(contains('Original title')),
        );
        expect(
          journal.single.afterCiphertext,
          isNot(contains('Exact supplied title')),
        );

        f.script(
          core.call('astoria_session_title_receipts', {}),
          next: (_) {
            final records = (f.lastData()['records'] as List)
                .cast<Map<dynamic, dynamic>>();
            expect(records, hasLength(1));
            return core.call('astoria_session_rename_undo', {
              'receipt': records.single['receipt'],
            }, id: 'fresh_title_undo');
          },
        );
        await f.start(tester);
        await f.apply(tester);
        final undone = await f.finish(tester);
        expect(undone.body, contains('изменение сохранено'));
        expect(core.wire, hasLength(3));
        final after = await configurationAction(
          tester,
          () =>
              (db.select(db.chatSessions)..where(
                    (t) => t.sessionId.equals(DomainLoopFixture.session),
                  ))
                  .getSingle(),
        );
        expect(
          after.copyWith(sessionVarsJson: Value(before.sessionVarsJson)),
          before,
        );
        final restored = jsonDecode(after.sessionVarsJson!) as Map;
        expect(
          restored.containsKey('sessionName'),
          initial.containsKey('sessionName'),
        );
        expect(restored['sessionName'], initial['sessionName']);
        expect(restored['unrelated'], 'Latest variable');
        expect(
          (await configurationAction(
            tester,
            () => db.select(db.supportMutationJournal).get(),
          )).single.status,
          'undone',
        );
        expect(owners.existing(DomainLoopFixture.session), same(original));
        expect(
          c
              .read(chatProvider(DomainLoopFixture.character))
              .value!
              .session!
              .sessionVars['sessionName'],
          initial['sessionName'],
        );
        if (kind == 'nullValue') {
          // Immediate null Undo is not enough: ordinary typed mutations and
          // both clear modes must preserve that exact raw title afterwards.
          core.isolation.extraAllowed.add(sessionDeletionRepoProvider);
          await configurationAction(tester, () async {
            final chats = c.read(chatRepoProvider);
            await chats.mutateMessage(
              sessionId: DomainLoopFixture.session,
              messageId: 'domain-message-1',
              mutate: (message) => message.copyWith(content: 'Ordinary edit'),
              updatedAt: before.updatedAt,
            );
            var raw =
                await (db.select(db.chatSessions)..where(
                      (t) => t.sessionId.equals(DomainLoopFixture.session),
                    ))
                    .getSingle();
            expect(raw.sessionVarsJson, after.sessionVarsJson);
            await chats.mutateSession(
              sessionId: DomainLoopFixture.session,
              mutate: (session) => session.copyWith(
                sessionVars: {
                  ...session.sessionVars,
                  'explicitDelta': 'kept',
                  'branchedAt': '7',
                },
              ),
            );
            final deletion = c.read(sessionDeletionRepoProvider);
            final cleared = await deletion.clearSession(
              sessionId: DomainLoopFixture.session,
              replacementMessages: const [],
              resetBranchStamp: true,
              countDeletedMessages: true,
            );
            expect(cleared, isNotNull);
            expect(cleared!.sessionVars.containsKey('sessionName'), false);
            raw =
                await (db.select(db.chatSessions)..where(
                      (t) => t.sessionId.equals(DomainLoopFixture.session),
                    ))
                    .getSingle();
            final vars = jsonDecode(raw.sessionVarsJson!) as Map;
            expect(vars.containsKey('sessionName'), true);
            expect(vars['sessionName'], isNull);
            expect(vars['unrelated'], 'Latest variable');
            expect(vars['explicitDelta'], 'kept');
            expect(vars.containsKey('branchedAt'), false);
            expect(vars[ChatSessionX.deletedMessagesVarKey], '3');
            await deletion.clearSession(
              sessionId: DomainLoopFixture.session,
              replacementMessages: const [],
            );
            final plainClear =
                await (db.select(db.chatSessions)..where(
                      (t) => t.sessionId.equals(DomainLoopFixture.session),
                    ))
                    .getSingle();
            expect(plainClear.sessionVarsJson, raw.sessionVarsJson);
          });
        }
        f.noEgress('${renamed.body}${undone.body}');
      },
    );
  }

  domainLoopTest('MODEL title CAS refuses a competing title after preview', (
    tester,
    f,
  ) async {
    final core = f.screen.core, c = core.container, db = core.native.db;
    f.script(
      core.call('astoria_session_rename', {
        'sessionId': DomainLoopFixture.session,
        'title': 'Stale title',
      }),
    );
    await f.start(tester);
    await configurationAction(
      tester,
      () => c
          .read(chatRepoProvider)
          .renameSession(
            sessionId: DomainLoopFixture.session,
            name: 'Competing title',
          ),
    );
    await f.apply(tester);
    final reply = await f.finish(tester);
    expect(reply.body, isNot(contains('изменение сохранено')));
    expect(
      (await configurationAction(
        tester,
        () => c.read(chatRepoProvider).getById(DomainLoopFixture.session),
      ))!.sessionVars['sessionName'],
      'Competing title',
    );
    expect(
      await configurationAction(
        tester,
        () => db.select(db.supportMutationJournal).get(),
      ),
      isEmpty,
    );
    expect(core.wire, hasLength(1));
    f.noEgress(reply.body);
  });

  domainLoopTest(
    'MODEL unrelated durable edit before title Apply cannot renew immutable original ROOT',
    (tester, f) async {
      final core = f.screen.core, c = core.container, db = core.native.db;
      f.script(
        core.call('astoria_session_rename', {
          'sessionId': DomainLoopFixture.session,
          'title': 'Must not cross changed ROOT',
        }),
      );
      await f.start(tester);
      await configurationAction(
        tester,
        () => c
            .read(chatRepoProvider)
            .updateSessionVarsJson(
              DomainLoopFixture.session,
              (vars) => {...vars, 'unrelated': 'Pre-ROOT edit'},
            ),
      );
      await f.apply(tester);
      final reply = await f.finish(tester);
      expect(reply.body, isNot(contains('изменение сохранено')));
      final durable = await configurationAction(
        tester,
        () => c.read(chatRepoProvider).getById(DomainLoopFixture.session),
      );
      expect(durable!.sessionVars.containsKey('sessionName'), false);
      expect(durable.sessionVars['unrelated'], 'Pre-ROOT edit');
      expect(
        await configurationAction(
          tester,
          () => db.select(db.supportMutationJournal).get(),
        ),
        isEmpty,
      );
      expect(core.wire, hasLength(1));
      f.noEgress(reply.body);
    },
  );

  domainLoopTest(
    'MODEL original owner ABA at provisional title write rolls back title and journal',
    (tester, f) async {
      final core = f.screen.core, c = core.container, db = core.native.db;
      f.script(
        core.call('astoria_session_rename', {
          'sessionId': DomainLoopFixture.session,
          'title': 'Must roll back',
        }),
      );
      await f.start(tester);
      var fenced = false;
      core.native.sql.afterWrite = (statement) async {
        if (!fenced &&
            statement.toLowerCase().startsWith('update chat_sessions')) {
          fenced = true;
          c.read(chatNativeOwnerRegistryProvider).beforeSessionSelection();
        }
      };
      await f.apply(tester);
      final reply = await f.finish(tester);
      core.native.sql.afterWrite = null;
      expect(fenced, true);
      expect(
        (await configurationAction(
          tester,
          () => c.read(chatRepoProvider).getById(DomainLoopFixture.session),
        ))!.sessionVars.containsKey('sessionName'),
        false,
      );
      expect(
        await configurationAction(
          tester,
          () => db.select(db.supportMutationJournal).get(),
        ),
        isEmpty,
      );
      expect(reply.body, isNot(contains('изменение сохранено')));
      expect(core.wire, hasLength(1));
      f.noEgress(reply.body);
    },
  );

  domainLoopTest(
    'MODEL title receipts cannot renew source ABA or reconstruct JSON authority',
    (tester, f) async {
      final core = f.screen.core, c = core.container;
      f.script(
        core.call('astoria_session_rename', {
          'sessionId': DomainLoopFixture.session,
          'title': 'Saved title',
        }),
      );
      await f.start(tester);
      await f.apply(tester);
      final renamed = await f.finish(tester);
      await configurationAction(tester, () async {
        final mutations = c.read(chatSourceMutationRegistryProvider);
        for (var i = 0; i < 2; i++) {
          final finish = mutations.beginMutation(
            sessionId: DomainLoopFixture.session,
          );
          finish(); // Same row value cannot renew the original receipt event.
        }
      });
      f.script(
        core.call('astoria_session_title_receipts', {}),
        next: (round) {
          final result = f.lastResult();
          if (round == 2) {
            expect((result['data'] as Map)['records'], isEmpty);
            return core.call('astoria_session_rename_undo', {
              'receipt': 'repair-${List.filled(32, 'a').join()}',
            }, id: 'guessed_title_undo');
          }
          expect(result['code'], 'unavailable');
          expect(result['effect'], 'none');
          return core.answer('No current retained title receipt.');
        },
      );
      await f.start(tester, confirmation: false);
      final reply = await f.finish(tester);
      expect(
        (await configurationAction(
          tester,
          () => c.read(chatRepoProvider).getById(DomainLoopFixture.session),
        ))!.sessionVars['sessionName'],
        'Saved title',
      );
      expect(core.wire, hasLength(4));
      f.noEgress('${renamed.body}${reply.body}');
    },
  );

  domainLoopTest(
    'MODEL actual original composer Stop before title Apply grants no write',
    (tester, f) async {
      final core = f.screen.core, c = core.container;
      f.script(
        core.call('astoria_session_rename', {
          'sessionId': DomainLoopFixture.session,
          'title': 'Stopped title',
        }),
      );
      await f.start(tester);
      final composer = find.byType(SupportComposerBar, skipOffstage: false);
      final stopButton = find.descendant(
        of: composer,
        matching: find.byKey(
          const ValueKey('support_composer_stop_btn'),
          skipOffstage: false,
        ),
        skipOffstage: false,
      );
      final stop = tester.widget<IconButton>(stopButton).onPressed;
      expect(stop, isNotNull);
      expect(
        identical(stop, tester.widget<SupportComposerBar>(composer).onStop),
        true,
      );
      final route = ModalRoute.of<void>(
        tester.element(
          find.byKey(const ValueKey('support_tool_confirmation_accept')),
        ),
      )!;
      await configurationAction(tester, stop!);
      // Stop cancels the actual token, which pops the original modal. Its
      // completed future waits for reverse-animation disposal in the fake zone.
      // Join only after those finite frames, never global busy-model idleness.
      await tester.pump();
      await tester.pump(route.reverseTransitionDuration);
      await tester.pump(const Duration(microseconds: 1));
      expect(route.isCurrent, false);
      final reply = await f.finish(tester);
      expect(reply.status, 'stopped');
      expect(
        (await configurationAction(
          tester,
          () => c.read(chatRepoProvider).getById(DomainLoopFixture.session),
        ))!.sessionVars.containsKey('sessionName'),
        false,
      );
      expect(core.wire, hasLength(1));
      f.noEgress(reply.body);
    },
  );

  domainLoopTest(
    'MODEL equal-title authoritative replacement retires genuine receipt despite later sync failure',
    (tester, f) async {
      final core = f.screen.core, c = core.container;
      f.script(
        core.call('astoria_session_rename', {
          'sessionId': DomainLoopFixture.session,
          'title': 'Saved title',
        }),
      );
      await f.start(tester);
      await f.apply(tester);
      final renamed = await f.finish(tester);
      expect(renamed.status, 'stopped', reason: renamed.body);
      await configurationAction(tester, () async {
        final chats = c.read(chatRepoProvider);
        final durable = (await chats.getById(DomainLoopFixture.session))!;
        final mutations = c.read(chatSourceMutationRegistryProvider);
        final original = mutations.sessionCheckpoint(durable.id);
        try {
          final replacement = chats.put(
            durable,
          ); // Direct cloud-store boundary.
          expect(
            identical(original, mutations.sessionCheckpoint(durable.id)),
            false,
          );
          expect(mutations.isSessionPending(durable.id), true);
          await replacement;
          throw const _SyntheticSyncFailure();
        } on _SyntheticSyncFailure {
          // Failure after the durable replacement cannot restore old authority.
        }
        expect(mutations.isSessionPending(durable.id), false);
        expect(
          identical(original, mutations.sessionCheckpoint(durable.id)),
          false,
        );
      });
      f.script(
        core.call('astoria_session_title_receipts', {}),
        next: (_) {
          expect(f.lastData()['records'], isEmpty);
          return core.answer(
            'An authoritative replacement retired the old receipt.',
          );
        },
      );
      await f.start(tester, confirmation: false);
      final reply = await f.finish(tester);
      expect(core.wire, hasLength(3));
      f.noEgress('${renamed.body}${reply.body}');
    },
  );

  domainLoopTest(
    'MODEL prepublication ordinary history rename retires awaited native refresh but retains committed fact',
    (tester, f) async {
      final core = f.screen.core, c = core.container, db = core.native.db;
      core.isolation.extraAllowed.addAll({
        chatHistoryProvider,
        revealHiddenCharactersProvider,
      });
      final history = await configurationAction(tester, () async {
        await c.read(chatHistoryProvider.future);
        return c.read(chatHistoryProvider.notifier);
      });
      final original = c
          .read(chatNativeOwnerRegistryProvider)
          .existing(DomainLoopFixture.session)!;
      final before = c
          .read(chatProvider(DomainLoopFixture.character))
          .value!
          .session!;
      f.script(
        core.call('astoria_session_rename', {
          'sessionId': DomainLoopFixture.session,
          'title': 'First committed title',
        }),
      );
      await f.start(tester);
      var interrupted = false;
      core.native.sql.afterSelect = (statement, _) async {
        // Only the full-row postcommit owner refresh, not title CAS observations.
        if (!interrupted &&
            statement.trimLeft().toLowerCase().startsWith(
              'select * from "chat_sessions"',
            )) {
          interrupted = true;
          await history.renameSession(
            DomainLoopFixture.session,
            'Ordinary history title',
          );
        }
      };
      await f.apply(tester);
      final reply = await f.finish(tester);
      core.native.sql.afterSelect = null;
      expect(interrupted, true);
      expect(reply.status, 'stopped', reason: reply.body);
      expect(reply.body, contains('изменение сохранено'));
      expect(
        reply.body,
        contains('обновление нативных представлений ожидается'),
      );
      expect(
        c.read(chatProvider(DomainLoopFixture.character)).value!.session,
        same(before),
      );
      expect(
        c
            .read(chatNativeOwnerRegistryProvider)
            .existing(DomainLoopFixture.session),
        same(original),
      );
      final durable = await configurationAction(
        tester,
        () => c.read(chatRepoProvider).getById(DomainLoopFixture.session),
      );
      expect(durable!.sessionVars['sessionName'], 'Ordinary history title');
      final journal = await configurationAction(
        tester,
        () => db.select(db.supportMutationJournal).get(),
      );
      expect(journal.single.status, 'applied');
      expect(core.wire, hasLength(1));
      f.noEgress(reply.body);
    },
  );

  for (final legacy in [false, true]) {
    domainLoopTest(
      'original character deletion fences session before cascade prerequisites and retains retirement on failure: legacy=$legacy',
      (tester, f) async {
        final core = f.screen.core, c = core.container, db = core.native.db;
        core.isolation.extraAllowed.add(characterDeletionRepoProvider);
        final mutations = c.read(chatSourceMutationRegistryProvider);
        final before = mutations.sessionCheckpoint(DomainLoopFixture.session);
        var observed = false;
        core.native.sql.afterSelect = (statement, _) async {
          if (!observed && statement.contains('"studio_config_rows"')) {
            observed = true;
            expect(mutations.isSessionPending(DomainLoopFixture.session), true);
            expect(
              identical(
                before,
                mutations.sessionCheckpoint(DomainLoopFixture.session),
              ),
              false,
            );
            throw const _SyntheticCascadeFailure();
          }
        };
        await configurationAction(tester, () async {
          try {
            if (legacy) {
              await c
                  .read(characterRepoProvider)
                  .delete(DomainLoopFixture.character);
            } else {
              await c.read(characterDeletionRepoProvider).deleteCharacters({
                DomainLoopFixture.character,
              });
            }
            fail('The injected original cascade failure must propagate.');
          } on _SyntheticCascadeFailure {
            // Admission intent remains retired even without a durable deletion.
          }
        });
        core.native.sql.afterSelect = null;
        expect(observed, true);
        expect(mutations.isSessionPending(DomainLoopFixture.session), false);
        expect(
          identical(
            before,
            mutations.sessionCheckpoint(DomainLoopFixture.session),
          ),
          false,
        );
        final durable = await configurationAction(
          tester,
          () => c.read(chatRepoProvider).getById(DomainLoopFixture.session),
        );
        expect(durable, isNotNull);
        expect(
          await configurationAction(
            tester,
            () => db.select(db.supportMutationJournal).get(),
          ),
          isEmpty,
        );
        expect(core.wire, isEmpty);
        f.noEgress();
      },
    );
  }
}

final class _SyntheticSyncFailure implements Exception {
  const _SyntheticSyncFailure();
}

final class _SyntheticCascadeFailure implements Exception {
  const _SyntheticCascadeFailure();
}
