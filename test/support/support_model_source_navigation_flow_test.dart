import 'dart:convert';

import 'package:drift/drift.dart' show Value, Variable;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide expect;
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/history_source_index_repo.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_source_preparation_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_source_preparation_sheet.dart';
import 'package:glaze_flutter/shared/widgets/menu_group.dart';
import 'package:glaze_flutter/shared/widgets/sheet_view.dart';

import 'support_model_source_loop_fixture.dart';

// MAIN runs these FILE-backed actual-provider/AEAD/screen checks sequentially.
// They reuse original dispatch, IO tripwires and settlement futures, not a fake
// source POST or a replacement native owner.
String _readyGame(SourceLoop loop) =>
    (loop.lastData()['pieces'] as List)
            .cast<Map<dynamic, dynamic>>()
            .singleWhere(
              (p) => p['domain'] == 'game' && p['state'] == 'current',
            )['source']
        as String;
Map<String, dynamic> _body(SourceLoop loop) => Map<String, dynamic>.from(
  jsonDecode(loop.lastData()['sourceText'] as String) as Map,
);
Future<void> _index(WidgetTester tester, BackupLoopFixture f) =>
    backupLoopReal(tester, () async {
      final result = await f.native.db.historySourceIndex.maintain(
        sessionId: sourceSession,
        isCurrent: () => true,
      );
      expect(result.state, HistoryIndexMaintenanceState.ready);
    });

Future<void> _prepareLocally(WidgetTester tester, BackupLoopFixture f) async {
  f.isolation.extraAllowed.add(supportSourcePreparationPageProvider(0));
  final canonical = await backupLoopReal(
    tester,
    () async =>
        (await f.native.db
                .customSelect(
                  'SELECT messages_json FROM chat_sessions WHERE session_id=?',
                  variables: [Variable.withString(sourceSession)],
                )
                .getSingle())
            .read<String>('messages_json'),
  );
  final entry = find.byKey(const ValueKey('support_local_source_preparation'));
  final openedSettings = entry.evaluate().isEmpty;
  if (openedSettings) {
    final mobile = find.byKey(const ValueKey('mobile_open_settings_btn'));
    final button = mobile.evaluate().isNotEmpty
        ? mobile
        : find.byKey(const ValueKey('support_collapsed_settings_btn'));
    expect(button.hitTestable(), findsOneWidget);
    await backupLoopReal(tester, () => tester.tap(button));
    await backupLoopUntil(tester, () => entry.evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 350));
  }
  await tester.ensureVisible(entry);
  await tester.pump();
  expect(entry.hitTestable(), findsOneWidget);
  await backupLoopReal(tester, () => tester.tap(entry));
  final sheet = find.byType(SupportSourcePreparationSheet);
  final candidate = find.byKey(
    ValueKey('support_source_prepare_$sourceSession'),
  );
  await backupLoopUntil(tester, () => candidate.evaluate().isNotEmpty);
  await tester.pump(const Duration(milliseconds: 350));
  final route = ModalRoute.of(tester.element(sheet))!;
  expect(route.isCurrent, isTrue);
  expect(
    tester.widget<MenuItem>(candidate).subtitle,
    'Не готов · подготовить / продолжить',
  );
  await tester.ensureVisible(candidate);
  await tester.pump();
  expect(candidate.hitTestable(), findsOneWidget);
  await backupLoopReal(tester, () => tester.tap(candidate));
  await backupLoopUntil(
    tester,
    () => find
        .text(
          'Готово для текущего снимка. Чтение моделью требует отдельного согласия.',
        )
        .evaluate()
        .isNotEmpty,
  );
  await backupLoopReal(tester, () async {
    expect(
      (await f.native.db.historySourceIndex.observe(sourceSession))['status'],
      'ready',
    );
    final after =
        (await f.native.db
                .customSelect(
                  'SELECT messages_json FROM chat_sessions WHERE session_id=?',
                  variables: [Variable.withString(sourceSession)],
                )
                .getSingle())
            .read<String>('messages_json');
    expect(utf8.encode(after), utf8.encode(canonical));
    final rows = await f.native.repo.getMessagesForSession(f.native.session);
    expect(rows.where((m) => m.runId != null), isEmpty);
  });
  expect(f.wire, isEmpty);
  SourceLoop(f).noBody();
  expect(
    find.byKey(const ValueKey('support_tool_confirmation_accept')),
    findsNothing,
  );
  final frame = find.byWidgetPredicate(
    (w) => w is SheetView && w.title == 'Локальная подготовка источников',
  );
  final back = find.descendant(
    of: frame,
    matching: find.widgetWithIcon(IconButton, Icons.arrow_back),
  );
  expect(back.hitTestable(), findsOneWidget);
  await backupLoopReal(tester, () => tester.tap(back));
  await tester.pump(const Duration(milliseconds: 350));
  await backupLoopUntil(tester, () => !route.isActive);
  if (openedSettings) {
    await tester.pageBack();
    await tester.pump(const Duration(milliseconds: 350));
  }
  _noPrivateSources(f);
}

