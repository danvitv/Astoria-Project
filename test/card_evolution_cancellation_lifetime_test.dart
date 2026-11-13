import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/applied_canon_transition_repo.dart';
import 'package:glaze_flutter/core/db/repositories/canon_transition_fact_ref_repo.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_knowledge_fact_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_revision_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_session_baseline_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_raw_tracker_state_reader.dart';
import 'package:glaze_flutter/core/db/repositories/manual_rewrite_job_repo.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/aux_retry_runner.dart';
import 'package:glaze_flutter/core/models/agent_operation_record.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/services/card_rewriter/automated_card_evolution_service.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_evolution_collector_coordinator.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_read_repository.dart';

const _config = AuxApiConfig(
  endpoint: 'https://example.invalid/completions',
  apiKey: 'test',
  model: 'test',
  protocol: 'openai',
  maxTokens: 1000,
);

void main() {
  late AppDatabase db;
  late _CancellationRepo repo;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final characters = CharacterRepo(db);
    final revisions = CharacterRevisionRepo(db);
    const character = Character(
      id: 'character',
      name: 'Alice',
      description: 'Alice is cautious.',
    );
    await characters.put(character);
    await revisions.insert(
      CharacterRevisionRecord(
        characterId: character.id,
        revision: 1,
        revisionHash: CardCanonicalizer.sha256(character),
        parentRevisionHash: '',
        snapshotJson: jsonEncode(character.toJson()),
        createdAt: 1,
      ),
    );
    await db.customStatement(
      'INSERT INTO chat_sessions '
      '(session_id, character_id, session_index, messages_json) '
      'VALUES (?, ?, 0, ?)',
      [
        'session',
        'character',
        jsonEncode([
          {'id': 'a1', 'role': 'assistant', 'content': 'Alice is cautious.'},
          {'id': 'u1', 'role': 'user', 'content': 'I reassure Alice.'},
          {'id': 'a2', 'role': 'assistant', 'content': 'Alice trusts me.'},
          {'id': 'u2', 'role': 'user', 'content': 'I promise to help.'},
        ]),
      ],
    );
    repo = _CancellationRepo(
      db: db,
      canonReader: EffectiveCanonReadRepository(
        db: db,
        characterRepo: characters,
        revisionRepo: revisions,
        baselineRepo: CharacterSessionBaselineRepo(db),
        factRepo: CharacterKnowledgeFactRepo(db),
        transitionRepo: AppliedCanonTransitionRepo(db),
        transitionFactRefRepo: CanonTransitionFactRefRepo(db),
      ),
      jobRepo: ManualRewriteJobRepo(
        db: db,
        rawTrackerStateReader: LedgerRawTrackerStateReader(db),
      ),
    );
  });
  tearDown(() => db.close());

  AutomatedCardEvolutionService service({
    Future<AuxApiConfig> Function()? writerResolver,
    CardEvolutionCollectorModelResolver? collectorResolver,
    required Future<AuxCallOutcome> Function(CancelToken?, String) execute,
    bool Function()? isStillCurrent,
  }) => AutomatedCardEvolutionService(
    repo: repo,
    resolveModel: writerResolver ?? () async => _config,
    resolveCollectorModel: collectorResolver ?? (_) async => _config,
    isStillCurrent: isStillCurrent,
    executor:
        ({
          required config,
          required prompt,
          required maxTokens,
          required temperature,
          required timeoutMs,
          cancelToken,
          captureContext,
        }) => execute(cancelToken, prompt),
  );

  Future<void> expectNoProposal() async {
    expect(await db.select(db.rewriteJobs).get(), isEmpty);
    expect(await db.select(db.cardEvolutionProposalRuns).get(), isEmpty);
    expect(await db.select(db.cardEvolutionObservations).get(), isEmpty);
  }

  test(
    'dispose during blocked writer resolution never starts transport',
    () async {
      final entered = Completer<void>();
      final release = Completer<AuxApiConfig>();
      var calls = 0;
      final lane = service(
        writerResolver: () {
          entered.complete();
          return release.future;
        },
        execute: (_, _) async {
          calls++;
          return _ok('{"operations":[]}');
        },
      );
      final pending = lane.runOneBatch('session');
      await entered.future;
      lane.dispose();
      release.complete(_config);
      expect((await pending).kind, 'cancelled');
      expect((await lane.runOneBatch('session')).kind, 'cancelled');
      expect((await lane.runPendingCollectors('session')).kind, 'cancelled');
      expect(calls, 0);
      await expectNoProposal();
    },
  );

  test(
    'dispose during collector preparation cannot install late transport',
    () async {
      repo.manualCollector = true;
      final entered = Completer<void>();
      final release = Completer<AuxApiConfig>();
      var calls = 0;
      final lane = service(
        collectorResolver: (_) {
          entered.complete();
          return release.future;
        },
        execute: (_, _) async {
          calls++;
          return _ok('{"observations":[]}');
        },
      );
      final pending = lane.runOneBatch('session');
      await entered.future;
      lane.dispose();
      release.complete(_config);
      expect((await pending).kind, 'cancelled');
      expect(calls, 0);
      await expectNoProposal();
    },
  );

  test(
    'cancelled collector cannot launch writer, but next manual run can',
    () async {
      repo.manualCollector = true;
      final entered = Completer<void>();
      final release = Completer<AuxCallOutcome>();
      var calls = 0;
      final lane = service(
        execute: (_, _) {
          calls++;
          if (calls == 1) {
            entered.complete();
            return release.future;
          }
          return Future.value(_ok(_proposal));
        },
      );
      final pending = lane.runOneBatch('session');
      await entered.future;
      lane.cancelSession('session');
      release.complete(_ok('{"observations":[]}'));
      expect((await pending).kind, 'cancelled');
      expect(calls, 1);
      repo.manualCollector = false;
      await expectNoProposal();
      expect((await lane.runOneBatch('session')).kind, 'persisted');
      expect(calls, 2);
      lane.dispose();
      expect(await db.select(db.rewriteJobs).get(), hasLength(1));
    },
  );

  test(
    'aborted collector outcome is not swallowed by best-effort refresh',
    () async {
      repo.manualCollector = true;
      var calls = 0;
      final lane = service(
        execute: (_, _) async {
          calls++;
          return const AuxCallOutcome(status: AgentOperationStatus.aborted);
        },
      );
      expect((await lane.runOneBatch('session')).kind, 'cancelled');
      expect(calls, 1);
      lane.dispose();
      await expectNoProposal();
    },
  );

  test('stale late writer output cannot persist or start repair', () async {
    final entered = Completer<void>();
    final release = Completer<AuxCallOutcome>();
    var active = true;
    var calls = 0;
    final lane = service(
      isStillCurrent: () => active,
      execute: (_, _) {
        calls++;
        entered.complete();
        return release.future;
      },
    );
    final pending = lane.runOneBatch('session');
    await entered.future;
    active = false;
    release.complete(_ok(_proposal));
    expect((await pending).kind, 'cancelled');
    expect(calls, 1);
    lane.dispose();
    await expectNoProposal();
  });
}

AuxCallOutcome _ok(String text) =>
    AuxCallOutcome(status: AgentOperationStatus.ok, text: text);

String get _proposal => jsonEncode({
  'operations': [
    {
      'field': 'description',
      'patches': [
        {
          'scopeKey': 'npc:alice',
          'anchor': 'Alice is cautious.',
          'anchorSha256': CardCanonicalizer.scalarSha256('Alice is cautious.'),
          'value': 'Alice is increasingly trusting.',
        },
      ],
      'transition': {
        'id': 'transition',
        'scopeKey': 'npc:alice',
        'canonicalClaim': 'Alice is increasingly trusting.',
        'promotionDestination': 'description',
        'affectedTrackerKeys': <String>[],
        'factIds': <String>[],
        'chatSessionId': null,
      },
    },
  ],
});

// Keep setup synthetic only at the cadence boundary; actual snapshots, writer
// claims, calls, and proposal storage use the production repositories.
final class _CancellationRepo extends CardEvolutionRepo {
  _CancellationRepo({
    required super.db,
    required super.canonReader,
    required super.jobRepo,
  });

  bool manualCollector = false;

  @override
  Future<int> countSuccessfulReconciliations(String sessionId) async =>
      manualCollector ? 3 : 0;
}
