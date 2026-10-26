import 'dart:convert';

import 'package:drift/drift.dart'
    show Value, QueryInterceptor, QueryExecutor, TransactionExecutor;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart' hide expect;
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_model_provenance.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_provenance_codec.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_ui_bridge.dart';

import 'support_model_source_loop_fixture.dart';

void _noExcluded(BackupLoopFixture f) {
  final outward = jsonEncode(f.wire);
  expect(outward, isNot(contains(sourceExcluded)));
  expect(outward, isNot(contains(sourceOlderBody)));
  expect(outward, isNot(contains(sourceInactiveStudioBody)));
  // Actual XChaCha decrypt observations, not an inert openedNative SQL spy.
  expect(
    f.native.primitive.decryptAads.any(
      (aad) => aad.contains('|excluded-backup-message|'),
    ),
    isFalse,
  );
  sourceNoEgress(f);
}

SupportModelMessage _selected(SupportMessage row) => SupportModelMessage(
  id: row.id,
  sessionId: row.sessionId,
  runId: row.runId!,
  role: row.role,
  status: row.status,
  createdAt: row.createdAt,
  text: row.body,
);

Future<List<SupportModelConversationMessage>> _visible(
  BackupLoopFixture f,
) async => [
  for (final row in await f.native.repo.getMessagesForSession(f.native.session))
    SupportModelConversationMessage(id: row.id, role: row.role, text: row.body),
];

/// Stop after the real OUTER source-provenance commit, before Drift returns the
/// transaction result. The native executor, SQL and committed result are intact.
final class _StopAfterSourceCommit extends QueryInterceptor {
  _StopAfterSourceCommit(this.stop);
  final void Function() stop;
  final _outer = <TransactionExecutor, bool>{};
  bool _sourceWritten = false;
  int committedSourceWrites = 0;