Future<void> _durableBeforePost(BackupLoopFixture f, int count) async {
  final rows = await f.native.repo.getMessagesForSession(f.native.session);
  final reply = rows.singleWhere(
    (r) => r.role == 'assistant' && r.runId != null,
  );
  final recipe = await modelSourceRecipe(f, reply.id);
  expect(recipe.toolDisclosures, hasLength(count));
  for (var i = 0; i < count; i++) {
    final disclosure = recipe.toolDisclosures![i];
    expect(disclosure.domain.name, 'game');
    expect(disclosure.sourceId, sourceSession);
    expect(disclosure.operation?.name, ['contents', 'search', 'read'][i]);
    expect(
      disclosure.extent?.name,
      i == 0 ? 'scopeMetadata' : 'selectedMessages',
    );
    expect(disclosure.orderedSourceIds, [
      for (final n in [
        [0, 1, 2, 3],
        [2],
        [1, 2, 3],
      ][i])
        'model-source-$n',
    ]);
  }
  for (final disclosure in recipe.toolDisclosures!) {
    expect(jsonEncode(f.wire), isNot(contains(disclosure.snapshotDigest)));
  }
  for (final tool
      in (f.wire.last['messages'] as List).cast<Map<dynamic, dynamic>>().where(
        (m) => m['role'] == 'tool',
      )) {
    // Check the actual nested native result, not a payload-only estimate.
    expect(
      utf8.encode(jsonEncode(jsonDecode(tool['content'] as String))).length,
      lessThanOrEqualTo(65536),
    );
  }
}

