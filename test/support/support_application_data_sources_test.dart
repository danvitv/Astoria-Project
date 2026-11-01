import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_provenance_codec.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_service.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_runtime.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_store.dart';

import 'helpers/support_automatic_sources_fixture.dart';
import 'support_app_backup_loop_native.dart';

Future<void> _seed(AutomaticSourcesFixture f) async {
  await f.native.db.customStatement(
    "INSERT INTO characters(char_id,name) VALUES('automatic-character','Marina')",
  );
  for (final i in [0, 1]) {
    await f.native.db.customStatement(
      'INSERT INTO chat_sessions(session_id,character_id,session_index,messages_json,updated_at) VALUES(?,?,?,?,?)',
      [
        'automatic-game-$i',
        'automatic-character',
        i,
        jsonEncode([
          {
            'id': 'automatic-message-$i',
            'role': 'assistant',
            'timestamp': 1,
            'content': jsonEncode({
              'scene': 'Marina scene $i',
              'apiKey': 'UNREGISTERED_JSON_KEY',
              'customHeaders': {'X-Unusual-Auth': 'UNREGISTERED_CUSTOM_HEADER'},
              'nested': jsonEncode({
                'headers': {'X-Private': 'NESTED_HEADER_KEY'},
              }),
            }),
            'reasoning': 'EXCLUDED_REASONING',
          },
        ]),
        i == 0 ? 1785750440 : 1785750441000,
      ],
    );
    await f.native.db.customStatement(
      'UPDATE chat_sessions SET session_vars_json=? WHERE session_id=?',
      [
        jsonEncode({
          'sessionName': i == 1
              ? 'Newest Marina session'
              : 'Earlier Marina session',
          'apiKey': 'DO_NOT_READ_SESSION_VARIABLE_KEY',
        }),
        'automatic-game-$i',
      ],
    );
  }
  await f.native.db.customStatement(
    'INSERT INTO studio_preset_rows(preset_id,name,blocks_json,runtime_settings_json,agents_json) VALUES(?,?,?,?,?)',
    [
      'automatic-studio',
      'Current Studio',
      jsonEncode([
        {
          'id': 'automatic-block',
          'name': 'Brief',
          'kind': 'custom_text',
          'content': 'Current Studio brief',
          'enabled': true,
        },
      ]),
      '{}',
      '[]',
    ],
  );
}

