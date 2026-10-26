import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide expect;
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/history_source_index_repo.dart';

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
Future<void> _durableBeforePost(BackupLoopFixture f, int count) async {
  final rows = await f.native.repo.getMessagesForSession(f.native.session);
  final reply = rows.singleWhere(
    (r) => r.role == 'assistant' && r.runId != null,
  );
  final recipe = await modelSourceRecipe(f, reply.id);
  expect(recipe.toolDisclosures, hasLength(count));
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
  backupLoopTest(
    'native catalog -> one frozen consent -> contents/search/read -> durable provenance -> settled reply',
    (tester, f) async {
      await seedModelSources(tester, f, messages: 4);
      await _index(tester, f);
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
      await loop.apply(tester); // Original recipient/send gesture.
      await loop.modal(tester);
      expect(jsonEncode(f.wire), isNot(contains(sourceGameBody)));
      await loop.apply(tester); // Exactly ONE game-source scope gesture.
      final reply = await loop.finish(
        tester,
      ); // No new gesture for search/read.
      expect(reply.status, 'complete');
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
      await loop.apply(tester);
      await loop.modal(tester);
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
      await loop.start(tester);
      await loop.apply(tester);
      final next = await loop.finish(tester);
      expect(next.status, 'complete');
      expect(f.wire.length, sent + 1);
      expect(jsonEncode(f.wire), isNot(contains(label)));
      loop.noBody();
    },
  );
}