void _noPrivateSources(BackupLoopFixture f) {
  for (final secret in [
    sourceExcluded,
    sourceOlderBody,
    sourceInactiveStudioBody,
    sourceSession,
    sourceCharacter,
  ]) {
    expect(jsonEncode(f.wire), isNot(contains(secret)));
  }
  sourceNoEgress(f);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final localPreparation in [false, true]) {
    backupLoopTest(
      localPreparation
          ? 'production local preparation sheet -> native catalog -> frozen consent -> contents/search/read -> encrypted provenance -> settled reply'
          : 'native catalog -> one frozen consent -> contents/search/read -> durable provenance -> settled reply',
      (tester, f) async {
        await seedModelSources(tester, f, messages: 4);
        if (localPreparation) {
          await _prepareLocally(tester, f);
        } else {
          await _index(tester, f);
        }
        final loop = SourceLoop(f);
        late String source;
        loop.script(
          SourceLoop.call('astoria_sources_list', {
            'domain': 'game',
          }, id: 'nav-list'),
          rounds: 5,
          next: (round) async {
            if (round == 2) {
              loop.noBody();
              source = _readyGame(loop);
              return SourceLoop.call('astoria_source_contents', {
                'source': source,
              }, id: 'nav-contents');
            }
            await _durableBeforePost(f, round - 2);
            final body = _body(loop);
            expect(body['status'], 'ok');
            expect(body['complete'], isTrue);
            if (round == 3) {
              expect(body['pieces'], hasLength(4));
              expect(jsonEncode(f.wire), isNot(contains(sourceGameBody)));
              return SourceLoop.call('astoria_source_search', {
                'source': source,
                'literal': '${sourceGameBody}2',
              }, id: 'nav-search');
            }
            if (round == 4) {
              final match = (body['pieces'] as List)
                  .cast<Map<dynamic, dynamic>>()
                  .single;
              expect(jsonEncode(match), contains('${sourceGameBody}2'));
              return SourceLoop.call('astoria_source_read', {
                'source': source,
                'selector': match['selector'],
                'before': 1,
                'after': 1,
              }, id: 'nav-read');
            }
            expect(round, 5);
            expect(body['pieces'], hasLength(3));
            for (final i in [1, 2, 3]) {
              expect(jsonEncode(body), contains('$sourceGameBody$i'));
            }
            _noPrivateSources(f);
            return SourceLoop.answer(
              'Selected active messages read within the frozen scope; saved material is not historical prompt proof.',
            );
          },
        );
        await loop.start(tester);
        loop.noBody();
        expect(jsonEncode(f.wire), isNot(contains(sourceGameBody)));
        await loop.apply(tester); // Exactly ONE game-source scope gesture.
        final reply = await loop.finish(
          tester,
        ); // No new gesture for search/read.
        expect(reply.status, 'complete', reason: loop.activityDiagnostic);
        expect(f.wire, hasLength(5));
        final recipe = await backupLoopReal(
          tester,
          () => modelSourceRecipe(f, reply.id),
        );
        expect(recipe.toolDisclosures, hasLength(3));
        expect(
          find.byKey(const ValueKey('support_tool_confirmation_accept')),
          findsNothing,
        );
        _noPrivateSources(f);
      },
    );
  }

  backupLoopTest(
    'refused local authored source label is absent from factual reply and later Send',
    (tester, f) async {
      const label = 'LOCAL_ONLY_AUTHOR_LABEL_CANARY';
      await seedModelSources(tester, f, messages: 4);
      await backupLoopReal(
        tester,
        () =>
            (f.native.db.update(f.native.db.characters)
                  ..where((t) => t.charId.equals(sourceCharacter)))
                .write(const CharactersCompanion(name: Value(label))),
      );
      await _index(tester, f);
      final loop = SourceLoop(f);
      loop.script(
        SourceLoop.call('astoria_sources_list', {
          'domain': 'game',
        }, id: 'private-list'),
        rounds: 3,
        next: (round) {
          if (round == 2)
            return SourceLoop.call('astoria_source_contents', {
              'source': _readyGame(loop),
            }, id: 'private-contents');
          expect(loop.lastResult()['ok'], isFalse);
          return SourceLoop.answer('No source text was disclosed.');
        },
      );
      await loop.start(tester);
      expect(find.textContaining(label), findsWidgets); // Local UI only.
      await loop.cancel(tester);
      final refused = await loop.finish(tester);
      expect(refused.body, isNot(contains(label)));
      expect(jsonEncode(f.wire), isNot(contains(label)));
      loop.noBody();
      final sent = f.wire.length;
      loop.script(
        SourceLoop.answer('New Send has no previous source grant.'),
        rounds: 1,
      );
      await loop.start(tester, confirmation: false); // Real composer Send only.
      final next = await loop.finish(tester);
      expect(next.status, 'complete');
      expect(f.wire.length, sent + 1);
      expect(jsonEncode(f.wire), isNot(contains(label)));
      loop.noBody();
    },
  );
}
