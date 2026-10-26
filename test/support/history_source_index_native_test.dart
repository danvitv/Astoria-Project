import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/history_source_index_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_source_text_repo.dart';
import 'package:glaze_flutter/core/db/native_history/history_index_schema.dart';
import 'package:glaze_flutter/core/support/source_navigation.dart' as nav;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'helpers/support_source_text_native_fixture.dart';
import 'helpers/support_text_context_fixture.dart';

// MAIN owns sequential execution of these synthetic native checks. No runtime
// database, provider, environment, vault, socket or app-launch access is used.
const _session = SupportTextContextFixture.roleplayId;
const _bound = nav.WorkBound();
SupportSourceNavigationRepo _navigation(SupportSourceTextNativeFixture f) =>
    SupportSourceNavigationRepo(
      boundary: SupportSourceTextRepo(
        db: f.db,
        cipher: f.cipher,
        currentRedactor: () => f.redactor,
      ),
      isCurrent: () => true,
    );

void main() {
  late SupportSourceTextNativeFixture f;
  setUp(() async {
    f = SupportSourceTextNativeFixture();
    await f.initialize();
    await f.seed();
  });
  tearDown(() => f.close());

  test(
    'migration 137 -> 138 preserves exact canonical bytes; production worker seam',
    () async {
      const original =
          '[ \n {"id":"a","role":"user","content":"😀 \\u0061","unknown":[1,true]} ] \t';
      await f.replaceRoleplayJson(original);
      for (final name in historyIndexTriggers.keys) {
        await f.db.customStatement('DROP TRIGGER $name');
      }
      for (final name in sourceNavigationIndexes.keys) {
        await f.db.customStatement('DROP INDEX $name');
      }
      for (final table in [
        'history_message_units',
        'history_source_generations',
        'history_index_clock',
      ]) {
        await f.db.customStatement('DROP TABLE $table');
      }
      await f.db.customStatement('PRAGMA user_version=137');
      await f.db.close();
      final migrated = AppDatabase.fixedNativeFile(File(f.sourcePath));
      try {
        await migrated.customSelect('SELECT 1').get();
        expect(migrated.schemaVersion, 138);
        expect(migrated.allTables.length, 64);
        final before =
            (await migrated
                    .customSelect(
                      'SELECT messages_json FROM chat_sessions WHERE session_id=?',
                      variables: [Variable.withString(_session)],
                    )
                    .getSingle())
                .read<String>('messages_json');
        expect(utf8.encode(before), utf8.encode(original));
        expect(
          (await migrated.historySourceIndex.observe(_session))['status'],
          'incomplete',
        );
        final result = await migrated.historySourceIndex.maintain(
          sessionId: _session,
          isCurrent: () => true,
        );
        expect(result.state, HistoryIndexMaintenanceState.ready);
        expect(
          (await migrated.historySourceIndex.observe(_session))['status'],
          'ready',
        );
        final after =
            (await migrated
                    .customSelect(
                      'SELECT messages_json FROM chat_sessions WHERE session_id=?',
                      variables: [Variable.withString(_session)],
                    )
                    .getSingle())
                .read<String>('messages_json');
        expect(utf8.encode(after), utf8.encode(original));
      } finally {
        await migrated.close();
      }
    },
  );

  test(
    'missing index refuses; bounded local checkpoint/Stop remains incomplete',
    () async {
      final repo = _navigation(f);
      final source = (await repo.observe(
        const nav.SourceKey(nav.SourceDomain.game, _session),
        _bound,
      ))!;
      expect(repo.approvalScope(source), isNull);
      final original = f.handle.select(
        'SELECT messages_json FROM chat_sessions WHERE session_id=?',
        [_session],
      ).single['messages_json'];
      final partial = await f.db.historySourceIndex.maintain(
        sessionId: _session,
        isCurrent: () => true,
        maxSteps: 1,
      );
      expect(partial.state, HistoryIndexMaintenanceState.incomplete);
      expect(
        (await f.db.historySourceIndex.observe(_session))['status'],
        'incomplete',
      );
      final resumed = await f.db.historySourceIndex.maintain(
        sessionId: _session,
        isCurrent: () => true,
        maxSteps: 1,
      );
      expect(resumed.state, HistoryIndexMaintenanceState.ready);
      final stopped = await f.db.historySourceIndex.maintain(
        sessionId: _session,
        isCurrent: () => false,
      );
      expect(stopped.state, HistoryIndexMaintenanceState.incomplete);
      expect(
        f.handle.select(
          'SELECT messages_json FROM chat_sessions WHERE session_id=?',
          [_session],
        ).single['messages_json'],
        original,
      );
      expect(
        (await f.db.historySourceIndex.maintain(
          sessionId: _session,
          isCurrent: () => true,
        )).state,
        HistoryIndexMaintenanceState.ready,
      );
    },
  );

  test(
    'same-size outside-selection DML, eligibility and delete/recreate retire generations',
    () async {
      await f.db.historySourceIndex.maintain(
        sessionId: _session,
        isCurrent: () => true,
      );
      final before = await f.db.historySourceIndex.observe(_session);
      final original =
          f.handle.select(
                'SELECT messages_json FROM chat_sessions WHERE session_id=?',
                [_session],
              ).single['messages_json']
              as String;
      final external = sqlite.sqlite3.open(f.sourcePath);
      try {
        external.execute(
          'UPDATE chat_sessions SET messages_json=? WHERE session_id=?',
          [
            original.replaceFirst('Synthetic second', 'Synthetic hidden'),
            _session,
          ],
        );
        final changed = await f.db.historySourceIndex.observe(_session);
        expect(changed['status'], 'incomplete');
        expect(changed['revision'], greaterThan(before['revision'] as int));
        external.execute(
          'UPDATE chat_sessions SET messages_json=? WHERE session_id=?',
          [original, _session],
        );
        final restored = await f.db.historySourceIndex.observe(_session);
        expect(restored['revision'], greaterThan(changed['revision'] as int));
        external.execute('UPDATE characters SET hidden=1 WHERE char_id=?', [
          'synthetic-character',
        ]);
        final ineligible = await f.db.historySourceIndex.observe(_session);
        expect(
          ineligible['revision'],
          greaterThan(restored['revision'] as int),
        );
        external.execute('DELETE FROM chat_sessions WHERE session_id=?', [
          _session,
        ]);
        external.execute(
          'INSERT INTO chat_sessions(session_id,character_id,session_index,messages_json) VALUES(?,?,?,?)',
          [_session, 'synthetic-character', 0, original],
        );
        final recreated = await f.db.historySourceIndex.observe(_session);
        expect(
          recreated['incarnation'],
          greaterThan(before['incarnation'] as int),
        );
        expect(recreated['status'], 'incomplete');
      } finally {
        external.close();
      }
    },
  );

  test(
    'corrupt/deleted derived units and trigger tampering never stay authoritative',
    () async {
      await f.db.historySourceIndex.maintain(
        sessionId: _session,
        isCurrent: () => true,
      );
      expect(
        (await f.db.historySourceIndex.observe(_session))['status'],
        'ready',
      );
      await f.db.customStatement(
        'DELETE FROM history_message_units WHERE session_id=? AND native_order=2',
        [_session],
      );
      expect(
        (await f.db.historySourceIndex.observe(_session))['status'],
        'incomplete',
      );
      await f.db.historySourceIndex.maintain(
        sessionId: _session,
        isCurrent: () => true,
      );
      await f.db.customStatement('DROP TRIGGER history_source_update');
      expect(
        (await f.db.historySourceIndex.observe(_session))['status'],
        'incomplete',
      );
      final original = f.handle.select(
        'SELECT messages_json FROM chat_sessions WHERE session_id=?',
        [_session],
      ).single['messages_json'];
      expect(original, isNotNull);
    },
  );

  test(
    'malformed, duplicate and oversized histories are preserved and honestly unsupported',
    () async {
      for (final original in [
        '[',
        r'[{"id":"a","id":"b","role":"user","content":"x"}]',
        '[{"id":"a","role":"user","content":"x"},{"id":"a","role":"user","content":"y"}]',
        jsonEncode([
          {'id': 'huge', 'role': 'user', 'content': 'x' * 65536},
        ]),
      ]) {
        await f.replaceRoleplayJson(original);
        final result = await f.db.historySourceIndex.maintain(
          sessionId: _session,
          isCurrent: () => true,
        );
        expect(
          result.state,
          HistoryIndexMaintenanceState.unsupported,
          reason: original.length.toString(),
        );
        expect(
          (await f.db.historySourceIndex.observe(_session))['status'],
          'incomplete',
        );
        expect(
          f.handle.select(
            'SELECT messages_json FROM chat_sessions WHERE session_id=?',
            [_session],
          ).single['messages_json'],
          original,
        );
      }
    },
  );

  test(
    'ready distant units use exact address index and bounded row payload, not canonical cell offsets',
    () async {
      await f.replaceRoleplay(
        List.generate(
          1000,
          (i) => {'id': 'm-$i', 'role': 'user', 'content': 'record $i'},
        ),
      );
      expect(
        (await f.db.historySourceIndex.maintain(
          sessionId: _session,
          isCurrent: () => true,
          maxSteps: 512,
        )).state,
        HistoryIndexMaintenanceState.ready,
      );
      final plan = f.handle.select(
        'EXPLAIN QUERY PLAN SELECT raw_json FROM history_message_units '
        'INDEXED BY idx_history_units_active WHERE session_id=? AND incarnation=? AND revision=? AND active_ordinal=?',
        [_session, 1, 1, 999],
      );
      expect(
        jsonEncode(plan.map((r) => Map<String, Object?>.from(r)).toList()),
        contains('SEARCH'),
      );
      expect(
        jsonEncode(plan.map((r) => Map<String, Object?>.from(r)).toList()),
        contains('idx_history_units_active'),
      );
      final size =
          f.handle
                  .select(
                    'SELECT max(octet_length(raw_json)) AS n FROM history_message_units',
                  )
                  .single['n']
              as int;
      expect(size, lessThanOrEqualTo(65536));
      final repo = _navigation(f);
      final source = (await repo.observe(
        const nav.SourceKey(nav.SourceDomain.game, _session),
        _bound,
      ))!;
      final scope = repo.approvalScope(source)!;
      final tail = nav.FrozenScope.messages(
        nav.ActiveRange(scope.messages!.end, scope.messages!.end),
      );
      final page = await repo.contents(source, tail, null, null, _bound);
      final read = await repo.read(
        source,
        tail,
        nav.ReadQuery(page.items.single.selection, 0, 0),
        _bound,
      );
      expect(read.items.single.payload, 'record 999');
      expect(read.candidatesExamined, 1);
    },
  );

  test(
    'non-game owner keysets exclude unrelated and filtered rows before bounded authored reads',
    () async {
      await f.db.transaction(() async {
        for (var i = 0; i < 1200; i++) {
          await f.db.customStatement(
            'INSERT INTO tracker_rows(session_id,name,value,scope) VALUES(?,?,?,?)',
            ['synthetic-branch', 'other-$i', 'UNRELATED_OWNER', 'ledger'],
          );
        }
        for (var i = 0; i < 100; i++) {
          await f.db.customStatement(
            'INSERT INTO tracker_rows(session_id,name,value,scope) VALUES(?,?,?,?)',
            [_session, 'canon_$i', 'EXCLUDED_CANON', 'ledger'],
          );
        }
        await f.db.customStatement(
          'INSERT INTO tracker_rows(session_id,name,value,scope) VALUES(?,?,?,?)',
          [_session, 'scene.location', 'native tracker needle', 'ledger'],
        );
      });
      final plan = jsonEncode(
        f.handle
            .select(
              'EXPLAIN QUERY PLAN SELECT rowid FROM tracker_rows '
              'INDEXED BY idx_navigation_tracker_rows_owner WHERE session_id=? AND rowid>? ORDER BY rowid LIMIT 1',
              [_session, 0],
            )
            .map((r) => Map<String, Object?>.from(r))
            .toList(),
      );
      expect(plan, contains('SEARCH'));
      expect(plan, isNot(contains('USE TEMP B-TREE')));
      final repo = _navigation(f);
      final source = (await repo.observe(
        const nav.SourceKey(nav.SourceDomain.ledgerState, _session),
        _bound,
      ))!;
      final result = await repo.search(
        source,
        repo.approvalScope(source)!,
        'native tracker needle',
        null,
        null,
        _bound,
      );
      expect(result.items.single.payload, 'native tracker needle');
      expect(result.candidatesExamined, greaterThanOrEqualTo(100));
      expect(result.candidatesExamined, lessThanOrEqualTo(4096));
      expect(
        jsonEncode(result.items.map((r) => r.payload).toList()),
        isNot(contains('EXCLUDED_CANON')),
      );
      expect(
        jsonEncode(result.items.map((r) => r.payload).toList()),
        isNot(contains('UNRELATED_OWNER')),
      );
    },
  );
}
