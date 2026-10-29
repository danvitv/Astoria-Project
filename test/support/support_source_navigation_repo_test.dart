import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_run_repo.dart';
import 'package:glaze_flutter/core/db/repositories/history_source_index_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_source_text_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_text_context_repo.dart';
import 'package:glaze_flutter/core/support/source_navigation.dart' as nav;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'helpers/support_source_text_native_fixture.dart';
import 'helpers/support_text_context_fixture.dart';

const _session = SupportTextContextFixture.roleplayId;
const _bound = nav.WorkBound();

SupportSourceNavigationRepo _repo(
  SupportSourceTextNativeFixture f, {
  bool Function()? current,
}) => SupportSourceNavigationRepo(
  boundary: SupportSourceTextRepo(
    db: f.db,
    cipher: f.cipher,
    currentRedactor: () => f.redactor,
  ),
  isCurrent: current ?? () => true,
);

Object? _canonical(Object? value) {
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

String _json(Object? value) => jsonEncode(_canonical(value));

Future<void> _allDomains(SupportSourceTextNativeFixture f) async {
  await f.db.customStatement(
    'INSERT INTO presets(preset_id,name,data_json) VALUES(?,?,?)',
    [
      'same-id',
      'Saved ordinary',
      jsonEncode({
        'id': 'same-id',
        'name': 'Saved ordinary',
        'blocks': [
          {
            'id': 'authored',
            'name': 'Ordinary block',
            'role': 'system',
            'content': 'ordinary needle',
            'enabled': true,
          },
        ],
        'regexes': <Object?>[],
        'reasoningEnabled': false,
        'summaryPrompt': 'summary template needle',
      }),
    ],
  );
  await f.db.customStatement(
    'INSERT INTO studio_preset_rows(preset_id,name,blocks_json,runtime_settings_json,agents_json) VALUES(?,?,?,?,?)',
    [
      'same-id',
      'Saved Studio',
      jsonEncode([
        {
          'id': 'seed',
          'name': 'Raw seed name',
          'kind': 'custom_text',
          'content': 'studio needle',
          'enabled': true,
        },
      ]),
      jsonEncode({
        'agentEnabledBeforeDependencyOff': {'native-agent': false},
      }),
      jsonEncode([
        {'id': 'native-agent', 'name': 'Agent', 'enabled': true},
      ]),
    ],
  );
  await f.db.customStatement(
    'INSERT INTO memory_book_rows(session_id,entries_json,pending_drafts_json,settings_json) VALUES(?,?,?,?)',
    [
      _session,
      jsonEncode([
        {
          'id': 'memory-entry',
          'title': 'Entry',
          'content': 'memory needle',
          'status': 'active',
          'activeRevisionId': 'entry-r1',
          'revisions': [
            {
              'id': 'entry-r1',
              'version': 1,
              'content': 'revision needle',
              'createdAt': 1,
            },
          ],
          'sourceManifest': {
            'version': 0,
            'originSessionId': '',
            'messages': <Object?>[],
            'invalidated': true,
          },
        },
      ]),
      jsonEncode([
        {
          'id': 'draft',
          'content': 'draft needle',
          'status': 'pending_approval',
        },
      ]),
      '{}',
    ],
  );
  await f.db.customStatement(
    'INSERT INTO memory_catalog_rows(id,chat_session_id,memory_entry_id,abstract_text) VALUES(?,?,?,?)',
    ['catalog', _session, 'memory-entry', 'derived catalog needle'],
  );
  await f.db.customStatement(
    'INSERT INTO chat_summaries(session_id,content,message_count,prompt) VALUES(?,?,?,?)',
    [_session, 'saved summary needle', 3, 'saved template needle'],
  );
  await f.db.customStatement(
    'INSERT INTO tracker_rows(session_id,name,value,scope,provenance) VALUES(?,?,?,?,?)',
    [_session, 'scene.location', 'live Ledger needle', 'ledger', 'saved'],
  );
  await f.db.customStatement(
    'INSERT INTO tracker_rows(session_id,name,value,scope) VALUES(?,?,?,?)',
    [_session, 'diagnostic', 'DO_NOT_DISCLOSE_DIAGNOSTIC', 'diagnostic'],
  );
  await f.db.customStatement(
    'INSERT INTO tracker_snapshots(session_id,message_id,swipe_id,agent_swipe_id,trackers_json,committed) VALUES(?,?,?,?,?,?)',
    [
      _session,
      'roleplay-b',
      1,
      0,
      jsonEncode([
        {
          'sessionId': _session,
          'name': 'scene.location',
          'value': 'snapshot needle',
          'scope': 'ledger',
          'provenance': 'saved',
        },
      ]),
      1,
    ],
  );
  await f.db.customStatement(
    'INSERT INTO ledger_reconciliation_checkpoints(session_id,start_message_id,end_message_id,end_swipe_id,end_agent_swipe_id,message_ids_json,range_hash) VALUES(?,?,?,?,?,?,?)',
    [
      _session,
      'roleplay-a',
      'roleplay-b',
      1,
      0,
      jsonEncode(['roleplay-a', 'roleplay-unselected', 'roleplay-b']),
      'private-range',
    ],
  );
  final run = LedgerReconciliationRun(
    id: 'saved-run',
    sessionId: _session,
    ordinal: 1,
    anchors: const [
      ReconciliationAnchor(
        messageId: 'roleplay-b',
        swipeId: 1,
        agentSwipeId: 0,
        role: 'assistant',
        contentHash:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ),
    ],
    acceptedManifestRefs: const [],
    effectiveCanonStamp: 'private-canon',
    effectiveCanonRevision: 0,
    effectiveCanonHash:
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    canonicalResult: {
      'cleanupOps': <Object?>[],
      'export': {
        'ops': [
          {
            'op': 'set',
            'key': 'scene.location',
            'value': 'saved reconciliation needle',
            'evidence': 'saved range',
            'eventState': '',
          },
        ],
        'sceneState': null,
        'entities': <Object?>[],
        'arcState': <Object?>[],
        'knowledgeFacts': <Object?>[],
      },
    },
    predecessorChainHash: '',
    contractVersion: 1,
    opsApplied: const ['tracker:set:scene.location'],
    createdAt: 1,
  );
  await f.db
      .into(f.db.ledgerReconciliationSuccessfulRuns)
      .insert(
        LedgerReconciliationSuccessfulRunsCompanion.insert(
          id: run.id,
          sessionId: run.sessionId,
          ordinal: run.ordinal,
          startMessageId: run.start.messageId,
          startSwipeId: run.start.swipeId,
          startAgentSwipeId: run.start.agentSwipeId,
          endMessageId: run.end.messageId,
          endSwipeId: run.end.swipeId,
          endAgentSwipeId: run.end.agentSwipeId,
          anchorsJson: run.anchorsJson,
          rangeHash: run.rangeHash,
          acceptedManifestRefsJson: run.manifestsJson,
          effectiveCanonStamp: run.effectiveCanonStamp,
          effectiveCanonRevision: run.effectiveCanonRevision,
          effectiveCanonHash: run.effectiveCanonHash,
          canonicalResultJson: run.resultJson,
          contentHash: run.contentHash,
          predecessorChainHash: run.predecessorChainHash,
          chainHash: run.chainHash,
          contractVersion: run.contractVersion,
          opsAppliedJson: run.opsJson,
          createdAt: run.createdAt,
        ),
      );
  final ledger = [
    {
      'sessionId': _session,
      'name': 'scene.location',
      'value': 'saved effect needle',
      'scope': 'ledger',
      'provenance': 'saved',
      'basisRevision': 0,
      'basisRevisionHash': '',
      'updatedAt': 1,
    },
  ];
  final before = ReconciliationStateSnapshot(
    ledgerJson: '[]',
    knowledgeJson: '[]',
  );
  final after = ReconciliationStateSnapshot(
    ledgerJson: _json(ledger),
    knowledgeJson: '[]',
  );
  // Only fixture setup uses a writer. The adapter never calls this repository.
  await LedgerReconciliationRunRepo(f.db).recordEffect(
    runId: run.id,
    sessionId: _session,
    before: before,
    after: after,
    createdAt: 1,
  );
  await f.db.customStatement(
    '''INSERT INTO character_knowledge_fact_rows(
    id,chat_session_id,knower_key,subject_key,fact_class,predicate,object,epistemic_state,
    confidence,importance,source_message_id,source_swipe_id,source_agent_swipe_id,lifecycle)
    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
    [
      'knowledge',
      _session,
      'knower',
      'subject',
      'knowledge',
      'knows',
      'knowledge needle',
      'confirmed',
      0.7,
      0.5,
      'roleplay-b',
      1,
      0,
      'active',
    ],
  );
}

Future<List<nav.DataRecord>> _searchAll(
  SupportSourceNavigationRepo repo,
  nav.SourceObservation source,
  String literal,
) async {
  final scope = repo.approvalScope(source)!;
  Object? cursor;
  final records = <nav.DataRecord>[];
  for (var step = 0; step < 32; step++) {
    final page = await repo.search(
      source,
      scope,
      literal,
      null,
      cursor,
      _bound,
    );
    expect(page.items.length, lessThanOrEqualTo(16));
    expect(page.candidatesExamined, lessThanOrEqualTo(4096));
    records.addAll(page.items);
    if (page.complete) return records;
    expect(page.next, isNotNull);
    cursor = page.next;
  }
  fail('Bounded synthetic scan failed to complete');
}

Future<void> _index(
  SupportSourceTextNativeFixture f, [
  String session = _session,
]) async {
  final result = await f.db.historySourceIndex.maintain(
    sessionId: session,
    isCurrent: () => true,
    maxSteps: 4096,
    deadline: const Duration(seconds: 180),
  );
  expect(result.state, HistoryIndexMaintenanceState.ready);
}

void main() {
  late SupportSourceTextNativeFixture f;
  setUp(() async {
    f = SupportSourceTextNativeFixture();
    await f.initialize();
    await f.seed();
  });
  tearDown(() => f.close());

  for (final mode in [
    'fresh',
    'mutation',
    'ABA',
    'forged',
    'stop',
    'reentry',
    'unknown',
  ]) {
    test('original ROOT batch is single-use and fail-closed: $mode', () async {
      await _allDomains(f);
      await _index(f);
      var current = true;
      final repo = _repo(f, current: () => current);
      final ordinary = (await repo.observe(
        const nav.SourceKey(nav.SourceDomain.ordinaryPreset, 'same-id'),
        _bound,
      ))!;
      final studio = (await repo.observe(
        const nav.SourceKey(nav.SourceDomain.studioPreset, 'same-id'),
        _bound,
      ))!;
      final history = SupportTextContextRepo(
        db: f.db,
        cipher: f.cipher,
        currentRedactor: () => f.redactor,
        admissionContract: mode == 'unknown'
            ? null
            : SupportTextAdmissionContract
                  .auditedRootSingleConnectionNoBusyHandler,
      );
      var dispatched = 0, checks = 0;
      nav.OriginalRootRevalidation? retained;
      Future<bool> admit({bool attack = false}) => repo.admitOriginalRoot(
        history: history,
        snapshots: const [],
        isCurrent: () => current,
        checkReadOnly: (checkpoint) async {
          checks++;
          final batch = repo.currentOriginalRootRevalidation!;
          expect(identical(batch, retained), isFalse);
          retained = batch;
          if (attack && mode == 'stop') current = false;
          if (attack && mode == 'reentry') {
            expect(
              await repo.admitOriginalRoot(
                history: history,
                snapshots: const [],
                isCurrent: () => current,
                checkReadOnly: (_) async => true,
                dispatch: () => dispatched++,
              ),
              isFalse,
            );
          }
          final originals = [ordinary, studio, ordinary];
          if (attack && mode == 'forged') {
            originals.add(
              nav.SourceObservation(
                key: ordinary.key,
                snapshot: ordinary.snapshot,
                state: ordinary.state,
                binding: ordinary.binding,
                lease: ordinary.lease,
              ),
            );
          }
          // ROOT already acquired audited writer exclusion. Observe only the
          // read-only batch, not its constant-false writer acquisition.
          f.observe();
          try {
            final ok = await batch.revalidate(originals, _bound);
            checkpoint();
            if (ok) {
              // Two independent observations share ONE operation and exactly
              // its BEFORE/AFTER native SQL fences, not per-source calls.
              expect(
                f.spy.statements.where((s) => s.contains('schema_revision')),
                hasLength(2),
              );
              final statements = f.spy.statements.length;
              expect(batch.isCurrent, isFalse);
              expect(await batch.revalidate(originals, _bound), isFalse);
              expect(f.spy.statements, hasLength(statements));
              checkpoint();
            }
            expect(f.spy.writes, 0);
            return ok;
          } finally {
            f.stopObserving();
          }
        },
        dispatch: () {
          expect(repo.currentOriginalRootRevalidation, isNull);
          expect(retained!.isCurrent, isFalse);
          dispatched++;
        },
      );
      if (mode == 'unknown') {
        expect(await admit(), isFalse);
        expect(checks, 0);
        expect(dispatched, 0);
        return;
      }
      await f.db.runWithInterceptor(() async {
        expect(await admit(), isTrue);
        expect(checks, 1);
        expect(dispatched, 1);
        // Retained reuse after ROOT closes must also do no SQL.
        f.observe();
        try {
          expect(await retained!.revalidate([ordinary], _bound), isFalse);
          expect(f.spy.statements, isEmpty);
          expect(f.spy.writes, 0);
        } finally {
          f.stopObserving();
        }
      }, interceptor: f.spy);
      if (mode == 'mutation' || mode == 'ABA') {
        await f.db.customStatement(
          "UPDATE presets SET name='changed' WHERE preset_id='same-id'",
        );
        if (mode == 'ABA') {
          await f.db.customStatement(
            "UPDATE presets SET name='Saved ordinary' WHERE preset_id='same-id'",
          );
        }
      }
      await f.db.runWithInterceptor(() async {
        expect(await admit(attack: true), mode == 'fresh');
      }, interceptor: f.spy);
      expect(dispatched, mode == 'fresh' ? 2 : 1);
      expect(repo.currentOriginalRootRevalidation, isNull);
      expect(retained!.isCurrent, isFalse);
    });
  }

  test(
    'missing stored domains are empty, not fabricated current sources',
    () async {
      final repo = _repo(f);
      for (final domain in nav.SourceDomain.values.where(
        (d) => d != nav.SourceDomain.game,
      )) {
        final page = await repo.discover(domain, null, null, _bound);
        expect(page.items, isEmpty, reason: domain.name);
        expect(page.complete, isTrue);
      }
    },
  );

  test(
    'all nine real native saved domains read; ordinary/Studio IDs stay separate',
    () async {
      await _allDomains(f);
      await _index(f);
      final repo = _repo(f);
      expect(repo.usesDatabase(f.db), isTrue);
      await f.db.runWithInterceptor(() async {
        f.observe();
        for (final domain in nav.SourceDomain.values) {
          final id =
              domain == nav.SourceDomain.ordinaryPreset ||
                  domain == nav.SourceDomain.studioPreset
              ? 'same-id'
              : _session;
          final source = (await repo.observe(
            nav.SourceKey(domain, id),
            _bound,
          ))!;
          final roots = await repo.contents(
            source,
            repo.approvalScope(source)!,
            null,
            null,
            _bound,
          );
          expect(roots.items, isNotEmpty, reason: domain.name);
          final hits = await _searchAll(
            repo,
            source,
            domain == nav.SourceDomain.game ? 'Synthetic' : 'needle',
          );
          expect(hits, isNotEmpty, reason: domain.name);
          final read = await repo.read(
            source,
            repo.approvalScope(source)!,
            nav.ReadQuery(hits.first.selection, 0, 0),
            _bound,
          );
          expect(read.items.single.payload, hits.first.payload);
        }
        expect(f.spy.writes, 0);
        final projected = jsonEncode(f.spy.values);
        expect(projected, isNot(contains('DO_NOT_DISCLOSE_DIAGNOSTIC')));
        // Raw finite sources are private and may contain authored IDs. Game
        // projection must never carry excluded message fields/variant bodies.
        final game = (await repo.observe(
          const nav.SourceKey(nav.SourceDomain.game, _session),
          _bound,
        ))!;
        final gameRecords = await _searchAll(repo, game, 'Synthetic');
        expect(
          jsonEncode(gameRecords.map((r) => r.payload).toList()),
          isNot(contains(SupportTextContextFixture.reasoning)),
        );
        expect(
          jsonEncode(gameRecords.map((r) => r.payload).toList()),
          isNot(contains(SupportTextContextFixture.attachment)),
        );
        f.stopObserving();
      }, interceptor: f.spy);
      final memory = (await repo.observe(
        const nav.SourceKey(nav.SourceDomain.memory, _session),
        _bound,
      ))!;
      expect(
        (await _searchAll(repo, memory, 'revision needle')).single.kind,
        nav.SectionKind.memoryRevision,
      );
      expect(
        (await _searchAll(repo, memory, 'draft needle')).single.state,
        nav.SourceState.pendingApproval,
      );
      expect(
        (await _searchAll(
          repo,
          memory,
          'memory needle',
        )).single.binding.evidence.state,
        nav.EvidenceState.invalid,
      );
      expect(
        (await _searchAll(repo, memory, 'derived catalog needle')).single.state,
        nav.SourceState.derived,
      );
      final recon = (await repo.observe(
        const nav.SourceKey(nav.SourceDomain.reconciliation, _session),
        _bound,
      ))!;
      expect(
        await _searchAll(repo, recon, 'saved reconciliation needle'),
        isNotEmpty,
      );
      expect(await _searchAll(repo, recon, 'saved effect needle'), isNotEmpty);
    },
  );

  test(
    'oversized >2000-message history is selected in SQLite with ACTIVE neighbours',
    () async {
      final filler = List.filled(1200, 'x').join();
      await f.replaceRoleplay(
        List.generate(
          2305,
          (i) => {
            ...SupportTextContextFixture.message(
              'm-$i',
              body: i == 2250 ? 'far needle' : '$i $filler',
            ),
            if (i == 2249) 'isHidden': true,
          },
        ),
      );
      await _index(f);
      final repo = _repo(f);
      await f.db.runWithInterceptor(() async {
        f.observe();
        final source = (await repo.observe(
          const nav.SourceKey(nav.SourceDomain.game, _session),
          _bound,
        ))!;
        final scope = repo.approvalScope(source)!;
        final hits = await _searchAll(repo, source, 'far needle');
        expect(hits.single.payload, 'far needle');
        expect(hits.single.selection.range!.start.ordinal, 2249);
        final read = await repo.read(
          source,
          scope,
          nav.ReadQuery(hits.single.selection, 2, 2),
          _bound,
        );
        expect(read.items.map((r) => r.binding.anchor!.messageId), [
          'm-2247',
          'm-2248',
          'm-2250',
          'm-2251',
          'm-2252',
        ]);
        expect(
          f.spy.values.any((r) => r.containsKey('messages_json')),
          isFalse,
        );
        expect(
          f.spy.statements.any(
            (s) => s.contains('json_each') || s.contains('OVER ('),
          ),
          isFalse,
        );
        expect(f.spy.writes, 0);
        f.stopObserving();
      }, interceptor: f.spy);
    },
  );

  test(
    '4096-candidate scan exhaustion is explicit, not proof of no match',
    () async {
      await f.replaceRoleplay(
        List.generate(
          4200,
          (i) => SupportTextContextFixture.message('m-$i', body: 'text $i'),
        ),
      );
      await _index(f);
      final repo = _repo(f);
      final source = (await repo.observe(
        const nav.SourceKey(nav.SourceDomain.game, _session),
        _bound,
      ))!;
      final scope = repo.approvalScope(source)!;
      final first = await repo.search(
        source,
        scope,
        'not-present',
        null,
        null,
        _bound,
      );
      expect(first.items, isEmpty);
      expect(first.complete, isFalse);
      expect(first.exhaustedWork, isTrue);
      expect(first.candidatesExamined, lessThanOrEqualTo(4096));
      expect(first.candidatesExamined, greaterThan(0));
      Object? cursor = first.next;
      var completed = false;
      for (var step = 0; step < 32; step++) {
        final page = await repo.search(
          source,
          scope,
          'not-present',
          null,
          cursor,
          _bound,
        );
        expect(page.items, isEmpty);
        if (page.complete) {
          completed = true;
          break;
        }
        cursor = page.next;
      }
      expect(completed, isTrue);
    },
  );

  test(
    'complete long TEXT is not an arbitrary JSON page; engine scalar continuation',
    () async {
      final long = '😀${List.filled(5000, 'long text ').join()}';
      await f.db.customStatement(
        'INSERT INTO chat_summaries(session_id,content) VALUES(?,?)',
        [_session, long],
      );
      final repo = _repo(f);
      final source = (await repo.observe(
        const nav.SourceKey(nav.SourceDomain.savedSummary, _session),
        _bound,
      ))!;
      final hit = (await _searchAll(repo, source, 'long text')).single;
      expect(hit.payload, long);
      final read = await repo.read(
        source,
        repo.approvalScope(source)!,
        nav.ReadQuery(hit.selection, 0, 0),
        _bound,
      );
      expect(read.items.single.payload, long);
      expect(read.items.single.completeUnit, isTrue);
      final approval = _Approval(repo);
      final provenance = _Capture(repo);
      final run = nav.RunContext(
        Object(),
        'synthetic-run',
        const nav.Recipient('p', 'c', 'openai', 'm'),
      );
      final engine = nav.SourceNavigationEngine(
        run: run,
        repository: repo,
        owner: _Owner(),
        approval: approval,
        projection: _Projection(),
        provenance: provenance,
      );
      final listed = await engine.invoke('astoria_sources_list', {
        'domain': 'savedSummary',
      });
      final sourceHandle = (listed.wire['pieces'] as List).first['source'];
      final searched = await engine.invoke('astoria_source_search', {
        'source': sourceHandle,
        'literal': 'long text',
      });
      final selector = (searched.wire['pieces'] as List).first['selector'];
      final result = await engine.invoke('astoria_source_read', {
        'source': sourceHandle,
        'selector': selector,
      });
      expect(result.wire['status'], 'ok');
      expect(result.wire['partial'], isTrue);
      expect(result.wire['nextCursor'], isNotNull);
      expect(provenance.digests, everyElement(isNotNull));
      final tail = await engine.invoke('astoria_source_read', {
        'source': sourceHandle,
        'selector': result.wire['nextCursor'],
      });
      expect(tail.wire['status'], 'ok');
      expect(tail.wire['partial'], isTrue);
    },
  );

  test(
    'source outside selected extent and same-size ABA permanently invalidate',
    () async {
      final repo = _repo(f);
      final source = (await repo.observe(
        const nav.SourceKey(nav.SourceDomain.game, _session),
        _bound,
      ))!;
      await f.db.customStatement(
        'UPDATE chat_sessions SET draft = ? WHERE session_id = ?',
        ['A', _session],
      );
      await f.db.customStatement(
        'UPDATE chat_sessions SET draft = ? WHERE session_id = ?',
        [SupportTextContextFixture.secret, _session],
      );
      expect(await repo.revalidate(source, _bound), isFalse);
      expect(source.lease.isCurrent(), isFalse);
      expect(repo.lastFailure, SupportSourceReadFailure.changed);
      expect(source.lease.isCurrent(), isFalse);
      expect(await repo.revalidate(source, _bound), isFalse);
      expect(repo.lastFailure, SupportSourceReadFailure.changed);
    },
  );

  test(
    'clock is an exact complete saved tuple, not a synthesized partial clock',
    () async {
      for (final entry in {
        'world:time': '12:00',
        'world:date': '2026-10-26',
        'world:day': '4',
      }.entries) {
        await f.db.customStatement(
          'INSERT INTO tracker_rows(session_id,name,value,scope) VALUES(?,?,?,?)',
          [_session, entry.key, entry.value, 'ledger'],
        );
      }
      final repo = _repo(f);
      final source = (await repo.observe(
        const nav.SourceKey(nav.SourceDomain.ledgerState, _session),
        _bound,
      ))!;
      final scope = repo.approvalScope(source)!;
      final roots = await repo.contents(source, scope, null, null, _bound);
      final records = await repo.contents(
        source,
        scope,
        roots.items.single.selection,
        null,
        _bound,
      );
      final tuple = await repo.read(
        source,
        scope,
        nav.ReadQuery(records.items.first.selection, 0, 0),
        _bound,
      );
      expect(tuple.items.single.payload, {
        'time': '12:00',
        'date': '2026-10-26',
        'day': '4',
      });
      expect(tuple.items.single.binding.evidence.range, isNull);
    },
  );

  test(
    'search selectors and raw-capture digest cannot be forged or transferred',
    () async {
      await _index(f);
      await _index(f, 'synthetic-branch');
      final repo = _repo(f);
      final source = (await repo.observe(
        const nav.SourceKey(nav.SourceDomain.game, _session),
        _bound,
      ))!;
      final scope = repo.approvalScope(source)!;
      final selected = (await repo.search(
        source,
        scope,
        'Synthetic second',
        null,
        null,
        _bound,
      )).items.single;
      final run = nav.RunContext(
        Object(),
        'synthetic-private',
        const nav.Recipient('p', 'c', 'openai', 'm'),
      );
      final grant = nav.NativeGrant(
        run: run,
        source: source.key,
        snapshot: source.snapshot,
        scope: scope,
        disclosureBytes: 65536,
        lease: _Approval(repo),
      );
      nav.ProvenanceEntry entry({int end = 3}) => nav.ProvenanceEntry(
        run: run,
        source: source,
        grant: grant,
        operation: 'astoria_source_read',
        argumentsJson: '{}',
        exactWireJson: '{}',
        exactEnvelopeJson: '{}',
        projection: const nav.ProjectionStamp('synthetic-projection', 0),
        extents: [
          nav.DisclosedExtent(
            selected.selection,
            selected.binding,
            startScalar: 0,
            endScalar: end,
          ),
        ],
      );
      final original = entry();
      final digest = repo.privateDigestFor(original);
      expect(digest, isNotNull);
      expect(repo.nativeIdsFor(original), ['roleplay-b']);
      expect(repo.privateDigestFor(entry(end: 4)), isNot(digest));
      expect(_repo(f).privateDigestFor(original), isNull);
      final foreign = (await repo.observe(
        const nav.SourceKey(nav.SourceDomain.game, 'synthetic-branch'),
        _bound,
      ))!;
      await expectLater(
        repo.read(
          foreign,
          repo.approvalScope(foreign)!,
          nav.ReadQuery(selected.selection, 0, 0),
          _bound,
        ),
        throwsA(isA<SupportSourceReadException>()),
      );
    },
  );

  test(
    'Studio locked/unknown cleaner fields never become admitted saved text',
    () async {
      await f.db.customStatement(
        'INSERT INTO studio_preset_rows(preset_id,name,blocks_json) VALUES(?,?,?)',
        [
          'locked',
          'Local title',
          jsonEncode([
            {
              'id': 'locked',
              'kind': 'custom_text',
              'content': 'needle',
              'locked': true,
            },
          ]),
        ],
      );
      final repo = _repo(f);
      final source = (await repo.observe(
        const nav.SourceKey(nav.SourceDomain.studioPreset, 'locked'),
        _bound,
      ))!;
      await expectLater(
        _searchAll(repo, source, 'needle'),
        throwsA(isA<SupportSourceReadException>()),
      );
      expect(repo.lastFailure, SupportSourceReadFailure.locked);
      expect(source.lease.isCurrent(), isFalse);
      await f.db.customStatement(
        'INSERT INTO studio_preset_rows(preset_id,name,runtime_settings_json) VALUES(?,?,?)',
        [
          'unknown',
          'Local title',
          '{"cleaner":{"postCleanerExtraRequestParameters":[{"name":"needle"}]}}',
        ],
      );
      final next = _repo(f);
      final unknown = (await next.observe(
        const nav.SourceKey(nav.SourceDomain.studioPreset, 'unknown'),
        _bound,
      ))!;
      await expectLater(
        _searchAll(next, unknown, 'needle'),
        throwsA(isA<SupportSourceReadException>()),
      );
      expect(next.lastFailure, SupportSourceReadFailure.unsupportedFormat);
    },
  );

  test(
    'unpaired Unicode scalar inside original JSON TEXT is refused on approved read',
    () async {
      await f.replaceRoleplayJson(
        r'[{"id":"scalar","role":"user","content":"\ud800"}]',
      );
      final result = await f.db.historySourceIndex.maintain(
        sessionId: _session,
        isCurrent: () => true,
      );
      expect(result.state, HistoryIndexMaintenanceState.unsupported);
      final repo = _repo(f);
      final source = (await repo.observe(
        const nav.SourceKey(nav.SourceDomain.game, _session),
        _bound,
      ))!;
      expect(repo.approvalScope(source), isNull);
    },
  );

  test('external connection mutation uses actual data_version', () async {
    final repo = _repo(f);
    final source = (await repo.observe(
      const nav.SourceKey(nav.SourceDomain.game, _session),
      _bound,
    ))!;
    final external = sqlite.sqlite3.open(f.sourcePath);
    try {
      external.execute(
        'UPDATE chat_sessions SET draft = ? WHERE session_id = ?',
        ['foreign', _session],
      );
    } finally {
      external.close();
    }
    expect(await repo.revalidate(source, _bound), isFalse);
    expect(source.lease.isCurrent(), isFalse);
  });

  test('unattested +1 or +2 is never own provenance advancement', () async {
    final encrypted = await f.encrypt(
      'synthetic provenance',
      'support_context_blocks',
      'own',
      SupportTextContextFixture.supportId,
      'summary_ciphertext',
    );
    final repo = _repo(f);
    final source = (await repo.observe(
      const nav.SourceKey(nav.SourceDomain.game, _session),
      _bound,
    ))!;
    await f.db
        .into(f.db.supportContextBlocks)
        .insert(
          SupportContextBlocksCompanion.insert(
            id: 'own',
            sessionId: SupportTextContextFixture.supportId,
            startMessageId: 'support-a',
            endMessageId: 'support-b',
            summaryCiphertext: encrypted,
          ),
        );
    // No attestation constructor exists. A generic single-row INSERT cannot be
    // passed to the advance seam; it is detected as an unrelated source fence.
    expect(await repo.revalidate(source, _bound), isFalse);
    expect(source.lease.isCurrent(), isFalse);
    final other = _repo(f);
    final observed = (await other.observe(
      const nav.SourceKey(nav.SourceDomain.game, _session),
      _bound,
    ))!;
    await f.db.customStatement(
      'UPDATE chat_sessions SET draft = ? WHERE session_id = ?',
      ['one', _session],
    );
    await f.db.customStatement(
      'UPDATE chat_sessions SET draft = ? WHERE session_id = ?',
      ['two', _session],
    );
    expect(await other.revalidate(observed, _bound), isFalse);
    expect(observed.lease.isCurrent(), isFalse);
  });

  test(
    'Stop is checked at SQL awaits and cannot revive the original owner',
    () async {
      var checks = 0, current = true;
      final repo = _repo(
        f,
        current: () {
          checks++;
          return current && checks < 9;
        },
      );
      await expectLater(
        repo.observe(
          const nav.SourceKey(nav.SourceDomain.game, _session),
          _bound,
        ),
        throwsA(isA<SupportSourceReadException>()),
      );
      current = true;
      await expectLater(
        repo.discover(nav.SourceDomain.game, null, null, _bound),
        throwsA(isA<SupportSourceReadException>()),
      );
    },
  );

  test(
    'strict duplicate-key/unknown shape and malformed variation fail closed',
    () async {
      await f.replaceRoleplayJson(
        '[{"id":"bad","role":"assistant","content":"one",'
        '"content":"two","swipeId":0,"agentSwipeId":0}]',
      );
      expect(
        (await f.db.historySourceIndex.maintain(
          sessionId: _session,
          isCurrent: () => true,
        )).state,
        HistoryIndexMaintenanceState.unsupported,
      );
      await f.replaceRoleplay([
        {...SupportTextContextFixture.message('bad'), 'agentSwipeId': 99},
      ]);
      expect(
        (await f.db.historySourceIndex.maintain(
          sessionId: _session,
          isCurrent: () => true,
        )).state,
        HistoryIndexMaintenanceState.unsupported,
      );
      await f.db.customStatement(
        'INSERT INTO memory_book_rows(session_id,entries_json) VALUES(?,?)',
        [_session, '[{"id":"entry","content":"needle","status":"invented"}]'],
      );
      final repo = _repo(f);
      final memory = (await repo.observe(
        const nav.SourceKey(nav.SourceDomain.memory, _session),
        _bound,
      ))!;
      await expectLater(
        _searchAll(repo, memory, 'needle'),
        throwsA(isA<SupportSourceReadException>()),
      );
    },
  );
}

final class _Owner implements nav.OwnerPort {
  @override
  bool isOriginalOwnerCurrent(nav.RunContext run) => true;
}

final class _Approval implements nav.ApprovalPort, nav.ApprovalLease {
  _Approval(this.repo);
  final SupportSourceNavigationRepo repo;
  @override
  bool isCurrent() => true;
  @override
  Future<nav.NativeGrant?> request(nav.ApprovalRequest request) async =>
      nav.NativeGrant(
        run: request.run,
        source: request.source.key,
        snapshot: request.source.snapshot,
        scope: repo.approvalScope(request.source)!,
        disclosureBytes: request.maximumDisclosureBytes,
        lease: this,
      );
}

final class _Projection implements nav.ProjectionPort {
  static const stamp = nav.ProjectionStamp('synthetic-projection', 0);
  @override
  Future<nav.ProjectedRecord> project(nav.DataRecord record) async =>
      nav.ProjectedRecord(record.payload, stamp);
  @override
  Future<nav.ProjectionStamp> currentStamp() async => stamp;
  @override
  Future<nav.ProjectedWire> wire(nav.WireCandidate candidate) async =>
      nav.ProjectedWire(candidate, candidate.wire, stamp);
}

/// Engine-shape test port ONLY; not a claim of durable native host provenance.
final class _Capture implements nav.ProvenancePort {
  _Capture(this.repo);
  final SupportSourceNavigationRepo repo;
  final digests = <String?>[];
  @override
  Future<nav.ProvenanceReceipt> append(nav.ProvenanceEntry entry) async {
    final digest = repo.privateDigestFor(entry);
    digests.add(digest);
    expect(repo.nativeIdsFor(entry)!.length, lessThanOrEqualTo(16));
    return nav.ProvenanceReceipt(entry, durableEncrypted: digest != null);
  }
}
