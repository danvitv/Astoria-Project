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
import 'package:glaze_flutter/features/support_assistant/widgets/support_composer_bar.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';

import 'support_model_source_loop_fixture.dart';

void _noExcluded(BackupLoopFixture f) {
  final outward = jsonEncode(f.wire);
  for (final value in [
    sourceExcluded,
    sourceOlderBody,
    sourceInactiveStudioBody,
  ]) {
    expect(outward, isNot(contains(value)));
  }
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
  WidgetTester tester,
  BackupLoopFixture f,
) => backupLoopReal(
  tester,
  () async => [
    for (final row in await f.native.repo.getMessagesForSession(
      f.native.session,
    ))
      SupportModelConversationMessage(
        id: row.id,
        role: row.role,
        text: row.body,
      ),
  ],
);

Future<SupportModelProvenance> _durable(SourceLoop loop, int count) async {
  final rows = await loop.file.native.repo.getMessagesForSession(
    loop.file.native.session,
  );
  final recipe = await modelSourceRecipe(
    loop.file,
    rows.last.id,
    expectedVersion: 4,
    expectedDisclosureCount: count,
  );
  expect(recipe.toolDisclosures, hasLength(count));
  final outward = jsonEncode(loop.file.wire);
  for (final disclosure in recipe.toolDisclosures!) {
    expect(disclosure.snapshotDigest, hasLength(64));
    expect(outward, isNot(contains(disclosure.snapshotDigest)));
  }
  for (final request in loop.file.wire) {
    for (final message in request['messages'] as List) {
      if (message['role'] == 'tool') {
        expect(
          utf8.encode(message['content'] as String).length,
          lessThanOrEqualTo(65536),
        );
      }
    }
  }
  return recipe;
}

Future<String> _largeStudio(
  WidgetTester tester,
  BackupLoopFixture f, {
  int repeats = 1400,
}) async {
  await seedModelSources(tester, f, messages: 4);
  final content =
      'PAGED_HEAD_$sourceStudioBody'
      '${List.filled(repeats, 'Привет 🐈‍⬛ \\ " ').join()}_PAGED_TAIL';
  await backupLoopReal(
    tester,
    () =>
        (f.native.db.update(
          f.native.db.studioPresetRows,
        )..where((t) => t.presetId.equals(sourceStudio))).write(
          StudioPresetRowsCompanion(
            blocksJson: Value(
              jsonEncode([
                {
                  'id': 'large-instruction',
                  'type': 'instruction',
                  'content': content,
                },
              ]),
            ),
          ),
        ),
  );
  expect(utf8.encode(jsonEncode(content)).length, greaterThan(24000));
  return content;
}