  @override
  TransactionExecutor beginTransaction(QueryExecutor parent) {
    final inner = super.beginTransaction(parent);
    _outer[inner] = parent is! TransactionExecutor;
    return inner;
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final changed = await super.runUpdate(executor, statement, args);
    if (changed == 1 &&
        statement.contains('support_context_blocks') &&
        statement.contains('protected_facts_ciphertext') &&
        args.any(
          (v) => v is String && v.startsWith('support.reply_provenance:'),
        )) {
      _sourceWritten = true;
    }
    return changed;
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) async {
    final outer = _outer.remove(inner) == true;
    await super.commitTransaction(inner);
    if (outer && _sourceWritten && committedSourceWrites == 0) {
      committedSourceWrites++;
      stop();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Reuse the already-isolated FILE-owner graph for generic native confirmation;
  // the old configuration-only fixture cannot bootstrap the current domain graph.
  backupLoopTest(
    'MODEL journal forwards exact generic confirmation for connection create',
    (tester, f) async {
      final loop = SourceLoop(f);
      final ui = loop.nativeUi(tester);
      const name = 'Journal synthetic connection';
      final before = await backupLoopReal(
        tester,
        f.native.apiRepo.getConfigIds,
      );
      loop.script(
        SourceLoop.call('astoria_connection_create', {
          'template': 'openaiChat',
          'model': 'synthetic-model',
          'name': name,
          'maxTokens': 2048,
          'contextSize': 16384,
          'temperature': 0.3,
        }, id: 'journal_connection'),
        rounds: 1,
      );
      try {
        final send = await backupLoopReal(
          tester,
          () => loop
              .emitter(tester, ui: ui)
              .send(
                text: 'Создай API-конфигурацию после моего подтверждения.',
                draftRevision: 1,
                isDraftCurrent: () => true,
              ),
        );
        final signal = BackupLoopSignal(send.finished);
        await loop.modal(tester);
        expect(f.bridge.view.toolActivities, hasLength(1));
        expect(
          f.bridge.view.toolActivities.single.action,
          'astoria_connection_create',
        );
        expect(
          f.bridge.view.toolActivities.single.stage,
          SupportModelToolStage.confirmation,
        );
        expect(find.text('Применить'), findsOneWidget);
        expect(
          await backupLoopReal(tester, f.native.apiRepo.getConfigIds),
          before,
        );
        await loop.apply(tester);
        final result = await loop.join(tester, signal);
        expect(result.saved, isTrue);
        expect(result.message!.text, contains('изменение сохранено'));
        expect(f.wire, hasLength(1));
        final after = await backupLoopReal(
          tester,
          f.native.apiRepo.getConfigIds,
        );
        final id = after.singleWhere((id) => !before.contains(id));
        final saved = await backupLoopReal(
          tester,
          () => f.native.apiRepo.inspectKeyless(id),
        );
        expect(saved!.view.displayName, name);
        expect(saved.view.maxTokens, 2048);
        expect(after.length, before.length + 1);
        loop.noBody();
      } finally {
        ui.dispose();
      }
    },
  );

  backupLoopTest(
    'MODEL two catalogs then two approved reads in one turn accepts saved seed and toggle dialects',
    (tester, f) async {
      await seedModelSources(tester, f);
      final loop = SourceLoop(f);
      await backupLoopReal(tester, () async {
        await (f.native.db.update(
          f.native.db.studioPresetRows,
        )..where((t) => t.presetId.equals(sourceStudio))).write(
          StudioPresetRowsCompanion(
            blocksJson: Value(
              jsonEncode([
                {
                  'id': 'seed-block',
                  'name': 'Saved seed text',
                  'kind': 'custom_text',
                  'content': '${sourceStudioBody}RAW_SAVED_SEED',
                  'locked': false,
                },
              ]),
            ),
            runtimeSettingsJson: const Value(
              '{"version":1,"broadcastBlocks":[],"agentEnabledBeforeDependencyOff":{"continuity":true}}',
            ),
          ),
        );
      });
      Map<String, Object?> batch(
        Map<String, Object?> first,
        Map<String, Object?> second,
      ) {
        final message =
            ((first['choices'] as List).single as Map)['message'] as Map;
        final other =
            ((second['choices'] as List).single as Map)['message'] as Map;
        (message['tool_calls'] as List).addAll(other['tool_calls'] as List);
        return first;
      }

      Map<String, dynamic> dataFor(String id) {
        final messages = f.wire.last['messages'] as List;
        final message = messages.cast<Map<dynamic, dynamic>>().lastWhere(
          (m) => m['role'] == 'tool' && m['tool_call_id'] == id,
        );
        final result = jsonDecode(message['content'] as String) as Map;
        expect(result['ok'], isTrue);
        return Map<String, dynamic>.from(result['data'] as Map);
      }

      loop.script(
        batch(
          loop.list('game', 'batch_game_list'),
          loop.list('studioPreset', 'batch_studio_list'),
        ),
        rounds: 3,
        next: (round) {
          if (round == 2) {
            final games = (dataFor('batch_game_list')['entries'] as List)
                .cast<Map<dynamic, dynamic>>();
            final studios = (dataFor('batch_studio_list')['entries'] as List)
                .cast<Map<dynamic, dynamic>>();
            return batch(
              loop.read(
                games.firstWhere(
                      (e) => e['label'] == 'Отель Петербург',
                    )['opaqueHandle']
                    as String,
                'batch_game_read',
              ),
              loop.read(
                studios.singleWhere(
                      (e) => e['activeAtListing'] == true,
                    )['opaqueHandle']
                    as String,
                'batch_studio_read',
              ),
            );
          }
          expect(
            dataFor('batch_game_read')['sourceText'],
            contains(sourceGameBody),
          );
          final studio =
              jsonDecode(dataFor('batch_studio_read')['sourceText'] as String)
                  as Map;
          expect(studio['state'], 'CURRENT SAVED');
          expect(jsonEncode(studio), contains('RAW_SAVED_SEED'));
          expect(
            jsonEncode(studio),
            contains('agentEnabledBeforeDependencyOff'),
          );
          return SourceLoop.answer('Compared both approved saved sources.');
        },
      );
      await loop.start(tester);
      loop.noBody();
      expect(f.bridge.view.toolActivities.map((a) => a.sequence), [1, 2, 3]);
      expect(
        f.bridge.view.toolActivities.last.stage,
        SupportModelToolStage.confirmation,
      );
      await loop.apply(tester);
      await loop.modal(tester);
      expect(f.wire, hasLength(2));
      loop.noBody();
      expect(f.bridge.view.toolActivities.map((a) => a.sequence), [1, 2, 3, 4]);
      await loop.apply(tester);
      final reply = await loop.finish(tester);
      expect(reply.status, 'complete');
      expect(f.wire, hasLength(3));
      expect(
        f.bridge.view.toolActivities.every(
          (a) => a.stage == SupportModelToolStage.completed,
        ),
        isTrue,
      );
      final recipe = await backupLoopReal(
        tester,
        () => modelSourceRecipe(f, reply.id),
      );
      expect(recipe.toolDisclosures, hasLength(2));
      f.noEgress(reply.body);
    },
  );

  backupLoopTest(
    'MODEL source metadata -> exact native game and Studio consent -> v4 -> cached next Send',
    (tester, f) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pump();
      await seedModelSources(tester, f);
      final loop = SourceLoop(f);
      final epoch = f.native.runtime.epoch;
      final policy = f.native.runtime.snapshot.preferences;
      final originalSource = f.native.db.nativeDataSourceIdentity!;
      expect(originalSource.belongsTo(f.native.db), isTrue);
      f.native.primitive.decryptAads.clear();
      final factsEncryptRounds = <int>[];
      f.native.primitive.afterEncrypt = (aad) async {
        if (aad.contains('|support.reply_provenance:') &&
            aad.endsWith('|protected_facts_ciphertext')) {
          factsEncryptRounds.add(f.wire.length);
        }
      };
      var answerIssued = false;
      loop.script(
        loop.list('game', 'source_list_game'),
        rounds: 5,
        next: (round) async {
          switch (round) {
            case 2:
              final entries = (loop.lastData()['entries'] as List)
                  .cast<Map<dynamic, dynamic>>();
              final hotel = entries
                  .where((e) => e['label'] == 'Отель Петербург')
                  .toList();
              expect(hotel.map((e) => e['sessionIndex']), [1, 0]);
              expect(hotel.map((e) => e['updatedAt']), [100, 10]);
              final handle = loop.handle('Отель Петербург', sessionIndex: 1);
              expect(handle, isNot(sourceSession));
              expect(handle, isNot(sourceOlderSession));
              loop.noBody();
              return loop.read(handle, 'source_read_game');
            case 3:
              final data = loop.lastData();
              final game = jsonDecode(data['sourceText'] as String) as Map;
              expect(game['sourceId'], sourceSession);
              expect(game['messages'], hasLength(16));
              expect((game['extent'] as Map)['orderedSourceIds'], [
                for (var i = 4; i < 20; i++) 'model-source-$i',
              ]);
              expect(data['sourceText'], contains(sourceGameBody));
              expect(data['sourceText'], isNot(contains(sourceExcluded)));
              final rows = await f.native.repo.getMessagesForSession(
                f.native.session,
              );
              final recipe = await modelSourceRecipe(f, rows.last.id);
              expect(recipe.toolDisclosures, hasLength(1));
              expect(recipe.toolDisclosures!.single.sourceId, sourceSession);
              // Real AEAD callback ran before the body round; encrypted v4 is
              // already durable when the actual private adapter receives that POST.
              expect(factsEncryptRounds, contains(2));
              _noExcluded(f);
              return loop.list('studioPreset', 'source_list_studio');
            case 4:
              final entries = (loop.lastData()['entries'] as List)
                  .cast<Map<dynamic, dynamic>>();
              expect(entries.first['label'], 'Comparison Studio');
              expect(entries.first['activeAtListing'], isTrue);
              expect(
                entries.singleWhere(
                  (e) => e['label'] == 'Newer inactive Studio',
                )['activeAtListing'],
                isFalse,
              );
              return loop.read(loop.activeStudioHandle(), 'source_read_studio');
            case 5:
              final studio =
                  jsonDecode(loop.lastData()['sourceText'] as String) as Map;
              expect(studio['sourceId'], sourceStudio);
              expect(studio['state'], 'CURRENT SAVED');
              expect(
                studio['scope'],
                contains('Not a historical assembled prompt'),
              );
              expect(jsonEncode(studio), contains(sourceStudioBody));
              final rows = await f.native.repo.getMessagesForSession(
                f.native.session,
              );
              final recipe = await modelSourceRecipe(f, rows.last.id);
              expect(recipe.toolDisclosures, hasLength(2));
              expect(factsEncryptRounds, contains(4));
              _noExcluded(f);
              answerIssued = true;
              return SourceLoop.answer(
                'Compared the approved game page with the CURRENT SAVED Studio definition.',
              );
            default:
              throw TestFailure('Unexpected source round');
          }
        },
      );
      await loop.start(tester);
      loop.noBody();
      expect(f.bridge.view.toolActivities.map((a) => a.sequence), [1, 2]);
      expect(f.bridge.view.toolActivities.map((a) => a.stage), [
        SupportModelToolStage.completed,
        SupportModelToolStage.confirmation,
      ]);
      expect(
        f.bridge.view.toolActivities.last.sourceLabel,
        contains('Отель Петербург'),
      );
      expect(f.bridge.view.toolActivities.last.label, contains('согласия'));
      expect(f.wire, hasLength(2));
      final tools = (f.wire.first['tools'] as List)
          .cast<Map<dynamic, dynamic>>();
      expect(tools, hasLength(45));
      expect(
        tools.map((t) => (t['function'] as Map)['name']),
        containsAll(['astoria_sources_list', 'astoria_source_read']),
      );
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
      expect(preview, contains('Отель Петербург'));
      expect(preview, contains(f.native.api.model));
      expect(preview, contains('model-source-4'));
      expect(preview, contains('model-source-19'));
      expect(preview, isNot(contains(sourceGameBody)));
      expect(find.text('Прочитать и передать модели'), findsOneWidget);
      final label = find.descendant(
        of: find.byKey(const ValueKey('support_tool_confirmation_accept')),
        matching: find.text('Прочитать и передать модели'),
      );
      expect(
        tester.renderObject<RenderParagraph>(label).didExceedMaxLines,
        isFalse,
      );
      await loop.apply(tester);
      await loop.modal(tester);
      expect(f.bridge.view.toolActivities.map((a) => a.sequence), [1, 2, 3, 4]);
      expect(
        f.bridge.view.toolActivities.last.stage,
        SupportModelToolStage.confirmation,
      );
      expect(
        f.bridge.view.toolActivities.last.sourceLabel,
        contains('Comparison Studio'),
      );
      expect(f.wire, hasLength(4));
      expect(jsonEncode(f.wire), contains(sourceGameBody));
      expect(jsonEncode(f.wire), isNot(contains(sourceStudioBody)));
      final studioPreview = tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(
                const ValueKey('support_tool_confirmation_preview'),
              ),
              matching: find.byType(Text),
            ),
          )
          .data!;
      expect(studioPreview, contains('Comparison Studio'));
      expect(studioPreview, contains('CURRENT SAVED'));
      expect(studioPreview, isNot(contains(sourceStudioBody)));
      await loop.apply(tester);
      final reply = await loop.finish(tester);
      expect(answerIssued, isTrue);
      expect(reply.status, 'complete');
      expect(f.bridge.view.toolActivities, hasLength(4));
      expect(
        f.bridge.view.toolActivities.every(
          (a) => a.stage == SupportModelToolStage.completed,
        ),
        isTrue,
      );
      expect(
        f.bridge.view.hasToolActivitiesFor(reply.runId, reply.sessionId),
        isTrue,
      );
      expect(
        f.bridge.view.hasToolActivitiesFor('other-run', reply.sessionId),
        isFalse,
      );
      final localTrace = f.bridge.view.toolActivities
          .map((a) => '${a.title} ${a.sourceLabel} ${a.label}')
          .join('\n');
      expect(localTrace, isNot(contains(sourceGameBody)));
      expect(localTrace, isNot(contains(sourceStudioBody)));
      expect(jsonEncode(f.wire), isNot(contains('Ожидание твоего согласия')));
      expect(
        reply.body,
        'Compared the approved game page with the CURRENT SAVED Studio definition.',
      );
      final recipe = await backupLoopReal(
        tester,
        () => modelSourceRecipe(f, reply.id),
      );
      expect(recipe.toolDisclosures!.map((d) => d.domain), [
        SupportModelToolDisclosureDomain.game,
        SupportModelToolDisclosureDomain.studioPreset,
      ]);
      expect(
        recipe.originalRanges.every(
          (r) => r.domain == SupportModelSourceDomain.support,
        ),
        isTrue,
      );
      for (final disclosure in recipe.toolDisclosures!) {
        expect(jsonEncode(f.wire), isNot(contains(disclosure.snapshotDigest)));
      }
      expect(f.wire, hasLength(5));
      for (final request in f.requests) {
        expect(request.method, 'POST');
        expect(request.uri, f.requests.first.uri);
        expect(request.cancelToken, same(f.requests.first.cancelToken));
      }
      expect(
        f.wire.every((post) => post['model'] == f.native.api.model),
        isTrue,
      );
      expect(f.native.db.nativeDataSourceIdentity, same(originalSource));
      expect(f.native.runtime.epoch, epoch);
      expect(f.native.runtime.snapshot.preferences, policy);
      _noExcluded(f);
      f.noEgress(reply.body);

      final start = f.wire.length;
      f.native.primitive.afterEncrypt = null;
      f.native.primitive.decryptAads.clear();
      loop.script(
        SourceLoop.answer('Cached current-chat answer only.'),
        rounds: 1,
      );
      await loop.start(tester, confirmation: false);
      final cached = await loop.finish(tester);
      expect(cached.status, 'complete');
      expect(f.bridge.view.toolActivities, isEmpty);
      final cachedRecipe = await backupLoopReal(
        tester,
        () => modelSourceRecipe(f, cached.id),
      );
      expect(cachedRecipe.toolDisclosures, hasLength(2));
      expect(cachedRecipe.toolDisclosures!.map((d) => d.sourceId), [
        sourceSession,
        sourceStudio,
      ]);
      final cachedWire = jsonEncode(f.wire.skip(start).toList());
      expect(cachedWire, isNot(contains(sourceGameBody)));
      expect(cachedWire, isNot(contains(sourceStudioBody)));
      for (final disclosure in cachedRecipe.toolDisclosures!) {
        expect(cachedWire, isNot(contains(disclosure.snapshotDigest)));
      }
      expect(
        find.byKey(const ValueKey('support_tool_confirmation_accept')),
        findsNothing,
      );
      expect(f.native.runtime.epoch, epoch);
      expect(f.native.runtime.snapshot.preferences, policy);
      _noExcluded(f);
    },
  );

  for (final decision in ['refuse', 'Stop', 'route ABA', 'source ABA']) {
    backupLoopTest(
      'MODEL exact source $decision retires original consent without body egress or global grants',
      (tester, f) async {
        await seedModelSources(tester, f);
        final loop = SourceLoop(f);
        final epoch = f.native.runtime.epoch,
            policy = f.native.runtime.snapshot.preferences;
        loop.script(
          loop.list('game', 'list_declined'),
          rounds: 3,
          next: (round) => round == 2
              ? loop.read(
                  loop.handle('Отель Петербург', sessionIndex: 1),
                  'read_declined',
                )
              : SourceLoop.answer('Source not approved.'),
        );
        await loop.start(tester);
        loop.noBody();
        final consentRoute = ModalRoute.of<void>(
          tester.element(
            find.byKey(const ValueKey('support_tool_confirmation_accept')),
          ),
        )!;
        if (decision == 'refuse') {
          await loop.cancel(tester);
        } else if (decision == 'Stop') {
          // The real composer callback is captured while its modal barrier
          // intentionally prevents a tap on the composer underneath the sheet.
          final stop = tester
              .widget<IconButton>(
                find.byKey(const ValueKey('support_composer_stop_btn')),
              )
              .onPressed!;
          await backupLoopReal(tester, stop);
        } else if (decision == 'route ABA') {
          await backupLoopReal(tester, () => f.router.go('/characters'));
          await tester.pump();
          await backupLoopReal(tester, () => f.router.go('/support'));
          await tester.pump();
        } else {
          await backupLoopReal(tester, () async {
            final db = f.native.db;
            final old = await (db.select(
              db.chatSessions,
            )..where((t) => t.sessionId.equals(sourceSession))).getSingle();
            await (db.update(db.chatSessions)
                  ..where((t) => t.sessionId.equals(sourceSession)))
                .write(const ChatSessionsCompanion(messagesJson: Value('[]')));
            await (db.update(
              db.chatSessions,
            )..where((t) => t.sessionId.equals(sourceSession))).write(
              ChatSessionsCompanion(messagesJson: Value(old.messagesJson)),
            );
          });
          await loop.apply(tester);
        }
        if (decision == 'Stop' || decision == 'route ABA') {
          // These original callbacks dismiss without the decision helper. Join
          // the retained route's real reverse animation before awaiting the run;
          // zero-duration polling cannot advance Flutter's fake animation clock.
          await tester.pump();
          await tester.pump(consentRoute.reverseTransitionDuration);
          await tester.pump(const Duration(microseconds: 1));
        }
        final reply = await loop.finish(tester);
        loop.noBody();
        expect(f.native.runtime.snapshot.preferences, policy);
        expect(f.native.runtime.epoch, epoch);
        expect(reply.body, isNot(contains(sourceGameBody)));
        if (decision != 'refuse') expect(f.wire, hasLength(2));
      },
    );
  }

  backupLoopTest(
    'MODEL Stop after committed source provenance settles extended reservation without body POST',
    (tester, f) async {
      await seedModelSources(tester, f);
      final loop = SourceLoop(f);
      loop.script(
        loop.list('game', 'commit_stop_list'),
        rounds: 3,
        next: (round) {
          if (round == 2) {
            return loop.read(
              loop.handle('Отель Петербург', sessionIndex: 1),
              'commit_stop_read',
            );
          }
          throw TestFailure('Stop after commit must prevent body continuation');
        },
      );
      final ui = loop.nativeUi(tester);
      try {
        final visible = await backupLoopReal(tester, () => _visible(f));
        final emitter = loop.emitter(tester, ui: ui, visible: visible);
        SupportModelUiSend? send;
        final commit = _StopAfterSourceCommit(() => send!.stop());
        final signal = await backupLoopReal(
          tester,
          () => BackupLoopSignal(
            f.native.db.runWithInterceptor(() async {
              send = emitter.send(
                text: 'Прочитай последнюю сессию «Отель Петербург».',
                draftRevision: 1,
                isDraftCurrent: () => true,
              );
              return await send!.finished;
            }, interceptor: commit),
          ),
        );
        await sourceLoopModal(tester, signal);
        loop.noBody();
        await loop.apply(tester);
        final result = await loop.join(tester, signal);
        expect(commit.committedSourceWrites, 1);
        expect(result.saved, isTrue);
        expect(result.message!.status, 'stopped');
        expect(f.wire, hasLength(2));
        loop.noBody();
        final recipe = await backupLoopReal(
          tester,
          () => modelSourceRecipe(f, result.message!.id),
        );
        expect(recipe.toolDisclosures, hasLength(1));
        expect(recipe.toolDisclosures!.single.sourceId, sourceSession);
        expect(recipe.toolDisclosures!.single.orderedSourceIds, [
          for (var i = 4; i < 20; i++) 'model-source-$i',
        ]);
      } finally {
        ui.dispose();
      }
    },
  );

  backupLoopTest(
    'MODEL game change after approved body round denies final replay POST',
    (tester, f) async {
      await seedModelSources(tester, f);
      final loop = SourceLoop(f);
      loop.script(
        loop.list('game', 'list_changed'),
        rounds: 4,
        next: (round) async {
          if (round == 2)
            return loop.read(
              loop.handle('Отель Петербург', sessionIndex: 1),
              'read_changed',
            );
          if (round == 3) {
            expect(loop.lastData()['sourceText'], contains(sourceGameBody));
            final db = f.native.db;
            await (db.update(db.chatSessions)
                  ..where((t) => t.sessionId.equals(sourceSession)))
                .write(const ChatSessionsCompanion(messagesJson: Value('[]')));
            return loop.list('studioPreset', 'list_after_change');
          }
          throw TestFailure('Changed approved source must block replay POST');
        },
      );
      await loop.start(tester);
      loop.noBody();
      await loop.apply(tester);
      final reply = await loop.finish(tester);
      expect(f.wire, hasLength(3));
      expect(reply.status, isNot('complete'));
      expect(reply.body, isNot(contains('Compared')));
      _noExcluded(f);
    },
  );

  backupLoopTest(
    'MODEL stale handle from a refused prior run is not source-read authority',
    (tester, f) async {
      await seedModelSources(tester, f);
      final loop = SourceLoop(f);
      late String stale;
      loop.script(
        loop.list('game', 'stale_list'),
        rounds: 3,
        next: (round) {
          if (round == 2) {
            stale = loop.handle('Отель Петербург', sessionIndex: 1);
            return loop.read(stale, 'stale_original_read');
          }
          return SourceLoop.answer('Source refused.');
        },
      );
      await loop.start(tester);
      await loop.cancel(tester);
      await loop.finish(tester);
      loop.script(
        loop.read(stale, 'stale_new_read'),
        rounds: 2,
        next: (_) {
          expect(loop.lastResult()['code'], 'denied');
          return SourceLoop.answer('Stale handle unavailable.');
        },
      );
      await loop.start(tester, confirmation: false);
      final reply = await loop.finish(tester);
      // The native outcome deliberately overrides model prose after a failed
      // tool. A denied old handle is a factual error, not a successful read.
      expect(reply.status, 'error');
      expect(reply.body, contains('Чтение источника'));
      expect(reply.body, contains('Вызов не разрешён'));
      expect(f.wire, hasLength(5));
      expect(loop.lastResult()['ok'], isFalse);
      expect(loop.lastResult()['code'], 'denied');
      loop.noBody();
      expect(
        find.byKey(const ValueKey('support_tool_confirmation_accept')),
        findsNothing,
      );
    },
  );

  backupLoopTest(
    'MODEL missing original source UI returns fixed unavailable without body or permission warming',
    (tester, f) async {
      await seedModelSources(tester, f);
      final loop = SourceLoop(f);
      final epoch = f.native.runtime.epoch,
          policy = f.native.runtime.snapshot.preferences;
      loop.script(
        loop.list('game', 'no_source_ui'),
        rounds: 2,
        next: (_) {
          expect(loop.lastResult()['code'], 'unavailable');
          return SourceLoop.answer('Source UI unavailable.');
        },
      );
      final visible = await backupLoopReal(tester, () => _visible(f));
      final emitter = loop.emitter(
        tester,
        visible: visible,
      ); // Deliberately no tool UI.
      final signal = await backupLoopReal(
        tester,
        () => BackupLoopSignal(
          emitter
              .send(
                text: 'Compare the latest game.',
                draftRevision: 1,
                isDraftCurrent: () => true,
              )
              .finished,
        ),
      );
      final result = await loop.join(tester, signal);
      expect(result.saved, isTrue);
      loop.noBody();
      expect(f.native.runtime.epoch, epoch);
      expect(f.native.runtime.snapshot.preferences, policy);
      expect(
        find.byKey(const ValueKey('support_tool_confirmation_accept')),
        findsNothing,
      );
    },
  );

  for (final shape in [
    'unsupported Studio',
    'malformed Studio',
    'malformed game',
    'historical Studio offset',
    'oversize game history',
    'oversize game page',
    'forged handle',
  ]) {
    backupLoopTest(
      'MODEL source $shape refuses without body or substituted source',
      (tester, f) async {
        final needsConsent =
            shape == 'unsupported Studio' || shape == 'malformed Studio';
        await seedModelSources(
          tester,
          f,
          studioJson: shape == 'unsupported Studio'
              ? '[{"id":"unsupported","type":"instruction","content":"$sourceStudioBody","futureCode":"x"}]'
              : shape == 'malformed Studio'
              ? '[{"content":"$sourceStudioBody"}'
              : null,
          gameJson: shape == 'malformed game'
              ? '{"content":"$sourceGameBody"}'
              : shape == 'oversize game page'
              ? jsonEncode([
                  for (var i = 0; i < 20; i++)
                    {
                      'id': 'oversize-$i',
                      'role': 'assistant',
                      'content':
                          '$sourceGameBody${List.filled(5000, 'g').join()}',
                    },
                ])
              : null,
          messages: shape == 'oversize game history' ? 2001 : 20,
        );
        final loop = SourceLoop(f);
        if (shape == 'forged handle') {
          loop.script(
            loop.read(sourceSession, 'forged_source'),
            rounds: 2,
            next: (_) {
              expect(loop.lastResult()['ok'], isFalse);
              expect(loop.lastResult()['code'], 'denied');
              return SourceLoop.answer('Unavailable.');
            },
          );
        } else {
          final studio = shape.contains('Studio');
          loop.script(
            loop.list(studio ? 'studioPreset' : 'game', 'bounded_list'),
            rounds: 3,
            next: (round) {
              if (round == 2)
                return loop.read(
                  loop.handle(
                    studio ? 'Comparison Studio' : 'Отель Петербург',
                    sessionIndex: studio ? null : 1,
                  ),
                  'bounded_read',
                  offset: shape == 'historical Studio offset' ? 16 : 0,
                );
              expect(loop.lastResult()['ok'], isFalse);
              return SourceLoop.answer('Unavailable bounded source.');
            },
          );
        }
        await loop.start(tester, confirmation: needsConsent);
        if (needsConsent) {
          loop.noBody();
          await loop.apply(tester);
        }
        final reply = await loop.finish(tester);
        loop.noBody();
        expect(reply.body, isNot(contains(sourceStudioBody)));
        expect(
          find.byKey(const ValueKey('support_tool_confirmation_accept')),
          findsNothing,
        );
      },
    );
  }

  for (final regeneration in [false, true]) {
    backupLoopTest(
      'MODEL read-only ${regeneration ? 'regen' : 'retry'} uses only private sources and fresh consent, never base graph',
      (tester, f) async {
        await seedModelSources(tester, f);
        final loop = SourceLoop(f);
        final epoch = f.native.runtime.epoch,
            policy = f.native.runtime.snapshot.preferences;
        final origin = (await backupLoopReal(
          tester,
          () => f.native.repo.appendCurrentUser(
            message: SupportMessage(
              id: 'source-reattempt-user',
              sessionId: f.native.session,
              role: 'user',
              body: 'Compare the latest Отель Петербург game.',
              runId: 'source-user-run',
              createdAt: 3,
            ),
            isCurrent: () => true,
          ),
        ))!;
        SupportMessage? oldReply;
        if (regeneration) {
          oldReply = await backupLoopReal(tester, () async {
            final oldRecipe = SupportModelProvenance(
              supportSessionId: f.native.session,
              replyMessageId: 'source-reattempt-reply',
              runId: origin.runId!,
              currentUserMessageId: origin.id,
              originalRanges: [
                SupportModelSourceRange(
                  domain: SupportModelSourceDomain.support,
                  sessionId: f.native.session,
                  orderedMessageIds: [
                    'old-native-user',
                    'old-native-assistant',
                  ],
                ),
              ],
              directReplies: const [],
              currentConversationMessageIds: [
                'old-native-user',
                'old-native-assistant',
              ],
              toolDisclosures: [
                SupportModelToolDisclosure(
                  domain: SupportModelToolDisclosureDomain.game,
                  sourceId: sourceSession,
                  orderedSourceIds: ['model-source-19'],
                  snapshotDigest: List.filled(64, 'a').join(),
                ),
              ],
            );
            final reserved = await f.native.repo.reserveOrderedReply(
              message: SupportMessage(
                id: 'source-reattempt-reply',
                sessionId: f.native.session,
                role: 'assistant',
                body: '',
                runId: origin.runId!,
                status: 'preparing',
                createdAt: 4,
              ),
              originatingUser: origin,
              provenanceJson:
                  SupportModelProvenanceCodec.encodeForEncryptedStorage(
                    oldRecipe,
                  ),
              isCurrent: () => true,
            );
            return f.native.repo.settleReply(
              expected: reserved!,
              status: 'complete',
              body: 'Cached old answer.',
              isCurrent: () => true,
            );
          });
        }
        final visible = await backupLoopReal(tester, () => _visible(f));
        expect(f.container.exists(supportAppActionRegistryProvider), isFalse);
        final ui = loop.nativeUi(tester);
        try {
          loop.script(
            loop.list('game', 'reattempt_list'),
            rounds: 3,
            next: (round) => round == 2
                ? loop.read(
                    loop.handle('Отель Петербург', sessionIndex: 1),
                    'reattempt_read',
                  )
                : SourceLoop.answer('Fresh read-only comparison.'),
          );
          final emitter = loop.emitter(tester, ui: ui, visible: visible);
          final signal = await backupLoopReal(
            tester,
            () => BackupLoopSignal(
              (regeneration
                      ? emitter.regenerate(_selected(oldReply!))
                      : emitter.retry(_selected(origin)))
                  .finished,
            ),
          );
          await sourceLoopModal(tester, signal);
          loop.noBody();
          final tools = (f.wire.first['tools'] as List)
              .cast<Map<dynamic, dynamic>>();
          expect(tools, hasLength(2));
          expect(tools.map((t) => (t['function'] as Map)['name']), [
            'astoria_sources_list',
            'astoria_source_read',
          ]);
          await loop.apply(tester);
          final result = await loop.join(tester, signal);
          expect(result.saved, isTrue);
          expect(result.message!.status, 'complete');
          expect(result.message!.text, 'Fresh read-only comparison.');
          expect(f.wire, hasLength(3));
          expect(jsonEncode(f.wire), contains(sourceGameBody));
          expect(f.container.exists(supportAppActionRegistryProvider), isFalse);
          final next = await backupLoopReal(
            tester,
            () => modelSourceRecipe(f, result.message!.id),
          );
          expect(next.toolDisclosures, hasLength(regeneration ? 2 : 1));
          if (regeneration) {
            expect(
              next.toolDisclosures!.first.snapshotDigest,
              List.filled(64, 'a').join(),
            );
            expect(
              f.wire.last.toString(),
              isNot(contains(next.toolDisclosures!.first.snapshotDigest)),
            );
          }
          expect(f.native.runtime.epoch, epoch);
          expect(f.native.runtime.snapshot.preferences, policy);
          final journals = await backupLoopReal(
            tester,
            () => f.native.db.select(f.native.db.supportMutationJournal).get(),
          );
          expect(journals, isEmpty);
          _noExcluded(f);
        } finally {
          ui.dispose();
        }
      },
    );
  }

  backupLoopTest(
    'MODEL read-only retry rejects a mutating fake call before base graph or effect preparation',
    (tester, f) async {
      await seedModelSources(tester, f);
      final loop = SourceLoop(f);
      final origin = (await backupLoopReal(
        tester,
        () => f.native.repo.appendCurrentUser(
          message: SupportMessage(
            id: 'mutating-retry-user',
            sessionId: f.native.session,
            role: 'user',
            body: 'Compare the game.',
            runId: 'mutating-user-run',
            createdAt: 3,
          ),
          isCurrent: () => true,
        ),
      ))!;
      final visible = await backupLoopReal(tester, () => _visible(f));
      expect(f.container.exists(supportAppActionRegistryProvider), isFalse);
      final ui = loop.nativeUi(tester);
      try {
        loop.script(
          SourceLoop.call('astoria_preferences_update', {
            'hideTooltips': true,
          }, id: 'forged_mutation'),
          rounds: 1,
        );
        final emitter = loop.emitter(tester, ui: ui, visible: visible);
        final signal = await backupLoopReal(
          tester,
          () => BackupLoopSignal(emitter.retry(_selected(origin)).finished),
        );
        final result = await loop.join(tester, signal);
        expect(result.message!.status, isNot('complete'));
        expect(f.wire, hasLength(1));
        expect(f.wire.single['tools'], hasLength(2));
        expect(f.container.exists(supportAppActionRegistryProvider), isFalse);
        final settings = await backupLoopReal(
          tester,
          () => f.container.read(appSettingsProvider.future),
        );
        expect(settings.hideTooltips, isFalse);
        final journals = await backupLoopReal(
          tester,
          () => f.native.db.select(f.native.db.supportMutationJournal).get(),
        );
        expect(journals, isEmpty);
        loop.noBody();
      } finally {
        ui.dispose();
      }
    },
  );
}