Future<void> _encrypted(AutomaticSourcesFixture f, int count) async {
  final rows = await f.native.repo.getMessagesForSession(f.native.session);
  final reply = rows.lastWhere((m) => m.role == 'assistant');
  final block = await f.native.repo.getContextBlockById(
    'support.reply_provenance:${reply.id}',
  );
  // Use the canonical fixed recipe ID rather than leaking private source IDs to wire.
  expect(block, isNotNull);
  final recipe = SupportModelProvenanceCodec.decodeFromEncryptedStorage(
    block!.protectedFactsJson,
  ).recipe!;
  expect(recipe.toolDisclosures, hasLength(count));
  for (final disclosure in recipe.toolDisclosures!) {
    expect(jsonEncode(f.wire), isNot(contains(disclosure.snapshotDigest)));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'one global consent -> all named newest catalog handles -> TWO sessions and current Studio in ONE run without UI',
    () async {
      await automaticSourcesTest((f) async {
        await _seed(f);
        final canonical = f.native.handle.select(
          'SELECT messages_json FROM chat_sessions WHERE character_id=? ORDER BY session_index',
          ['automatic-character'],
        );
        late String newest, older, studio;
        f.script = (round) async {
          if (round == 1)
            return AutomaticSourcesFixture.calls([
              ('games', 'astoria_sources_list', {'domain': 'game'}),
              ('studio', 'astoria_sources_list', {'domain': 'studioPreset'}),
            ]);
          if (round == 2) {
            await _encrypted(f, 2);
            final games = (f.result('games')['data']['pieces'] as List)
                .where((p) => p['label'] == 'Marina')
                .toList();
            expect(games, hasLength(2));
            expect(games.map((p) => p['sessionNumber']), [2, 1]);
            expect(games.first['savedActivityAt'], 1785750441000);
            expect(games.first['title'], 'Newest Marina session');
            expect(games.every((p) => p['state'] == 'current'), true);
            newest = games.first['source'] as String;
            older = games.last['source'] as String;
            studio =
                (f.result('studio')['data']['pieces'] as List).singleWhere(
                      (p) => p['activeAtListing'] == true,
                    )['source']
                    as String;
            return AutomaticSourcesFixture.calls([
              (
                'newest-contents',
                'astoria_source_contents',
                {'source': newest},
              ),
              ('older-contents', 'astoria_source_contents', {'source': older}),
              (
                'studio-search',
                'astoria_source_search',
                {'source': studio, 'literal': 'Current Studio brief'},
              ),
            ]);
          }
          if (round == 3) {
            await _encrypted(f, 5);
            expect(jsonEncode(f.wire), isNot(contains('Marina scene')));
            expect(
              jsonEncode(f.body('studio-search')),
              contains('Current Studio brief'),
            );
            return AutomaticSourcesFixture.calls([
              (
                'newest-read',
                'astoria_source_read',
                {
                  'source': newest,
                  'selector': f.body(
                    'newest-contents',
                  )['pieces'][0]['selector'],
                },
              ),
              (
                'older-read',
                'astoria_source_read',
                {
                  'source': older,
                  'selector': f.body('older-contents')['pieces'][0]['selector'],
                },
              ),
              (
                'studio-read',
                'astoria_source_read',
                {
                  'source': studio,
                  'selector': f.body('studio-search')['pieces'][0]['selector'],
                },
              ),
            ]);
          }
          if (round == 4) {
            await _encrypted(f, 8);
            expect(
              jsonEncode(f.body('newest-read')),
              contains('Marina scene 1'),
            );
            expect(
              jsonEncode(f.body('older-read')),
              contains('Marina scene 0'),
            );
            expect(
              jsonEncode(f.body('studio-read')),
              contains('Current Studio brief'),
            );
            return AutomaticSourcesFixture.answer();
          }
          throw TestFailure('Unexpected extra model round');
        };
        final submission = await f.start();
        final result = await submission.finished.timeout(
          const Duration(seconds: 30),
        );
        expect(
          result.message?.status,
          'complete',
          reason:
              '${result.reason.name}: posts=${f.wire.length}, reply=${result.message?.text}; ${f.activity.map((a) => a.detail).join(' | ')}',
        );
        expect(f.wire, hasLength(4));
        final outward = jsonEncode(f.wire);
        for (final forbidden in [
          BackupLoopNative.key,
          BackupLoopNative.rowSecret,
          'UNREGISTERED_JSON_KEY',
          'DO_NOT_READ_SESSION_VARIABLE_KEY',
          'UNREGISTERED_CUSTOM_HEADER',
          'NESTED_HEADER_KEY',
          'EXCLUDED_REASONING',
          'automatic-game-',
          'automatic-character',
          'automatic-message-',
          'automatic-block',
        ]) {
          expect(outward, isNot(contains(forbidden)));
        }
        expect(
          f.requests.every(
            (r) =>
                r.uri.toString() ==
                'https://api.openai.com/v1/chat/completions',
          ),
          true,
        );
        expect(
          f.native.handle
              .select(
                'SELECT messages_json FROM chat_sessions WHERE character_id=? ORDER BY session_index',
                ['automatic-character'],
              )
              .map((r) => r['messages_json']),
          canonical.map((r) => r['messages_json']),
        );
      });
    },
    skip: !Platform.isWindows,
  );

  test(
    'deny without global consent exposes no named catalog/body and requests no approval callback',
    () async {
      await automaticSourcesTest((f) async {
        await _seed(f);
        f.script = (round) {
          if (round == 1)
            return AutomaticSourcesFixture.calls([
              ('deny', 'astoria_sources_list', {'domain': 'game'}),
            ]);
          expect(f.result('deny')['ok'], false);
          return AutomaticSourcesFixture.answer();
        };
        final result = await (await f.start()).finished;
        expect(result.message?.status, 'error');
        expect(jsonEncode(f.wire), isNot(contains('Marina scene')));
      }, grant: false);
    },
    skip: !Platform.isWindows,
  );

  test(
    'failed OFF persistence denies NEW runs and automatic preparation until fresh native consent',
    () async {
      await automaticSourcesTest((f) async {
        await _seed(f);
        await f.native.db.customStatement('''
        CREATE TEMP TRIGGER synthetic_fail_application_denial
        BEFORE UPDATE ON support_context_blocks
        WHEN NEW.id='workspace-permissions-global-v1'
        BEGIN SELECT RAISE(ABORT, 'synthetic denial write failure'); END
      ''');
        final controller = SupportNativeConsentController(
          runtime: f.native.runtime,
          readMessages: (_, _, _) => throw StateError('No read picker'),
        );
        final entered = Completer<void>(), release = Completer<void>();
        f.script = (round) async {
          if (round == 1)
            return AutomaticSourcesFixture.calls([
              ('games', 'astoria_sources_list', {'domain': 'game'}),
            ]);
          if (round == 2)
            return AutomaticSourcesFixture.calls([
              (
                'contents',
                'astoria_source_contents',
                {'source': f.result('games')['data']['pieces'][0]['source']},
              ),
            ]);
          expect(round, 3);
          entered.complete();
          await release.future;
          return AutomaticSourcesFixture.answer();
        };
        final first = await f.start();
        await entered.future.timeout(const Duration(seconds: 20));
        try {
          expect(
            await controller.revokeApplicationDataFromDisplayedIntent(
              controller.view.displayedIntent,
            ),
            false,
          );
          expect(f.native.permissions.applicationDataReadDenied, true);
          expect(f.native.permissions.applicationDataRevocationUnsaved, true);
          expect(
            f.native.runtime.snapshot.preferences!.allows(
              SupportPermission.readApplicationData,
            ),
            true,
          );
        } finally {
          release.complete();
        }
        expect(
          (await first.finished.timeout(
            const Duration(seconds: 20),
          )).message?.status,
          isNot('complete'),
        );
        await f.native.db.customStatement(
          'DROP TRIGGER synthetic_fail_application_denial',
        );
        await f.native.db.customStatement(
          'INSERT INTO chat_sessions(session_id,character_id,session_index,messages_json,updated_at) VALUES(?,?,?,?,?)',
          [
            'denied-unprepared',
            'automatic-character',
            2,
            jsonEncode([
              {
                'id': 'denied-message',
                'role': 'assistant',
                'timestamp': 1,
                'content': 'DENIED_UNPREPARED_BODY',
              },
            ]),
            1785759999000,
          ],
        );
        expect(
          (await f.native.db.historySourceIndex.observe(
            'denied-unprepared',
          ))['status'],
          isNot('ready'),
        );
        final replacement = SupportPermissionStore(f.native.repo);
        expect(replacement.applicationDataReadDenied, true);
        f.native.runtime.selectSession(f.native.session, force: true);
        await f.native.runtime.refresh(resolve: true);
        expect(f.native.permissions.applicationDataReadDenied, true);
        final previousPosts = f.wire.length;
        f.script = (round) {
          if (round == previousPosts + 1)
            return AutomaticSourcesFixture.calls([
              ('denied-new-run', 'astoria_sources_list', {'domain': 'game'}),
            ]);
          expect(round, previousPosts + 2);
          expect(f.result('denied-new-run')['ok'], false);
          return AutomaticSourcesFixture.answer();
        };
        final next = await f.start();
        expect(
          (await next.finished.timeout(
            const Duration(seconds: 20),
          )).message?.status,
          isNot('complete'),
        );
        expect(
          jsonEncode(f.wire.skip(previousPosts).toList()),
          isNot(contains('DENIED_UNPREPARED_BODY')),
        );
        expect(
          (await f.native.db.historySourceIndex.observe(
            'denied-unprepared',
          ))['status'],
          isNot('ready'),
        );
        final staleReview = await controller.prepareReview(
          resolveRecipient: false,
        );
        expect(staleReview, isNotNull);
        expect(
          await controller.revokeApplicationDataFromDisplayedIntent(
            controller.view.displayedIntent,
          ),
          true,
        );
        expect(
          await controller.setGrant(
            staleReview!,
            SupportPermission.readApplicationData,
            true,
          ),
          false,
        );
        expect(f.native.permissions.applicationDataReadDenied, true);
        final freshReview = await controller.prepareReview(
          resolveRecipient: false,
        );
        expect(freshReview, isNotNull);
        expect(
          await controller.setGrant(
            freshReview!,
            SupportPermission.readApplicationData,
            true,
          ),
          true,
        );
        expect(f.native.permissions.applicationDataReadDenied, false);
        expect(replacement.applicationDataReadDenied, false);
      });
    },
    skip: !Platform.isWindows,
  );

  for (final enableAgain in [false, true]) {
    test(
      'another runtime failed OFF retires catalog custody before POST; fresh ON=$enableAgain cannot revive it',
      () async {
        await automaticSourcesTest((f) async {
          await _seed(f);
          final otherStore = SupportPermissionStore(f.native.repo);
          final other = SupportNativeRuntime(
            permissions: otherStore,
            resolveRecipient: f.native.runtime.resolveRecipient,
            loadSelectedConnection: f.native.runtime.loadSelectedConnection,
            configurationRevision: f.native.runtime.configurationRevision,
            configurationStable: f.native.runtime.configurationStable,
          );
          try {
            other.selectSession(f.native.session);
            await other.refresh();
            final controller = SupportNativeConsentController(
              runtime: other,
              readMessages: (_, _, _) => throw StateError('No read picker'),
            );
            final originalEpoch = f.native.runtime.epoch;
            f.native.primitive.afterEncrypt = (aad) async {
              if (aad.contains('workspace-permissions-global-v1'))
                throw StateError('synthetic denial write failure');
            };
            Future<bool>? denied;
            f.onActivity = (activity) {
              if (denied == null &&
                  activity.action == 'astoria_sources_list' &&
                  activity.stage.name == 'completed') {
                denied = controller.revokeApplicationDataFromDisplayedIntent(
                  controller.view.displayedIntent,
                );
              }
            };
            f.script = (round) {
              if (round == 1)
                return AutomaticSourcesFixture.calls([
                  ('games', 'astoria_sources_list', {'domain': 'game'}),
                ]);
              if (round == 2)
                return AutomaticSourcesFixture.calls([
                  (
                    'old-source',
                    'astoria_source_contents',
                    {
                      'source': f.result(
                        'games',
                      )['data']['pieces'][0]['source'],
                    },
                  ),
                ]);
              return AutomaticSourcesFixture.answer();
            };
            final started = await f.start();
            final retained = (await started.prepared).preview;
            expect(retained, isNotNull);
            final result = await started.finished.timeout(
              const Duration(seconds: 20),
            );
            expect(denied, isNotNull);
            expect(await denied!, false);
            expect(
              f.native.runtime.epoch,
              originalEpoch,
            ); // B does not notify/invalidate A.
            expect(
              f.native.runtime.snapshot.preferences!.allows(
                SupportPermission.readApplicationData,
              ),
              true,
            );
            expect(retained!.isCurrent, false);
            expect(result.message?.status, isNot('complete'));
            expect(f.wire, hasLength(1));
            expect(
              jsonEncode(f.wire),
              isNot(contains('Newest Marina session')),
            );
            await _encrypted(f, 1);
            if (enableAgain) {
              f.native.primitive.afterEncrypt = null;
              final review = await controller.prepareReview(
                resolveRecipient: false,
              );
              expect(review, isNotNull);
              expect(
                await controller.setGrant(
                  review!,
                  SupportPermission.readApplicationData,
                  true,
                ),
                true,
              );
              expect(otherStore.applicationDataReadDenied, false);
              expect(retained.isCurrent, false);
              expect(f.wire, hasLength(1));
            }
          } finally {
            f.native.primitive.afterEncrypt = null;
            other.dispose();
          }
        });
      },
      skip: !Platform.isWindows,
    );
  }

  for (final interruption in [
    'nativeRevoke',
    'revoke',
    'durableRevoke',
    'stop',
    'mutation',
    'model',
  ]) {
    test(
      '$interruption after automatic contents cancels source transmission/replay',
      () async {
        await automaticSourcesTest((f) async {
          await _seed(f);
          final controller = SupportNativeConsentController(
            runtime: f.native.runtime,
            readMessages: (_, _, _) =>
                throw StateError('Revocation must not read a picker'),
          );
          final entered = Completer<void>(), release = Completer<void>();
          f.script = (round) async {
            if (round == 1)
              return AutomaticSourcesFixture.calls([
                ('games', 'astoria_sources_list', {'domain': 'game'}),
              ]);
            if (round == 2) {
              final source = f.result('games')['data']['pieces'][0]['source'];
              return AutomaticSourcesFixture.calls([
                ('contents', 'astoria_source_contents', {'source': source}),
              ]);
            }
            expect(round, 3);
            entered.complete();
            await release.future;
            return AutomaticSourcesFixture.calls([
              (
                'replay',
                'astoria_source_read',
                {
                  'source': f.result('games')['data']['pieces'][0]['source'],
                  'selector': f.body('contents')['pieces'][0]['selector'],
                },
              ),
            ]);
          };
          final submission = await f.start();
          await entered.future.timeout(const Duration(seconds: 20));
          try {
            if (interruption == 'nativeRevoke') {
              final view = controller.view;
              expect(
                view.busy,
                false,
              ); // Active source/model work is not a consent-store mutex.
              final epoch = f.native.runtime.epoch;
              final revoked = controller
                  .revokeApplicationDataFromDisplayedIntent(
                    view.displayedIntent,
                  );
              expect(
                f.native.runtime.epoch,
                greaterThan(epoch),
              ); // Synchronous, before decrypt/write.
              expect(await revoked, true);
              expect(
                f.native.runtime.snapshot.preferences!.allows(
                  SupportPermission.readApplicationData,
                ),
                false,
              );
            } else if (interruption == 'stop') {
              f.service.stop();
            } else if (interruption == 'revoke' ||
                interruption == 'durableRevoke') {
              await f.native.permissions.setGrantFromNative(
                f.native.session,
                SupportPermission.readApplicationData,
                false,
                isCurrent: () => true,
              );
              if (interruption == 'revoke') await f.native.runtime.refresh();
            } else if (interruption == 'mutation') {
              await f.native.db.customStatement(
                "UPDATE chat_sessions SET draft='changed' WHERE session_id='automatic-game-1'",
              );
              f.service.invalidateGameSource(sessionId: 'automatic-game-1');
            } else {
              final mutation = f.native.revisions.beginMutation();
              mutation();
            }
          } finally {
            release.complete();
          }
          final result = await submission.finished.timeout(
            const Duration(seconds: 20),
          );
          expect(result.message?.status, isNot('complete'));
          expect(f.wire, hasLength(3));
          expect(jsonEncode(f.wire), isNot(contains('Marina scene')));
          f.service.stop();
          expect(f.wire, hasLength(3));
          final replayed = await f.service.beginSend(f.retainedInput!).finished;
          expect(replayed.accepted, false);
          expect(f.wire, hasLength(3));
        });
      },
      skip: !Platform.isWindows,
    );
  }

  for (final mode in ['nativeRevoke', 'stop', 'mutation']) {
    test(
      '$mode after encrypted contents commit but BEFORE continuation wire denies payload replay',
      () async {
        await automaticSourcesTest((f) async {
          await _seed(f);
          final controller = SupportNativeConsentController(
            runtime: f.native.runtime,
            readMessages: (_, _, _) => throw StateError('No picker'),
          );
          Future<bool>? revocation;
          var interrupted = false;
          f.onActivity = (activity) {
            if (interrupted ||
                activity.action != 'astoria_source_contents' ||
                activity.stage.name != 'completed')
              return;
            interrupted = true;
            if (mode == 'nativeRevoke') {
              revocation = controller.revokeApplicationDataFromDisplayedIntent(
                controller.view.displayedIntent,
              );
            } else if (mode == 'stop') {
              f.service.stop();
            } else {
              f.native.handle.execute(
                "UPDATE chat_sessions SET draft='before-wire' WHERE session_id='automatic-game-1'",
              );
            }
          };
          f.script = (round) {
            if (round == 1)
              return AutomaticSourcesFixture.calls([
                ('games', 'astoria_sources_list', {'domain': 'game'}),
              ]);
            expect(round, 2);
            return AutomaticSourcesFixture.calls([
              (
                'contents',
                'astoria_source_contents',
                {'source': f.result('games')['data']['pieces'][0]['source']},
              ),
            ]);
          };
          final submission = await f.start();
          final result = await submission.finished.timeout(
            const Duration(seconds: 20),
          );
          if (revocation != null) expect(await revocation!, true);
          expect(interrupted, true);
          expect(result.message?.status, isNot('complete'));
          expect(f.wire, hasLength(2));
          await _encrypted(
            f,
            2,
          ); // Catalog + contents provenance survives settlement.
          final replay = await f.service.beginSend(f.retainedInput!).finished;
          expect(replay.accepted, false);
          expect(f.wire, hasLength(2));
        });
      },
      skip: !Platform.isWindows,
    );
  }
}