/// Stop AFTER the actual OUTER encrypted source-extension COMMIT, before Drift
/// returns its reservation. The original native executor and result are intact.
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

  backupLoopTest(
    'MODEL logical Studio continuation reconstructs complete saved text under one frozen scope',
    (tester, f) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pump();
      final content = await _largeStudio(tester, f);
      final loop = SourceLoop(f);
      late String source;
      final chunks = <String>[];
      var disclosures = 0;
      loop.script(
        loop.list('studioPreset', 'large_catalog'),
        rounds: 8,
        next: (round) async {
          if (round == 2) {
            loop.noBody();
            source = loop.activeStudioHandle();
            return loop.contents(source, 'large_contents');
          }
          disclosures++;
          await _durable(
            loop,
            disclosures,
          ); // encrypted v4 BEFORE this actual POST
          if (round == 3) {
            return loop.search(source, 'PAGED_HEAD_', 'large_search');
          }
          if (round == 4) {
            return loop.read(source, loop.selector(), 'large_read');
          }
          final body = loop.body();
          final piece = (body['pieces'] as List).single as Map;
          chunks.add(piece['payload'] as String);
          expect(body['partial'], isTrue);
          expect(
            piece['complete'],
            isFalse,
          ); // a continuation is not the full unit
          expect(
            find.byKey(const ValueKey('support_tool_confirmation_accept')),
            findsNothing,
          );
          if (body['nextCursor'] != null) {
            expect(body['complete'], isFalse);
            return loop.read(
              source,
              body['nextCursor'] as String,
              'large_continue_$round',
            );
          }
          expect(
            body['complete'],
            isTrue,
          ); // full reconstruction only after this tail
          return SourceLoop.answer(
            'The complete current SAVED instruction is reconstructed; historical use is unknown.',
          );
        },
      );
      await loop.start(tester);
      await loop.apply(tester);
      final reply = await loop.finish(tester);
      expect(reply.status, 'complete');
      expect(chunks.length, greaterThan(1));
      expect(chunks.join(), content);
      final recipe = await backupLoopReal(
        tester,
        () => modelSourceRecipe(
          f,
          reply.id,
          expectedVersion: 4,
          expectedDisclosureCount: disclosures,
        ),
      );
      expect(recipe.toolDisclosures, hasLength(disclosures));
      expect(
        recipe.toolDisclosures!.every(
          (d) => d.domain == SupportModelToolDisclosureDomain.studioPreset,
        ),
        isTrue,
      );
      expect(
        recipe.toolDisclosures!
            .where(
              (d) => d.operation == SupportModelToolDisclosureOperation.read,
            )
            .length,
        chunks.length,
      );
      expect(jsonEncode(f.wire), isNot(contains(sourceGameBody)));
      _noExcluded(f);
    },
  );

  for (final failure in ['stop', 'changedOutsideFirstPart']) {
    backupLoopTest(
      'MODEL $failure retires logical continuation without disclosing the remaining saved text',
      (tester, f) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pump();
        // Stay inside saved-unit admission, but beyond the escaped partial-read
        // budget. The continuation must exist, not fail on initial source size.
        final content = await _largeStudio(tester, f);
        expect(utf8.encode(jsonEncode(content)).length, lessThan(65536));
        final loop = SourceLoop(f);
        late VoidCallback stopOriginal;
        late String source;
        var continuationAttempted = false;
        loop.script(
          loop.list('studioPreset', 'partial_catalog'),
          rounds: 5,
          next: (round) async {
            if (round == 2) {
              source = loop.activeStudioHandle();
              return loop.contents(source, 'partial_contents');
            }
            if (round == 3) {
              await _durable(loop, 1);
              return loop.search(source, 'PAGED_HEAD_', 'partial_search');
            }
            if (round == 4) {
              await _durable(loop, 2);
              return loop.read(source, loop.selector(), 'partial_read');
            }
            await _durable(loop, 3);
            final body = loop.body();
            expect(body['complete'], isFalse);
            expect(body['partial'], isTrue);
            final next = body['nextCursor'] as String;
            final piece = (body['pieces'] as List).single as Map;
            final firstPart = piece['payload'] as String;
            expect(piece['complete'], isFalse);
            expect(firstPart, startsWith('PAGED_HEAD_'));
            expect(content, startsWith(firstPart));
            expect(firstPart.length, lessThan(content.length));
            expect(
              content.substring(firstPart.length),
              endsWith('_PAGED_TAIL'),
            );
            expect(jsonEncode(f.wire), contains('PAGED_HEAD_'));
            expect(jsonEncode(f.wire), isNot(contains('_PAGED_TAIL')));
            if (failure == 'stop') {
              stopOriginal();
            } else {
              final row = await (f.native.db.select(
                f.native.db.studioPresetRows,
              )..where((t) => t.presetId.equals(sourceStudio))).getSingle();
              await (f.native.db.update(
                f.native.db.studioPresetRows,
              )..where((t) => t.presetId.equals(sourceStudio))).write(
                StudioPresetRowsCompanion(
                  blocksJson: Value(
                    row.blocksJson.replaceFirst('_PAGED_TAIL', '_CHANGED_TAIL'),
                  ),
                ),
              );
            }
            continuationAttempted = true;
            return loop.read(source, next, 'retired_continue');
          },
        );
        await loop.start(tester);
        stopOriginal = tester
            .widget<SupportComposerBar>(find.byType(SupportComposerBar))
            .onStop!;
        await loop.apply(tester);
        final reply = await loop.finish(tester);
        expect(continuationAttempted, isTrue);
        expect(reply.status, failure == 'stop' ? 'stopped' : 'error');
        expect(f.wire, hasLength(5));
        expect(jsonEncode(f.wire), isNot(contains('_PAGED_TAIL')));
        expect(jsonEncode(f.wire), isNot(contains('_CHANGED_TAIL')));
        final recipe = await backupLoopReal(
          tester,
          () => modelSourceRecipe(
            f,
            reply.id,
            expectedVersion: 4,
            expectedDisclosureCount: 3,
          ),
        );
        expect(recipe.toolDisclosures, hasLength(3));
        _noExcluded(f);
      },
    );
  }

  // Same-scope continuation no longer invents a second consent. Refusal is
  // still tested on a genuinely NEW source scope after an admitted game body.
  backupLoopTest(
    'MODEL refuses another source after approved game without granting Studio continuation',
    (tester, f) async {
      await _largeStudio(tester, f, repeats: 2400);
      final loop = SourceLoop(f);
      late String game, studio;
      loop.script(
        loop.list('game', 'before_refusal'),
        rounds: 7,
        next: (round) async {
          if (round == 2) {
            game = loop.handle();
            return loop.contents(game, 'game_scope');
          }
          if (round == 3) return loop.read(game, loop.selector(), 'game_body');
          if (round == 4) {
            await _durable(loop, 2);
            return loop.list('studioPreset', 'new_source');
          }
          if (round == 5) {
            studio = loop.activeStudioHandle();
            return loop.contents(studio, 'refuse_studio');
          }
          expect(loop.lastResult()['ok'], isFalse);
          expect(loop.lastResult()['code'], 'denied');
          expect(loop.lastResult()['effect'], 'none');
          return SourceLoop.answer(
            'Only the approved game excerpt was read. The Studio instruction is incomplete and was not read.',
          );
        },
      );
      await loop.start(tester);
      await loop.apply(tester);
      await loop.modal(tester);
      await loop.cancel(tester);
      final reply = await loop.finish(tester);
      expect(reply.status, 'error');
      expect(f.bridge.view.transportReason.name, 'denied');
      expect(
        reply.body,
        contains('Нативное согласие на эту область не получено или отозвано'),
      );
      expect(
        reply.body,
        isNot(contains('Only the approved game excerpt was read.')),
      );
      expect(jsonEncode(f.wire), contains('${sourceGameBody}0'));
      expect(jsonEncode(f.wire), isNot(contains('PAGED_HEAD_')));
      final recipe = await backupLoopReal(
        tester,
        () => modelSourceRecipe(
          f,
          reply.id,
          expectedVersion: 4,
          expectedDisclosureCount: 2,
        ),
      );
      expect(recipe.toolDisclosures, hasLength(2));
      _noExcluded(f);
    },
  );

  backupLoopTest(
    'MODEL native screen generic connection consent remains real and durable',
    (tester, f) async {
      await seedModelSources(tester, f, messages: 4);
      final loop = SourceLoop(f);
      final bridge = f.bridge;
      final ui = loop.nativeUi(tester);
      final emitter = loop.emitter(
        tester,
        ui: ui,
        visible: await _visible(tester, f),
      );
      loop.script(
        SourceLoop.call('astoria_connection_create', {
          'template': 'openaiChat',
          'name': 'screen-native-create',
          'model': 'gpt-4o-mini',
        }, id: 'screen_create'),
        rounds: 1,
      );
      final original = f.native.runtime.snapshot.preferences;
      final signal = await backupLoopReal(
        tester,
        () => BackupLoopSignal(
          emitter
              .send(
                text: 'Create an empty connection.',
                draftRevision: 1,
                isDraftCurrent: () => true,
              )
              .finished,
        ),
      );
      await loop.modal(tester, signal: signal);
      await loop.apply(tester);
      await loop.join(tester, signal);
      final row = await (f.native.db.select(
        f.native.db.apiConfigs,
      )..where((t) => t.name.equals('screen-native-create'))).getSingle();
      final created = await backupLoopReal(
        tester,
        () => ApiConfigRepo(f.native.db).getById(row.configId),
      );
      expect(created, isNotNull);
      expect(created!.apiKey, isEmpty);
      expect(f.native.runtime.snapshot.preferences, original);
      expect(bridge.view.busy, isFalse);
      expect(f.wire, hasLength(1));
      loop.noBody();
      _noExcluded(f);
      ui.dispose();
    },
  );

  backupLoopTest(
    'MODEL batched catalogs admit exact game and raw Studio dialect under separate real scopes',
    (tester, f) async {
      const privateAgentId = 'PRIVATE_STUDIO_AGENT_CANARY_7C3E91B4';
      await seedModelSources(
        tester,
        f,
        messages: 4,
        studioJson: jsonEncode([
          {
            'id': 'raw-seed',
            'name': 'Raw saved name',
            'kind': 'custom_text',
            'content': sourceStudioBody,
            'enabled': true,
          },
        ]),
      );
      await backupLoopReal(
        tester,
        () =>
            (f.native.db.update(
              f.native.db.studioPresetRows,
            )..where((t) => t.presetId.equals(sourceStudio))).write(
              StudioPresetRowsCompanion(
                agentsJson: Value(
                  jsonEncode([
                    {
                      'id': privateAgentId,
                      'name': 'Continuity',
                      'enabled': true,
                    },
                  ]),
                ),
                runtimeSettingsJson: Value(
                  jsonEncode({
                    'agentEnabledBeforeDependencyOff': {privateAgentId: false},
                  }),
                ),
              ),
            ),
      );
      final loop = SourceLoop(f);
      late String game, studio;
      final batch = loop.list('game', 'batch_game');
      final firstMessage =
          ((batch['choices'] as List).single['message'] as Map);
      (firstMessage['tool_calls'] as List).addAll(
        ((loop.list('studioPreset', 'batch_studio')['choices'] as List)
                    .single['message']
                as Map)['tool_calls']
            as List,
      );
      loop.script(
        batch,
        rounds: 7,
        next: (round) async {
          if (round == 2) {
            loop.noBody();
            final messages = (f.wire.last['messages'] as List)
                .where((m) => m['role'] == 'tool')
                .toList();
            final data = jsonDecode(
              messages[messages.length - 2]['content'] as String,
            )['data'];
            game = (data['pieces'] as List).single['source'] as String;
            studio = loop.activeStudioHandle();
            return loop.contents(game, 'batch_game_scope');
          }
          if (round == 3) {
            return loop.read(game, loop.selector(), 'batch_game_read');
          }
          if (round == 4) {
            await _durable(loop, 2);
            return loop.contents(studio, 'batch_studio_scope');
          }
          if (round == 5) {
            return loop.search(studio, sourceStudioBody, 'batch_studio_search');
          }
          if (round == 6) {
            return loop.read(studio, loop.selector(), 'batch_studio_read');
          }
          await _durable(loop, 5);
          expect(jsonEncode(loop.body()), contains(sourceStudioBody));
          return SourceLoop.answer(
            'Current SAVED raw Studio text and the approved game were compared; historical prompt use is unknown.',
          );
        },
      );
      await loop.start(tester);
      await loop.apply(tester);
      await loop.modal(tester);
      await loop.apply(tester);
      final reply = await loop.finish(tester);
      expect(reply.status, 'complete');
      final recipe = await backupLoopReal(
        tester,
        () => modelSourceRecipe(
          f,
          reply.id,
          expectedVersion: 4,
          expectedDisclosureCount: 5,
        ),
      );
      expect(recipe.toolDisclosures!.map((d) => d.domain.name), [
        'game',
        'game',
        'studioPreset',
        'studioPreset',
        'studioPreset',
      ]);
      expect(f.wire, hasLength(7));
      expect(jsonEncode(f.wire), contains(sourceGameBody));
      expect(jsonEncode(f.wire), contains(sourceStudioBody));
      expect(
        jsonEncode(f.wire),
        isNot(contains(privateAgentId)),
      ); // private reference id
      _noExcluded(f);
    },
  );

  backupLoopTest(
    'MODEL exact recipient encrypted sources never warm the next cached Send',
    (tester, f) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pump();
      await seedModelSources(tester, f, messages: 4);
      final loop = SourceLoop(f);
      late String game, studio;
      final originalPolicy = f.native.runtime.snapshot.preferences;
      final epoch = f.native.runtime.epoch;
      final originalModel = f.native.api.model;
      final encryptRounds = <int>[];
      f.native.primitive.afterEncrypt = (aad) async {
        if (aad.contains('|support.reply_provenance:') &&
            aad.endsWith('|protected_facts_ciphertext')) {
          encryptRounds.add(f.wire.length);
        }
      };
      loop.script(
        loop.list('game', 'metadata_game'),
        rounds: 8,
        next: (round) async {
          if (round == 2) {
            loop.noBody();
            final piece = (loop.lastData()['pieces'] as List).single as Map;
            expect(piece['label'], 'game');
            expect(piece['historicalUse'], 'unknown');
            expect(
              piece['activeAtListing'],
              isNull,
            ); // not guessed from updated_at
            expect(loop.lastData()['complete'], isFalse);
            expect(loop.lastData()['count'], 1);
            expect(loop.lastData()['incompleteReason'], 'localTargetSelection');
            expect(
              jsonEncode(loop.lastData()),
              isNot(contains('Отель Петербург')),
            );
            game = loop.handle();
            return loop.contents(game, 'metadata_scope');
          }
          if (round == 3) {
            expect(encryptRounds, contains(2));
            await _durable(loop, 1);
            return loop.read(game, loop.selector(), 'metadata_read');
          }
          if (round == 4) {
            await _durable(loop, 2);
            return loop.list('studioPreset', 'metadata_studio');
          }
          if (round == 5) {
            final piece = (loop.lastData()['pieces'] as List).single as Map;
            expect(piece['label'], 'studioPreset');
            expect(piece['state'], 'currentSaved');
            expect(piece['activeAtListing'], isTrue);
            expect(piece['historicalUse'], 'unknown');
            studio = loop.activeStudioHandle();
            return loop.contents(studio, 'metadata_studio_scope');
          }
          if (round == 6) {
            return loop.search(
              studio,
              sourceStudioBody,
              'metadata_studio_search',
            );
          }
          if (round == 7) {
            return loop.read(studio, loop.selector(), 'metadata_studio_read');
          }
          await _durable(loop, 5);
          return SourceLoop.answer(
            'Only approved game text and the current SAVED Studio definition were compared.',
          );
        },
      );
      await loop.start(tester);
      final preview = find.byKey(
        const ValueKey('support_tool_confirmation_preview'),
      );
      final previewText = tester
          .widgetList<Text>(
            find.descendant(of: preview, matching: find.byType(Text)),
          )
          .map((t) => t.data)
          .join();
      expect(previewText, contains('Модель: $originalModel\n'));
      expect(
        previewText,
        contains(
          'Активные сообщения 1–4; границы заморожены, новые сообщения не включаются',
        ),
      );
      final accept = find.byKey(
        const ValueKey('support_tool_confirmation_accept'),
      );
      final acceptButton = tester.widget<GlazeActionButton>(accept);
      expect(acceptButton.maxLabelLines, isNull);
      expect(acceptButton.onTap, isNotNull);
      final render = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: accept,
          matching: find.text('Прочитать и передать модели'),
        ),
      );
      expect(render.didExceedMaxLines, isFalse);
      expect(render.maxLines, isNull);
      expect(render.overflow, TextOverflow.visible);
      // The kit deliberately paints an unbounded wrapping label. Its overflow
      // enum alone proves neither clipping nor fit: check every laid-out glyph
      // box inside the actual enabled button and mobile viewport.
      expect(render.text.toPlainText(), acceptButton.label);
      expect(acceptButton.busy, isFalse);
      expect(accept.hitTestable(), findsOneWidget);
      final buttonRect = tester.getRect(accept);
      final viewport =
          Offset.zero &
          (tester.view.physicalSize / tester.view.devicePixelRatio);
      final boxes = render.getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: acceptButton.label.length),
      );
      expect(boxes, isNotEmpty);
      for (final box in boxes) {
        final rect = box.toRect();
        final topLeft = render.localToGlobal(rect.topLeft);
        final bottomRight = render.localToGlobal(rect.bottomRight);
        expect(buttonRect.contains(topLeft), isTrue);
        expect(buttonRect.contains(bottomRight), isTrue);
        expect(viewport.contains(topLeft), isTrue);
        expect(viewport.contains(bottomRight), isTrue);
      }
      await loop.apply(tester);
      await loop.modal(tester);
      await loop.apply(tester);
      final reply = await loop.finish(tester);
      expect(reply.status, 'complete');
      expect(f.wire.first['tools'], hasLength(47));
      expect(
        f.bridge.view.toolActivities.any(
          (a) => jsonEncode([a.sourceLabel, a.detail]).contains(sourceGameBody),
        ),
        isFalse,
      );
      final recipe = await backupLoopReal(
        tester,
        () => modelSourceRecipe(
          f,
          reply.id,
          expectedVersion: 4,
          expectedDisclosureCount: 5,
        ),
      );
      expect(
        recipe.originalRanges.every((r) => r.sessionId == f.native.session),
        isTrue,
      );
      expect(recipe.toolDisclosures!.map((d) => d.sourceId), [
        sourceSession,
        sourceSession,
        sourceStudio,
        sourceStudio,
        sourceStudio,
      ]);
      final cachedStart = f.wire.length;
      loop.script(
        SourceLoop.answer('No new source reading was approved.'),
        rounds: 1,
      );
      await loop.start(tester, confirmation: false);
      final cached = await loop.finish(tester);
      expect(cached.status, 'complete');
      final cachedRequests = f.wire.skip(cachedStart).toList();
      expect(cachedRequests, hasLength(1));
      for (final message in cachedRequests.single['messages'] as List) {
        expect(message['role'], isNot('tool'));
        expect(message['tool_calls'], isNull);
      }
      expect(f.bridge.view.toolActivities, isEmpty);
      expect(
        find.byKey(const ValueKey('support_tool_confirmation_accept')),
        findsNothing,
      );
      final cachedWire = jsonEncode(cachedRequests);
      for (final value in [
        sourceGameBody,
        sourceStudioBody,
        ...recipe.toolDisclosures!.map((d) => d.snapshotDigest),
      ]) {
        expect(cachedWire, isNot(contains(value)));
      }
      final cachedRecipe = await backupLoopReal(
        tester,
        () => modelSourceRecipe(
          f,
          cached.id,
          expectedVersion: 4,
          expectedDisclosureCount: 5,
        ),
      );
      // Cached own-chat input retains historical provenance, not source bodies
      // or fresh read authority. Preserve every original field and its order.
      final retainedDisclosures = cachedRecipe.toolDisclosures!;
      final originalDisclosures = recipe.toolDisclosures!;
      expect(retainedDisclosures, hasLength(5));
      for (var i = 0; i < originalDisclosures.length; i++) {
        final retained = retainedDisclosures[i];
        final original = originalDisclosures[i];
        expect(retained.domain, original.domain);
        expect(retained.sourceId, original.sourceId);
        expect(retained.orderedSourceIds, original.orderedSourceIds);
        expect(retained.snapshotDigest, original.snapshotDigest);
        expect(retained.operation, original.operation);
        expect(retained.extent, original.extent);
      }
      expect(f.native.runtime.snapshot.preferences, originalPolicy);
      expect(f.native.runtime.epoch, epoch);
      for (final request in f.requests) {
        expect(
          request.uri.toString(),
          'https://api.openai.com/v1/chat/completions',
        );
      }
      expect(loop.dispatchAuthorizations, hasLength(f.requests.length));
      expect(
        loop.dispatchAuthorizations,
        everyElement('Bearer ${BackupLoopNative.key}'),
      );
      for (final request in f.wire) {
        expect(request['model'], originalModel);
      }
      _noExcluded(f);
    },
  );

  for (final failure in ['refuse', 'stop', 'routeABA', 'sourceABA']) {
    backupLoopTest(
      'MODEL $failure during source consent retires without body or global warming',
      (tester, f) async {
        await seedModelSources(tester, f, messages: 4);
        final loop = SourceLoop(f);
        final originalPolicy = f.native.runtime.snapshot.preferences;
        final epoch = f.native.runtime.epoch;
        loop.script(
          loop.list('game', '${failure}_catalog'),
          rounds: failure == 'refuse' ? 3 : 2,
          next: (round) {
            if (round == 2) {
              return loop.contents(loop.handle(), '${failure}_scope');
            }
            expect(loop.lastResult()['ok'], isFalse);
            expect(loop.lastResult()['code'], 'denied');
            expect(loop.lastResult()['effect'], 'none');
            return SourceLoop.answer('The source was not read.');
          },
        );
        await loop.start(tester);
        final stop = tester
            .widget<SupportComposerBar>(find.byType(SupportComposerBar))
            .onStop;
        if (failure == 'refuse') {
          await loop.cancel(tester);
        } else if (failure == 'sourceABA') {
          await backupLoopReal(tester, () async {
            final row = await (f.native.db.select(
              f.native.db.chatSessions,
            )..where((t) => t.sessionId.equals(sourceSession))).getSingle();
            await f.native.db.customStatement(
              'UPDATE chat_sessions SET messages_json = ? WHERE session_id = ?',
              ['[]', sourceSession],
            );
            await f.native.db.customStatement(
              'UPDATE chat_sessions SET messages_json = ? WHERE session_id = ?',
              [row.messagesJson, sourceSession],
            );
          });
          await loop.apply(tester);
        } else {
          final route = ModalRoute.of<void>(
            tester.element(
              find.byKey(const ValueKey('support_tool_confirmation_accept')),
            ),
          )!;
          await backupLoopReal(tester, () async {
            if (failure == 'stop') {
              stop!();
            } else {
              f.router.go('/characters');
              f.router.go('/support');
            }
          });
          await sourceLoopRouteClosed(tester, route);
        }
        final reply = await loop.finish(tester);
        expect(
          reply.status,
          failure == 'refuse'
              ? 'error'
              : failure == 'sourceABA'
              ? 'error'
              : 'stopped',
        );
        if (failure == 'refuse') {
          expect(f.bridge.view.transportReason.name, 'denied');
          expect(
            reply.body,
            contains(
              'Нативное согласие на эту область не получено или отозвано',
            ),
          );
          expect(reply.body, isNot(contains('The source was not read.')));
        }
        expect(f.wire, hasLength(failure == 'refuse' ? 3 : 2));
        loop.noBody();
        expect(
          find.byKey(const ValueKey('support_tool_confirmation_accept')),
          findsNothing,
        );
        final recipe = await backupLoopReal(
          tester,
          () => modelSourceRecipe(
            f,
            reply.id,
            expectedVersion: 2,
            expectedDisclosureCount: null,
          ),
        );
        expect(recipe.toolDisclosures, isNull);
        expect(f.native.runtime.snapshot.preferences, originalPolicy);
        expect(f.native.runtime.epoch, epoch);
        _noExcluded(f);
      },
    );
  }

  backupLoopTest(
    'MODEL Stop after durable source COMMIT settles exact advanced reservation without body POST',
    (tester, f) async {
      await seedModelSources(tester, f, messages: 4);
      final loop = SourceLoop(f);
      final bridge = f.bridge;
      final ui = loop.nativeUi(tester);
      final emitter = loop.emitter(
        tester,
        ui: ui,
        visible: await _visible(tester, f),
      );
      SupportModelUiSend? originalSend;
      final interceptor = _StopAfterSourceCommit(() => originalSend!.stop());
      loop.script(
        loop.list('game', 'commit_catalog'),
        rounds: 2,
        next: (_) => loop.contents(loop.handle(), 'commit_scope'),
      );
      final signal = await backupLoopReal(
        tester,
        () => BackupLoopSignal(
          f.native.db.runWithInterceptor(() async {
            originalSend = emitter.send(
              text: 'Read the selected game.',
              draftRevision: 1,
              isDraftCurrent: () => true,
            );
            return await originalSend!.finished;
          }, interceptor: interceptor),
        ),
      );
      await loop.modal(tester, signal: signal);
      await loop.apply(tester);
      await loop.join(tester, signal);
      final reply = (await backupLoopReal(
        tester,
        () => f.native.repo.getMessagesForSession(f.native.session),
      )).last;
      expect(interceptor.committedSourceWrites, 1);
      expect(reply.status, 'stopped');
      expect(bridge.view.busy, isFalse);
      expect(f.wire, hasLength(2));
      loop.noBody();
      final recipe = await backupLoopReal(
        tester,
        () => modelSourceRecipe(
          f,
          reply.id,
          expectedVersion: 4,
          expectedDisclosureCount: 1,
        ),
      );
      expect(recipe.toolDisclosures, hasLength(1));
      expect(
        recipe.toolDisclosures!.single.orderedSourceIds,
        List.generate(4, (i) => 'model-source-$i'),
      );
      expect(
        recipe.toolDisclosures!.single.extent,
        SupportModelToolDisclosureExtent.scopeMetadata,
      );
      expect(
        recipe.toolDisclosures!.single.operation,
        SupportModelToolDisclosureOperation.contents,
      );
      expect(recipe.toolDisclosures!.single.sourceId, sourceSession);
      _noExcluded(f);
      ui.dispose();
    },
  );

  backupLoopTest(
    'MODEL original source mutation after body POST denies the next actual replay POST',
    (tester, f) async {
      await seedModelSources(tester, f, messages: 4);
      final loop = SourceLoop(f);
      late String source;
      loop.script(
        loop.list('game', 'replay_catalog'),
        rounds: 4,
        next: (round) async {
          if (round == 2) {
            source = loop.handle();
            return loop.contents(source, 'replay_scope');
          }
          if (round == 3) {
            return loop.read(source, loop.selector(), 'replay_read');
          }
          await _durable(loop, 2);
          expect(jsonEncode(f.wire), contains(sourceGameBody));
          await f.native.db.customStatement(
            'UPDATE chat_sessions SET messages_json = ? WHERE session_id = ?',
            ['[]', sourceSession],
          );
          return loop.list('studioPreset', 'after_changed_body');
        },
      );
      await loop.start(tester);
      await loop.apply(tester);
      final reply = await loop.finish(tester);
      expect(reply.status, 'error');
      expect(f.wire, hasLength(4));
      final recipe = await backupLoopReal(
        tester,
        () => modelSourceRecipe(
          f,
          reply.id,
          expectedVersion: 4,
          expectedDisclosureCount: 2,
        ),
      );
      expect(recipe.toolDisclosures, hasLength(2));
      _noExcluded(f);
    },
  );

  backupLoopTest(
    'MODEL refused run-local handle cannot be reused by a later Send',
    (tester, f) async {
      await seedModelSources(tester, f, messages: 4);
      final loop = SourceLoop(f);
      late String old;
      loop.script(
        loop.list('game', 'stale_catalog'),
        rounds: 3,
        next: (round) {
          if (round == 2) {
            old = loop.handle();
            return loop.contents(old, 'refused_scope');
          }
          expect(loop.lastResult()['ok'], isFalse);
          expect(loop.lastResult()['code'], 'denied');
          expect(loop.lastResult()['effect'], 'none');
          return SourceLoop.answer('Not read.');
        },
      );
      await loop.start(tester);
      await loop.cancel(tester);
      final refused = await loop.finish(tester);
      expect(refused.status, 'error');
      expect(f.bridge.view.transportReason.name, 'denied');
      expect(
        refused.body,
        contains('Нативное согласие на эту область не получено или отозвано'),
      );
      loop.script(
        loop.contents(old, 'reused_handle'),
        rounds: 2,
        next: (_) {
          expect(loop.lastResult()['ok'], isFalse);
          expect(loop.lastResult()['code'], 'denied');
          expect(loop.lastResult()['effect'], 'none');
          return SourceLoop.answer('Old handles are not grants.');
        },
      );
      await loop.start(tester, confirmation: false);
      final reply = await loop.finish(tester);
      expect(reply.status, 'error');
      expect(f.bridge.view.transportReason.name, 'denied');
      expect(
        reply.body,
        contains(
          'Модель передала невыданную ссылку или неподдерживаемые параметры',
        ),
      );
      expect(reply.body, isNot(contains('Old handles are not grants.')));
      loop.noBody();
      expect(
        find.byKey(const ValueKey('support_tool_confirmation_accept')),
        findsNothing,
      );
      final recipe = await backupLoopReal(
        tester,
        () => modelSourceRecipe(
          f,
          reply.id,
          expectedVersion: 2,
          expectedDisclosureCount: null,
        ),
      );
      expect(recipe.toolDisclosures, isNull);
      _noExcluded(f);
    },
  );

  backupLoopTest(
    'MODEL missing original native UI refuses catalog without source bodies or grants',
    (tester, f) async {
      await seedModelSources(tester, f, messages: 4);
      final loop = SourceLoop(f);
      final ui = loop.nativeUi(tester);
      final emitter = loop.emitter(tester, visible: await _visible(tester, f));
      loop.script(
        loop.list('game', 'no_ui'),
        rounds: 2,
        next: (_) {
          expect(loop.lastResult()['ok'], isFalse);
          expect(loop.lastResult()['code'], 'unavailable');
          expect(loop.lastResult()['effect'], 'none');
          return SourceLoop.answer('The original consent UI is unavailable.');
        },
      );
      final signal = await backupLoopReal(
        tester,
        () => BackupLoopSignal(
          emitter
              .send(
                text: 'Read the game.',
                draftRevision: 1,
                isDraftCurrent: () => true,
              )
              .finished,
        ),
      );
      await loop.join(tester, signal);
      loop.checkScript();
      loop.noBody();
      expect(f.wire, hasLength(2));
      final reply = (await backupLoopReal(
        tester,
        () => f.native.repo.getMessagesForSession(f.native.session),
      )).last;
      expect(reply.status, 'error');
      expect(f.bridge.view.transportReason.name, 'denied');
      expect(
        reply.body,
        isNot(contains('The original consent UI is unavailable.')),
      );
      expect(
        reply.body,
        contains(
          'Источник недоступен для этого чтения; текст не передан модели',
        ),
      );
      final recipe = await backupLoopReal(
        tester,
        () => modelSourceRecipe(
          f,
          reply.id,
          expectedVersion: 2,
          expectedDisclosureCount: null,
        ),
      );
      expect(recipe.toolDisclosures, isNull);
      expect(
        find.byKey(const ValueKey('support_tool_confirmation_accept')),
        findsNothing,
      );
      _noExcluded(f);
      ui.dispose();
    },
  );

  backupLoopTest(
    'MODEL missing original native UI refuses body approval without source bodies or grants',
    (tester, f) async {
      await seedModelSources(tester, f, messages: 4);
      final loop = SourceLoop(f);
      final ui = loop.nativeUi(tester);
      final emitter = loop.emitter(tester, visible: await _visible(tester, f));
      loop.script(
        loop.contents('unissued-source', 'no_ui_body'),
        rounds: 2,
        next: (_) {
          // The registry must refuse absent authority before preparing a source
          // or asking the engine for a grant, even with valid argument shape.
          expect(loop.lastResult()['ok'], isFalse);
          expect(loop.lastResult()['code'], 'unavailable');
          expect(loop.lastResult()['effect'], 'none');
          return SourceLoop.answer('No native body approval was available.');
        },
      );
      final signal = await backupLoopReal(
        tester,
        () => BackupLoopSignal(
          emitter
              .send(
                text: 'Read the game.',
                draftRevision: 1,
                isDraftCurrent: () => true,
              )
              .finished,
        ),
      );
      await loop.join(tester, signal);
      loop.checkScript();
      loop.noBody();
      expect(f.wire, hasLength(2));
      final reply = (await backupLoopReal(
        tester,
        () => f.native.repo.getMessagesForSession(f.native.session),
      )).last;
      expect(reply.status, 'error');
      expect(f.bridge.view.transportReason.name, 'denied');
      expect(
        reply.body,
        isNot(contains('No native body approval was available.')),
      );
      final recipe = await backupLoopReal(
        tester,
        () => modelSourceRecipe(
          f,
          reply.id,
          expectedVersion: 2,
          expectedDisclosureCount: null,
        ),
      );
      expect(recipe.toolDisclosures, isNull);
      expect(
        find.byKey(const ValueKey('support_tool_confirmation_accept')),
        findsNothing,
      );
      _noExcluded(f);
      ui.dispose();
    },
  );

  for (final negative in [
    'unsupportedStudio',
    'malformedStudio',
    'malformedGame',
    'historicalStudioSelector',
    'unpreparedHugeHistory',
    'oversizeRange',
    'forgedNativeId',
    'legacyArgumentAlias',
  ]) {
    backupLoopTest(
      'MODEL strict native source control $negative preserves no-body refusal',
      (tester, f) async {
        await seedModelSources(
          tester,
          f,
          messages: negative == 'unpreparedHugeHistory' ? 2001 : 4,
          prepareHistory:
              negative != 'unpreparedHugeHistory' &&
              negative != 'oversizeRange' &&
              negative != 'malformedGame',
          studioJson: negative == 'unsupportedStudio'
              ? '[{"id":"future","type":"futureCode","content":"$sourceStudioBody"}]'
              : negative == 'malformedStudio'
              ? '{broken'
              : null,
        );
        if (negative == 'malformedGame' || negative == 'oversizeRange') {
          await backupLoopReal(tester, () async {
            final json = negative == 'malformedGame'
                ? '{broken'
                : jsonEncode(
                    List.generate(
                      4,
                      (i) => {
                        'id': 'model-source-$i',
                        'role': 'assistant',
                        // Each saved message fits admission, but FOUR ordinary
                        // complete payloads exceed the engine wire cap.
                        'content':
                            '$sourceGameBody${List.filled(17000, 'a').join()}',
                      },
                    ),
                  );
            await f.native.db.customStatement(
              'UPDATE chat_sessions SET messages_json = ? WHERE session_id = ?',
              [json, sourceSession],
            );
            if (negative == 'oversizeRange') {
              final messages = jsonDecode(json) as List;
              for (final message in messages) {
                expect(
                  utf8.encode(jsonEncode(message)).length,
                  lessThan(65536),
                );
              }
              final payloads = messages.map((m) => m['content'] as String);
              // Unclipped bodies alone exceed the engine bound, even before
              // JSON encoding or host-envelope escaping adds any overhead.
              expect(utf8.encode(payloads.join()).length, greaterThan(65536));
            }
          });
        }
        final studio = negative.contains('Studio');
        final strictStudio =
            negative == 'unsupportedStudio' || negative == 'malformedStudio';
        // Make strict shape cases unambiguous: local selection cannot be used to
        // mask malformed/unprepared source admission or manufacture a body grant.
        await backupLoopReal(tester, () async {
          await f.native.db.customStatement(
            'DELETE FROM chat_sessions WHERE session_id = ?',
            [sourceOlderSession],
          );
          await f.native.db.customStatement(
            'DELETE FROM studio_preset_rows WHERE preset_id <> ?',
            [sourceStudio],
          );
          if (negative == 'oversizeRange') {
            // Prepare the final saved setup, after all source-row changes.
            final result = await f.native.db.historySourceIndex.maintain(
              sessionId: sourceSession,
              isCurrent: () => true,
            );
            expect(result.state.name, 'ready');
            final indexed = await f.native.db.historySourceIndex.observe(
              sourceSession,
            );
            expect(indexed['status'], 'ready');
            expect(indexed['activeCount'], 4);
          }
        });
        final loop = SourceLoop(f);
        late String source;
        var issuedOversizeRead = false;
        final fake =
            negative == 'forgedNativeId' || negative == 'legacyArgumentAlias';
        final initial = negative == 'legacyArgumentAlias'
            ? SourceLoop.call('astoria_source_read', {
                'opaqueHandle': sourceSession,
                'activeMessageOffset': 0,
              }, id: 'forged_old_alias')
            : fake
            ? loop.contents(sourceSession, 'forged_native_id')
            : loop.list(studio ? 'studioPreset' : 'game', 'strict_catalog');
        loop.script(
          initial,
          rounds: negative == 'oversizeRange' || strictStudio
              ? 4
              : fake
              ? 2
              : 3,
          next: (round) async {
            if (!fake && round == 2) {
              source = loop.handle();
              if (negative == 'historicalStudioSelector') {
                return loop.read(
                  source,
                  'invented_historical_selector',
                  'forged_history',
                );
              }
              return loop.contents(source, 'strict_scope');
            }
            if (strictStudio && round == 3) {
              final recipe = await _durable(loop, 1);
              final disclosure = recipe.toolDisclosures!.single;
              expect(
                disclosure.extent,
                SupportModelToolDisclosureExtent.scopeMetadata,
              );
              expect(
                disclosure.operation,
                SupportModelToolDisclosureOperation.contents,
              );
              expect(disclosure.sourceId, sourceStudio);
              loop.noBody();
              final section = (loop.body()['pieces'] as List).singleWhere(
                (piece) => piece['kind'] == 'studioBlock',
              );
              return loop.contents(
                source,
                'strict_studio_blocks',
                section: section['selector'] as String,
              );
            }
            if (negative == 'oversizeRange' && round == 3) {
              final recipe = await _durable(loop, 1);
              final disclosure = recipe.toolDisclosures!.single;
              expect(disclosure.sourceId, sourceSession);
              expect(disclosure.domain, SupportModelToolDisclosureDomain.game);
              expect(
                disclosure.operation,
                SupportModelToolDisclosureOperation.contents,
              );
              expect(
                disclosure.extent,
                SupportModelToolDisclosureExtent.scopeMetadata,
              );
              expect(
                disclosure.orderedSourceIds,
                List.generate(4, (i) => 'model-source-$i'),
              );
              final pieces = loop.body()['pieces'] as List;
              expect(pieces, hasLength(4));
              loop.noBody();
              issuedOversizeRead = true;
              return loop.read(
                source,
                pieces[1]['selector'] as String,
                'oversize_structured_range',
                before: 1,
                after: 2,
              );
            }
            expect(loop.lastResult()['ok'], isFalse);
            expect(loop.lastResult()['effect'], 'none');
            expect(loop.lastResult()['code'], switch (negative) {
              'unsupportedStudio' ||
              'malformedStudio' ||
              'oversizeRange' => 'unavailable',
              'legacyArgumentAlias' ||
              'historicalStudioSelector' ||
              'forgedNativeId' => 'invalidArguments',
              _ => 'denied',
            });
            return SourceLoop.answer(
              'The source cannot be read safely; preparation or a current issued selector is required.',
            );
          },
        );
        final needsScope =
            negative == 'unsupportedStudio' ||
            negative == 'malformedStudio' ||
            negative == 'oversizeRange';
        await loop.start(tester, confirmation: needsScope);
        if (needsScope) await loop.apply(tester);
        final reply = await loop.finish(tester);
        if (negative == 'oversizeRange') {
          expect(issuedOversizeRead, isTrue);
          expect(f.wire, hasLength(4));
          final calls = (f.wire.last['messages'] as List)
              .where((m) => m['role'] == 'assistant' && m['tool_calls'] != null)
              .expand((m) => m['tool_calls'] as List);
          final read = calls.singleWhere(
            (c) => c['id'] == 'oversize_structured_range',
          );
          expect(read['function']['name'], 'astoria_source_read');
          final arguments =
              jsonDecode(read['function']['arguments'] as String) as Map;
          expect(arguments['before'], 1);
          expect(arguments['after'], 2);
        }
        expect(reply.status, 'error');
        expect(f.bridge.view.transportReason.name, 'denied');
        final nativeFailure = f.bridge.view.toolActivities.lastWhere(
          (a) => a.stage.name == 'failed' || a.stage.name == 'stopped',
        );
        expect(nativeFailure.detail, isNotNull);
        expect(reply.body, contains(nativeFailure.detail!));
        expect(
          reply.body,
          isNot(contains('The source cannot be read safely;')),
        );
        loop.noBody();
        // These failures retain accepted scope metadata, but no body. The
        // other strict refusals never committed a disclosure at all.
        final recipe = await backupLoopReal(
          tester,
          () => modelSourceRecipe(
            f,
            reply.id,
            expectedVersion: needsScope ? 4 : 2,
            expectedDisclosureCount: needsScope ? 1 : null,
          ),
        );
        expect(recipe.toolDisclosures, needsScope ? hasLength(1) : isNull);
        _noExcluded(f);
      },
    );
  }

  for (final operation in ['retry', 'regenerate']) {
    backupLoopTest(
      'MODEL $operation uses ONLY four source tools with fresh native consent before any base graph',
      (tester, f) async {
        await seedModelSources(tester, f, messages: 4);
        final loop = SourceLoop(f);
        final ui = loop.nativeUi(tester);
        final origin = (await backupLoopReal(
          tester,
          () => f.native.repo.appendCurrentUser(
            message: SupportMessage(
              id: 'source-reattempt-user',
              sessionId: f.native.session,
              role: 'user',
              body: 'Compare the latest game.',
              runId: 'source-user-run',
              createdAt: 3,
            ),
            isCurrent: () => true,
          ),
        ))!;
        SupportMessage? oldReply;
        const oldDigest =
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        if (operation == 'regenerate') {
          oldReply = await backupLoopReal(tester, () async {
            final recipe = SupportModelProvenance(
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
                  orderedSourceIds: ['model-source-3'],
                  snapshotDigest: oldDigest,
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
                  SupportModelProvenanceCodec.encodeForEncryptedStorage(recipe),
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
        final emitter = loop.emitter(
          tester,
          ui: ui,
          visible: await _visible(tester, f),
        );
        final prefs = f.native.runtime.snapshot.preferences;
        final epoch = f.native.runtime.epoch;
        late String source;
        loop.script(
          loop.list('game', '${operation}_catalog'),
          rounds: 5,
          next: (round) async {
            if (round == 2) {
              expect(
                f.container.exists(supportAppActionRegistryProvider),
                isFalse,
              );
              final definitions = f.wire.last['tools'] as List;
              expect(definitions, hasLength(4));
              expect(definitions.map((d) => d['function']['name']).toSet(), {
                'astoria_sources_list',
                'astoria_source_contents',
                'astoria_source_search',
                'astoria_source_read',
              });
              source = loop.handle();
              return loop.contents(source, '${operation}_scope');
            }
            if (round == 3) {
              return loop.search(
                source,
                '${sourceGameBody}2',
                '${operation}_search',
              );
            }
            if (round == 4) {
              final body = loop.body();
              final hit = (body['pieces'] as List).single as Map;
              return loop.read(
                hit['citation']['source'] as String,
                hit['selector'] as String,
                '${operation}_read',
              );
            }
            await _durable(loop, operation == 'regenerate' ? 4 : 3);
            return SourceLoop.answer(
              'Only this fresh approved native scope was read.',
            );
          },
        );
        final signal = await backupLoopReal(
          tester,
          () => BackupLoopSignal(
            (operation == 'retry'
                    ? emitter.retry(_selected(origin))
                    : emitter.regenerate(_selected(oldReply!)))
                .finished,
          ),
        );
        await loop.modal(tester, signal: signal);
        expect(f.bridge.view.busy, isTrue);
        await loop.apply(tester);
        final result = await loop.join(tester, signal);
        expect(result.saved, isTrue);
        final all = await backupLoopReal(
          tester,
          () => f.native.repo.getMessagesForSession(f.native.session),
        );
        final reply = all.last;
        expect(reply.status, 'complete');
        final next = await backupLoopReal(
          tester,
          () => modelSourceRecipe(
            f,
            reply.id,
            expectedVersion: 4,
            expectedDisclosureCount: operation == 'regenerate' ? 4 : 3,
          ),
        );
        expect(
          next.toolDisclosures,
          hasLength(operation == 'regenerate' ? 4 : 3),
        );
        if (operation == 'regenerate') {
          expect(next.toolDisclosures!.first.snapshotDigest, oldDigest);
        }
        expect(next.toolDisclosures!.last.sourceId, sourceSession);
        expect(
          next.toolDisclosures!.last.operation,
          SupportModelToolDisclosureOperation.read,
        );
        expect(jsonEncode(f.wire), contains('${sourceGameBody}2'));
        expect(f.container.exists(supportAppActionRegistryProvider), isFalse);
        expect(f.native.runtime.snapshot.preferences, prefs);
        expect(f.native.runtime.epoch, epoch);
        expect(
          await f.native.db.select(f.native.db.supportMutationJournal).get(),
          isEmpty,
        );
        _noExcluded(f);
        ui.dispose();
      },
    );
  }

  backupLoopTest(
    'MODEL forged mutating retry tool is rejected before base graph or effect preparation',
    (tester, f) async {
      await seedModelSources(tester, f, messages: 4);
      final loop = SourceLoop(f);
      final ui = loop.nativeUi(tester);
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
      final emitter = loop.emitter(
        tester,
        ui: ui,
        visible: await _visible(tester, f),
      );
      loop.script(
        SourceLoop.call('astoria_preferences_update', {
          'hideTooltips': true,
        }, id: 'forged_retry'),
        rounds: 1,
      );
      final signal = await backupLoopReal(
        tester,
        () => BackupLoopSignal(emitter.retry(_selected(origin)).finished),
      );
      final result = await loop.join(tester, signal);
      expect(result.message!.status, isNot('complete'));
      loop.checkScript();
      expect(f.wire, hasLength(1));
      loop.noBody();
      expect(f.container.exists(supportAppActionRegistryProvider), isFalse);
      expect(f.wire.single['tools'], hasLength(4));
      expect(
        (await backupLoopReal(
          tester,
          () => f.container.read(appSettingsProvider.future),
        )).hideTooltips,
        isFalse,
      );
      expect(
        await f.native.db.select(f.native.db.supportMutationJournal).get(),
        isEmpty,
      );
      expect(
        find.byKey(const ValueKey('support_tool_confirmation_accept')),
        findsNothing,
      );
      _noExcluded(f);
      ui.dispose();
    },
  );
}
