import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/applied_canon_transition_repo.dart';
import 'package:glaze_flutter/core/db/repositories/canon_transition_fact_ref_repo.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_observation_repo.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_collector_run_repo.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_repo.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_job_repo.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_selected_input_validator.dart';
import 'package:glaze_flutter/core/db/repositories/character_knowledge_fact_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_revision_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_session_baseline_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_raw_tracker_state_reader.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_run_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_snapshot_repo.dart';
import 'package:glaze_flutter/core/db/repositories/llm_request_capture_repo.dart';
import 'package:glaze_flutter/core/db/repositories/manual_rewrite_job_repo.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/aux_retry_runner.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/llm/transport/llm_call_event.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/llm_request_capture.dart';
import 'package:glaze_flutter/core/models/agent_operation_record.dart';
import 'package:glaze_flutter/core/models/card_evolution_observation.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/models/tracker_snapshot.dart';
import 'package:glaze_flutter/core/services/card_rewriter/automated_card_evolution_service.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_read_repository.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';
import 'package:glaze_flutter/core/utils/time_helpers.dart';

void main() {
  late _Fixture fixture;

  setUp(() async {
    fixture = await _Fixture.create();
  });
  tearDown(() => fixture.db.close());

  test('zero reconciliation runs skips observation pass', () async {
    var calls = 0;
    await fixture
        .service((_, prompt) async {
          calls++;
          return _ok(fixture.cardBatchOutput);
        })
        .runOneBatch('session');
    expect(calls, 1);
    expect(
      await fixture.observationRepo.getActiveObservations('session'),
      isEmpty,
    );
  });

  test('incomplete reconciliation batch skips observation pass', () async {
    await fixture.seedReconciliationRun(ordinal: 1);
    var calls = 0;
    await fixture
        .service((_, prompt) async {
          calls++;
          return _ok(fixture.cardBatchOutput);
        })
        .runOneBatch('session');
    expect(calls, 1);
  });

  test('scope outside available Ledger targets gets one repair', () async {
    await fixture.seedReconciliationRun(ordinal: 1);
    var calls = 0;
    final invalid = jsonDecode(fixture.cardBatchOutput) as Map<String, dynamic>;
    final operation = (invalid['operations'] as List).single as Map;
    ((operation['patches'] as List).single as Map)['scopeKey'] = 'npc:Боб';
    (operation['transition'] as Map)['scopeKey'] = 'npc:Боб';

    final result = await fixture
        .service((_, prompt) async {
          calls++;
          if (calls == 1) return _ok(jsonEncode(invalid));
          expect(prompt, contains('not an available retrieval target'));
          expect(prompt, contains('npc:Алиса'));
          return _ok(fixture.cardBatchOutput);
        })
        .runOneBatch('session');

    expect(result.kind, 'persisted');
    expect(calls, 2);
  });

  test(
    'complete reconciliation batch runs observation pass before card writer',
    () async {
      await fixture.seedReconciliationRun(ordinal: 1);
      await fixture.seedReconciliationRun(ordinal: 2);
      await fixture.seedReconciliationRun(ordinal: 3);
      final prompts = <String>[];
      await fixture
          .service((_, prompt) async {
            prompts.add(prompt);
            if (prompt.contains('observation journal keeper')) {
              return _ok(fixture.observationNewOutput);
            }
            return _ok(fixture.cardBatchOutput);
          })
          .runOneBatch('session');
      expect(prompts, hasLength(2));
      expect(prompts.first, contains('observation journal keeper'));
      expect(prompts.last, contains('Astoria card rewriter'));
      final active = await fixture.observationRepo.getActiveObservations(
        'session',
      );
      expect(active, hasLength(1));
      expect(active.first.semanticScopeKey, 'character.preference.trust');
      expect(active.first.status, 'active');
      expect(active.first.repeatCount, 1);
    },
  );

  test(
    'promoted observation appears as validated target in card writer prompt',
    () async {
      await fixture.seedReconciliationRun(ordinal: 1);
      await fixture.observationRepo.insertObservation(
        CardEvolutionObservation(
          id: 'obs-promoted',
          sessionId: 'session',
          characterId: 'character',
          runOrdinal: 1,
          semanticScopeKey: 'character.preference.trust',
          observedChange: 'Alice is consistently more trusting',
          canonicalClaim: 'Alice has become more trusting',
          evidenceClusters: const [
            ['a1', 'u1'],
          ],
          retrievalKeys: const ['npc:Алиса'],
          targetKind: 'main_character_card',
          cardFieldPath: 'personality',
          confidence: 0.9,
          status: 'promoted',
          firstSeenRun: 1,
          repeatCount: 3,
          lastConfirmedRun: 3,
          createdAt: 10,
          updatedAt: 10,
        ),
      );
      String? cardPrompt;
      await fixture
          .service((_, prompt) async {
            if (!prompt.contains('observation journal keeper')) {
              cardPrompt = prompt;
            }
            return _ok(fixture.cardBatchOutput);
          })
          .runOneBatch('session');
      expect(cardPrompt, isNotNull);
      expect(
        cardPrompt,
        contains('Accumulated candidates from observation journal'),
      );
      expect(cardPrompt, contains('character.preference.trust'));
    },
  );

  test('card writer prompt does not duplicate the card snapshot', () async {
    await fixture.seedReconciliationRun(ordinal: 1);
    String? cardPrompt;
    await fixture
        .service((_, prompt) async {
          if (!prompt.contains('observation journal keeper')) {
            cardPrompt = prompt;
          }
          return _ok(fixture.cardBatchOutput);
        })
        .runOneBatch('session');
    expect(cardPrompt, isNotNull);
    final snapshotIndex = cardPrompt!.indexOf(
      '# Canonical character card snapshot (read-only)',
    );
    expect(snapshotIndex, greaterThanOrEqualTo(0));
    final snapshotOccurrences = '# Canonical character card snapshot'
        .allMatches(cardPrompt!)
        .length;
    expect(snapshotOccurrences, 1);
    final historyStart = cardPrompt!.indexOf(
      '# Immutable chat history and effective canon',
    );
    expect(historyStart, greaterThan(snapshotIndex));
    final historyPayload = cardPrompt!.substring(historyStart);
    expect(historyPayload, isNot(contains('"card":{')));
  });

  test(
    'writer excludes an active observation unrelated to current ranges',
    () async {
      await fixture.seedReconciliationRun(ordinal: 1);
      await fixture.observationRepo.insertObservation(
        CardEvolutionObservation(
          id: 'obs-unrelated',
          sessionId: 'session',
          characterId: 'character',
          runOrdinal: 1,
          semanticScopeKey: 'relationship:Неизвестный',
          observedChange: 'Must not be globally injected',
          evidenceClusters: const [
            ['a1'],
          ],
          retrievalKeys: const ['relationship:Неизвестный.секрет'],
          targetKind: 'main_character_card',
          confidence: 0.9,
          status: 'active',
          firstSeenRun: 1,
          createdAt: 10,
          updatedAt: 10,
        ),
      );
      String? cardPrompt;
      await fixture
          .service((_, prompt) async {
            cardPrompt = prompt;
            return _ok(fixture.cardBatchOutput);
          })
          .runOneBatch('session');
      expect(cardPrompt, isNot(contains('Must not be globally injected')));
      expect(
        await fixture.observationRepo.findById('obs-unrelated'),
        isNotNull,
      );
    },
  );

  test('card writer excludes lorebook-target observations', () async {
    await fixture.seedReconciliationRun(ordinal: 1);
    await fixture.observationRepo.insertObservation(
      CardEvolutionObservation(
        id: 'npc-lore-only',
        sessionId: 'session',
        characterId: 'character',
        runOrdinal: 1,
        semanticScopeKey: 'npc:Алиса',
        observedChange: 'NPC-owned lorebook-only fact',
        evidenceClusters: const [
          ['a1'],
        ],
        retrievalKeys: const ['npc:Алиса'],
        targetKind: 'injected_lorebook_entry',
        lorebookEntryId: 'book:alice',
        confidence: 0.9,
        status: 'active',
        firstSeenRun: 1,
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    String? cardPrompt;
    await fixture
        .service((_, prompt) async {
          cardPrompt = prompt;
          return _ok(fixture.cardBatchOutput);
        })
        .runOneBatch('session');
    expect(cardPrompt, isNot(contains('NPC-owned lorebook-only fact')));
  });

  test('promotion after threshold confirmations', () async {
    await fixture.seedReconciliationRun(ordinal: 1);
    await fixture.seedReconciliationRun(ordinal: 2);
    await fixture.seedReconciliationRun(ordinal: 3);
    await fixture.observationRepo.insertObservation(
      CardEvolutionObservation(
        id: 'obs-1',
        sessionId: 'session',
        characterId: 'character',
        runOrdinal: 0,
        semanticScopeKey: 'character.preference.trust',
        observedChange: 'Alice is becoming more trusting',
        canonicalClaim: 'Alice has become more trusting',
        evidenceClusters: const [
          ['a1'],
          ['u1'],
        ],
        retrievalKeys: const ['npc:Алиса'],
        targetKind: 'main_character_card',
        cardFieldPath: 'personality',
        confidence: 0.8,
        status: 'active',
        firstSeenRun: 1,
        repeatCount: 2,
        lastConfirmedRun: 0,
        createdAt: 10,
        updatedAt: 10,
      ),
    );
    await fixture
        .service((_, prompt) async {
          if (prompt.contains('observation journal keeper')) {
            return _ok(fixture.observationConfirmOutput);
          }
          return _ok(fixture.cardBatchOutput);
        })
        .runOneBatch('session');
    // Proposal persistence is review-only, so promotion remains available
    // until the user actually applies the proposal.
    final obs = await fixture.observationRepo.findById('obs-1');
    expect(obs, isNotNull);
    expect(obs!.status, 'promoted');
    expect(obs.repeatCount, 3);
  });

  test('persisted proposal does not consume promoted observations', () async {
    await fixture.observationRepo.insertObservation(
      CardEvolutionObservation(
        id: 'obs-promoted',
        sessionId: 'session',
        characterId: 'character',
        runOrdinal: 1,
        semanticScopeKey: 'character.preference.trust',
        observedChange: 'Alice is consistently more trusting',
        evidenceClusters: const [
          ['a1'],
        ],
        confidence: 0.9,
        status: 'promoted',
        firstSeenRun: 1,
        repeatCount: 3,
        lastConfirmedRun: 3,
        createdAt: 10,
        updatedAt: 10,
      ),
    );
    final result = await fixture
        .service((_, _) async => _ok(fixture.cardBatchOutput))
        .runOneBatch('session');
    expect(result.kind, 'persisted');
    expect(
      await fixture.observationRepo.getPromotedObservations('session'),
      hasLength(1),
    );
  });

  test('observation pass failure does not block card writer', () async {
    await fixture.seedReconciliationRun(ordinal: 1);
    await fixture.seedReconciliationRun(ordinal: 2);
    await fixture.seedReconciliationRun(ordinal: 3);
    var calls = 0;
    final result = await fixture
        .service((_, prompt) async {
          calls++;
          if (prompt.contains('observation journal keeper')) {
            return _ok('not valid json');
          }
          return _ok(fixture.cardBatchOutput);
        })
        .runOneBatch('session');
    expect(calls, 2);
    expect(result.kind, 'persisted');
    expect(
      await fixture.observationRepo.getActiveObservations('session'),
      isEmpty,
    );
  });

  test('no evidence does not expire or otherwise mutate observation', () async {
    await fixture.seedReconciliationRun(ordinal: 1);
    await fixture.seedReconciliationRun(ordinal: 2);
    await fixture.seedReconciliationRun(ordinal: 3);
    await fixture.observationRepo.insertObservation(
      CardEvolutionObservation(
        id: 'obs-stale',
        sessionId: 'session',
        characterId: 'character',
        runOrdinal: 1,
        semanticScopeKey: 'character.preference.trust',
        observedChange: 'Alice is becoming more trusting',
        evidenceClusters: const [
          ['a1'],
        ],
        confidence: 0.6,
        status: 'active',
        firstSeenRun: 1,
        repeatCount: 1,
        lastConfirmedRun: 1,
        createdAt: 10,
        updatedAt: 10,
      ),
    );
    await fixture
        .service(
          (_, prompt) async => _ok(
            prompt.contains('observation journal keeper')
                ? jsonEncode({
                    'observations': [
                      {
                        'action': 'no_evidence',
                        'scopeKey': 'character.preference.trust',
                        'evidenceMessageIds': <String>[],
                        'confidence': 0.6,
                      },
                    ],
                  })
                : fixture.cardBatchOutput,
          ),
        )
        .runOneBatch('session');
    final active = await fixture.observationRepo.getActiveObservations(
      'session',
    );
    expect(active, hasLength(1));
    expect(active.single.updatedAt, 10);
  });

  test(
    'explicit contradiction with valid evidence expires observation',
    () async {
      await fixture.seedReconciliationRun(ordinal: 1);
      await fixture.seedReconciliationRun(ordinal: 2);
      await fixture.seedReconciliationRun(ordinal: 3);
      await fixture.observationRepo.insertObservation(
        CardEvolutionObservation(
          id: 'obs-contradicted',
          sessionId: 'session',
          characterId: 'character',
          runOrdinal: 0,
          semanticScopeKey: 'character.preference.trust',
          observedChange: 'Alice is becoming more trusting',
          evidenceClusters: const [
            ['a1'],
          ],
          retrievalKeys: const ['npc:Алиса'],
          targetKind: 'main_character_card',
          confidence: 0.7,
          status: 'active',
          firstSeenRun: 1,
          createdAt: 10,
          updatedAt: 10,
        ),
      );
      await fixture
          .service((_, prompt) async {
            if (prompt.contains('observation journal keeper')) {
              return _ok(
                jsonEncode({
                  'observations': [
                    {
                      'action': 'contradict',
                      'scopeKey': 'character.preference.trust',
                      'evidenceMessageIds': ['a2'],
                      'retrievalKeys': ['npc:Алиса'],
                      'targetKind': 'main_character_card',
                      'confidence': 0.2,
                    },
                  ],
                }),
              );
            }
            return _ok(fixture.cardBatchOutput);
          })
          .runOneBatch('session');
      expect(
        (await fixture.observationRepo.findById('obs-contradicted'))!.status,
        'expired',
      );
    },
  );

  test('fabricated evidence IDs cannot create observations', () async {
    await fixture.seedReconciliationRun(ordinal: 1);
    await fixture.seedReconciliationRun(ordinal: 2);
    await fixture.seedReconciliationRun(ordinal: 3);
    await fixture
        .service((_, prompt) async {
          if (prompt.contains('observation journal keeper')) {
            return _ok(
              jsonEncode({
                'observations': [
                  {
                    'action': 'new',
                    'scopeKey': 'character.preference.fabricated',
                    'observedChange': 'Fabricated change',
                    'evidenceMessageIds': ['not-in-chat'],
                    'confidence': 0.9,
                  },
                ],
              }),
            );
          }
          return _ok(fixture.cardBatchOutput);
        })
        .runOneBatch('session');
    expect(
      await fixture.observationRepo.getActiveObservations('session'),
      isEmpty,
    );
  });

  test(
    'duplicate scopes and non-string evidence reject the whole output',
    () async {
      await fixture.seedReconciliationRun(ordinal: 1);
      await fixture.seedReconciliationRun(ordinal: 2);
      await fixture
          .service((_, prompt) async {
            if (prompt.contains('observation journal keeper')) {
              return _ok(
                jsonEncode({
                  'observations': [
                    {
                      'action': 'new',
                      'scopeKey': 'character.preference.trust',
                      'observedChange': 'First',
                      'evidenceMessageIds': ['a1'],
                      'confidence': 0.8,
                    },
                    {
                      'action': 'confirm',
                      'scopeKey': 'character.preference.trust',
                      'evidenceMessageIds': [1],
                      'confidence': 0.8,
                    },
                  ],
                }),
              );
            }
            return _ok(fixture.cardBatchOutput);
          })
          .runOneBatch('session');
      expect(
        await fixture.observationRepo.getActiveObservations('session'),
        isEmpty,
      );
    },
  );

  test(
    'automatic collector runs every third reconciliation and writer every fifth collector',
    () async {
      final prompts = <String>[];
      final contexts = <LlmCaptureContext>[];
      final service = fixture.service((_, prompt) async {
        prompts.add(prompt);
        return prompt.contains('observation journal keeper')
            ? _ok('{"observations":[]}')
            : _ok('{"operations":[]}');
      }, onCaptureContext: contexts.add);
      for (var ordinal = 1; ordinal <= 30; ordinal++) {
        final run = await fixture.seedReconciliationRun(ordinal: ordinal);
        final result = await service.runAfterReconciliation(run);
        expect(
          result.kind,
          ordinal % 15 == 0 ? 'emptyModelProposal' : 'collectorCompleted',
        );
        expect(
          prompts.where((value) => value.contains('Astoria card rewriter')),
          hasLength(ordinal ~/ 15),
        );
      }
      expect(
        prompts.where((value) => value.contains('observation journal keeper')),
        hasLength(10),
      );
      expect(
        prompts.where((value) => value.contains('Astoria card rewriter')),
        hasLength(2),
      );
      final collectors = await fixture.db
          .select(fixture.db.cardEvolutionCollectorRuns)
          .get();
      expect(collectors, hasLength(10));
      expect(collectors.map((run) => run.reconciliationRunOrdinal), [
        for (var ordinal = 3; ordinal <= 30; ordinal += 3) ordinal,
      ]);
      expect(collectors.every((run) => run.status == 'completed'), isTrue);
      final claims = await fixture.db
          .select(fixture.db.cardEvolutionClaims)
          .get();
      expect(claims.map((claim) => claim.predecessorRunOrdinal), [5, 10]);
      expect(claims.every((claim) => claim.status == 'completed'), isTrue);
      expect(claims.every((claim) => claim.rewriteJobId == null), isTrue);
      for (final claim in claims) {
        final input = jsonDecode(claim.selectedInputJson!) as Map;
        final ids = (input['limits'] as Map)['reconciliationRunIds'] as List;
        final start = claim.predecessorRunOrdinal == 5 ? 1 : 16;
        expect(ids, [for (var i = start; i < start + 15; i++) 'run-$i']);
      }
      final collectorContexts = contexts
          .where((context) => context.stage == 'card.collector')
          .toList();
      expect(collectorContexts.map((context) => context.stageOrdinal), [
        for (var ordinal = 1; ordinal <= 10; ordinal++) ordinal,
      ]);
      expect(
        collectorContexts.every((context) => context.sessionId == 'session'),
        isTrue,
      );
    },
  );

  test(
    'delayed automatic job neither consumes future runs nor resets their journal',
    () async {
      final runs = [
        for (var ordinal = 1; ordinal <= 18; ordinal++)
          await fixture.seedReconciliationRun(ordinal: ordinal),
      ];
      var collectorCalls = 0;
      var writerCalls = 0;
      final service = fixture.service((_, prompt) async {
        if (prompt.contains('observation journal keeper')) {
          collectorCalls++;
          return _ok('{"observations":[]}');
        }
        writerCalls++;
        return _ok('{"operations":[]}');
      });
      await service.runAfterReconciliation(runs[2]);
      expect(collectorCalls, 1);
      expect(writerCalls, 0);
      await service.runAfterReconciliation(runs.last);
      expect(collectorCalls, 6);
      expect(writerCalls, 1);
      final journal = await fixture.collectorRepo.readSession('session');
      expect(journal, hasLength(6));
      await service.runAfterReconciliation(runs[2]);
      expect(collectorCalls, 6);
      expect(writerCalls, 1);
      expect(
        (await fixture.collectorRepo.readSession(
          'session',
        )).map((row) => row.id),
        journal.map((row) => row.id),
      );
      service.dispose();
    },
  );

  test(
    'durable job cancellation fences collector effects without a local Stop',
    () async {
      for (var ordinal = 1; ordinal <= 3; ordinal++) {
        await fixture.seedReconciliationRun(ordinal: ordinal);
      }
      final jobs = CardEvolutionJobRepo(fixture.db);
      final now = currentTimestampSeconds();
      final job = await jobs.enqueue(
        sessionId: 'session',
        characterId: 'character',
        reconciliationRunId: 'run-3',
        routingSnapshotJson: '{}',
        routingSnapshotHash: 'hash',
        now: now - 2,
      );
      final claimed = (await jobs.claim(
        id: job.id,
        now: now,
        leaseSeconds: 900,
      ))!;
      final service = fixture.service(
        (_, prompt) async {
          await jobs.cancel(id: job.id, now: now);
          return _ok(fixture.observationNewOutput);
        },
        isCommitCurrent: () =>
            jobs.isOwned(id: job.id, ownerNonce: claimed.ownerNonce!, now: now),
      );
      await service.runAfterReconciliation(
        (await LedgerReconciliationRunRepo(
          fixture.db,
        ).readSession('session')).last,
      );
      expect(
        await fixture.observationRepo.getActiveObservations('session'),
        isEmpty,
      );
      expect(
        (await fixture.collectorRepo.readSession(
          'session',
        )).where((row) => row.status == 'completed'),
        isEmpty,
      );
      expect((await jobs.getById(job.id))!.status, 'cancelled');
      service.dispose();
    },
  );

  for (final empty in [false, true]) {
    test(
      'durable cancellation fences ${empty ? 'empty writer boundary' : 'writer proposal'} transaction',
      () async {
        for (var ordinal = 1; ordinal <= 15; ordinal++) {
          await fixture.seedReconciliationRun(ordinal: ordinal);
        }
        final jobs = CardEvolutionJobRepo(fixture.db);
        final now = currentTimestampSeconds();
        final job = await jobs.enqueue(
          sessionId: 'session',
          characterId: 'character',
          reconciliationRunId: 'run-15',
          routingSnapshotJson: '{}',
          routingSnapshotHash: 'hash',
          now: now - 2,
        );
        final claimed = (await jobs.claim(
          id: job.id,
          now: now,
          leaseSeconds: 900,
        ))!;
        var writerCalls = 0;
        final service = fixture.service(
          (_, prompt) async {
            if (prompt.contains('observation journal keeper')) {
              return _ok('{"observations":[]}');
            }
            writerCalls++;
            await jobs.cancel(id: job.id, now: now);
            return _ok(empty ? '{"operations":[]}' : fixture.cardBatchOutput);
          },
          isCommitCurrent: () => jobs.isOwned(
            id: job.id,
            ownerNonce: claimed.ownerNonce!,
            now: now,
          ),
        );
        final result = await service.runAfterReconciliation(
          (await LedgerReconciliationRunRepo(
            fixture.db,
          ).readSession('session')).last,
        );
        expect(writerCalls, 1);
        expect(result.kind, isNot('persisted'));
        expect(await fixture.db.select(fixture.db.rewriteJobs).get(), isEmpty);
        expect(
          await fixture.collectorRepo.latestDeliveredWriterBoundary('session'),
          0,
        );
        expect(
          (await fixture.collectorRepo.readSession(
            'session',
          )).where((row) => row.status == 'completed'),
          hasLength(5),
        );
        service.dispose();
      },
    );
  }

  for (final empty in [false, true]) {
    test(
      'local cancellation during final durable check rolls back ${empty ? 'empty boundary' : 'proposal'}',
      () async {
        for (var ordinal = 1; ordinal <= 15; ordinal++) {
          await fixture.seedReconciliationRun(ordinal: ordinal);
        }
        var writerResponded = false;
        var writerChecks = 0;
        late AutomatedCardEvolutionService service;
        service = fixture.service(
          (_, prompt) async {
            if (prompt.contains('observation journal keeper')) {
              return _ok('{"observations":[]}');
            }
            writerResponded = true;
            return _ok(empty ? '{"operations":[]}' : fixture.cardBatchOutput);
          },
          isCommitCurrent: () async {
            if (writerResponded && ++writerChecks == 2) {
              // The final guard runs after staged writes, within their SQLite
              // transaction. Durable Cancel would queue behind that transaction.
              if (empty) {
                expect(
                  await fixture.collectorRepo.latestDeliveredWriterBoundary(
                    'session',
                  ),
                  5,
                );
              } else {
                expect(
                  await fixture.db.select(fixture.db.rewriteJobs).get(),
                  hasLength(1),
                );
              }
              await Future<void>.value();
              service.cancelSession('session');
            }
            return true;
          },
        );
        final result = await service.runAfterReconciliation(
          (await LedgerReconciliationRunRepo(
            fixture.db,
          ).readSession('session')).last,
        );
        expect(writerChecks, 2);
        expect(result.kind, isNot('persisted'));
        expect(await fixture.db.select(fixture.db.rewriteJobs).get(), isEmpty);
        expect(
          await fixture.collectorRepo.latestDeliveredWriterBoundary('session'),
          0,
        );
        expect(
          (await fixture.collectorRepo.readSession(
            'session',
          )).where((row) => row.status == 'completed'),
          hasLength(5),
        );
        service.dispose();
      },
    );
  }

  test(
    'incompatible journal discovery is read-only, never a session-wide reset',
    () async {
      for (var ordinal = 1; ordinal <= 3; ordinal++) {
        await fixture.seedReconciliationRun(ordinal: ordinal);
      }
      final service = fixture.service(
        (_, _) async => _ok(fixture.observationNewOutput),
      );
      await service.runAfterReconciliation(
        (await LedgerReconciliationRunRepo(
          fixture.db,
        ).readSession('session')).last,
      );
      final before = await fixture.collectorRepo.readSession('session');
      final observations = await fixture.observationRepo.getActiveObservations(
        'session',
      );
      expect(observations, isNotEmpty);
      await fixture.db.customStatement(
        "UPDATE card_evolution_collector_runs SET range_hash = 'incompatible' WHERE session_id = 'session'",
      );
      await expectLater(
        fixture.collectorRepo.pendingValidPairs('session'),
        throwsStateError,
      );
      expect(
        (await fixture.collectorRepo.readSession(
          'session',
        )).map((row) => row.id),
        before.map((row) => row.id),
      );
      expect(
        (await fixture.observationRepo.getActiveObservations(
          'session',
        )).map((row) => row.id),
        observations.map((row) => row.id),
      );
      service.dispose();
    },
  );

  test('manual Collector recovery processes an unclaimed batch once', () async {
    await fixture.seedReconciliationRun(ordinal: 1);
    await fixture.seedReconciliationRun(ordinal: 2);
    await fixture.seedReconciliationRun(ordinal: 3);
    var collectorCalls = 0;
    final service = fixture.service((_, prompt) async {
      if (prompt.contains('observation journal keeper')) {
        collectorCalls++;
        return _ok('{"observations":[]}');
      }
      return _ok('{"operations":[]}');
    });

    final first = await service.runPendingCollectors('session');
    final second = await service.runPendingCollectors('session');

    expect(first.kind, 'collectorCompleted');
    expect(second.kind, 'collectorUpToDate');
    expect(collectorCalls, 1);
    final collectors = await fixture.db
        .select(fixture.db.cardEvolutionCollectorRuns)
        .get();
    expect(collectors, hasLength(1));
    expect(collectors.single.status, 'completed');
  });

  test(
    'historical delivered boundary waits for five new collectors across restart',
    () async {
      final historical = await fixture.seedHistoricalWriterClaim();
      expect(
        await fixture.repo.completeEmptyClaim(
          claimId: historical.row.id,
          ownerId: 'historical-owner',
          now: 11,
        ),
        isTrue,
      );
      var writerCalls = 0;
      Future<AuxCallOutcome> execute(CancelToken? _, String prompt) async {
        if (prompt.contains('observation journal keeper')) {
          return _ok('{"observations":[]}');
        }
        writerCalls++;
        return _ok('{"operations":[]}');
      }

      var service = fixture.service(execute);
      for (var ordinal = 7; ordinal <= 21; ordinal++) {
        if (ordinal == 13) {
          service.dispose();
          service = fixture.service(execute);
        }
        final outcome = await service.runAfterReconciliation(
          await fixture.seedReconciliationRun(ordinal: ordinal),
        );
        expect(
          outcome.kind,
          ordinal < 21 ? 'collectorCompleted' : 'emptyModelProposal',
        );
        expect(writerCalls, ordinal < 21 ? 0 : 1);
      }
      final claims = await fixture.db
          .select(fixture.db.cardEvolutionClaims)
          .get();
      expect(claims.map((claim) => claim.predecessorRunOrdinal), [2, 7]);
      expect(claims.first.selectedInputJson, historical.selectedInputJson);
      final input = jsonDecode(claims.last.selectedInputJson!) as Map;
      expect((input['limits'] as Map)['reconciliationRunIds'], [
        for (var ordinal = 7; ordinal <= 21; ordinal++) 'run-$ordinal',
      ]);
      expect(
        await fixture.collectorRepo.latestDeliveredWriterBoundary('session'),
        7,
      );
      service.dispose();
      final restarted = fixture.service(execute);
      expect(
        (await restarted.runPendingCollectors('session')).kind,
        'collectorUpToDate',
      );
      expect(writerCalls, 1);
      expect(await fixture.collectorRepo.readSession('session'), hasLength(7));
      restarted.dispose();
    },
  );

  test(
    'historical two-collector failed claim recovers exact input after restart',
    () async {
      final historical = await fixture.seedHistoricalWriterClaim();
      expect(
        await fixture.repo.markWriterFailed(
          claimId: historical.row.id,
          ownerId: 'historical-owner',
          now: 11,
          code: 'cardWriterFailed',
        ),
        isTrue,
      );
      final collectorService = fixture.service(
        (_, _) async => _ok('{"observations":[]}'),
      );
      for (var ordinal = 7; ordinal <= 9; ordinal++) {
        await collectorService.runAfterReconciliation(
          await fixture.seedReconciliationRun(ordinal: ordinal),
        );
      }
      collectorService.dispose();

      // The new automatic lane must not discard an old reproducible claim.
      final blocked = await fixture.repo.claim(
        sessionId: 'session',
        ownerId: 'new-automatic-owner',
        now: 12,
        leaseSeconds: 60,
      );
      expect(blocked.kind, 'failed', reason: blocked.detail);
      expect(blocked.claim?.selectedInputJson, historical.selectedInputJson);
      var writerCalls = 0;
      final restarted = fixture.service((_, _) async {
        writerCalls++;
        return _ok(fixture.cardBatchOutput);
      });
      final outcome = await restarted.resumeFailedWriter(historical.row.id);
      expect(outcome.kind, 'persisted', reason: outcome.detail);
      expect(writerCalls, 1);
      final recovered = (await fixture.repo.getClaimById(historical.row.id))!;
      expect(recovered.selectedInputJson, historical.selectedInputJson);
      expect(recovered.inputHash, historical.row.inputHash);
      expect(recovered.predecessorRunOrdinal, 2);
      final proposal = await fixture.db
          .select(fixture.db.cardEvolutionProposalRuns)
          .getSingle();
      expect(proposal.selectedInputJson, historical.selectedInputJson);
      final session = await fixture.db
          .select(fixture.db.chatSessions)
          .getSingle();
      expect(
        CardEvolutionSelectedChatEvidence.tryParse(
          proposal.selectedInputJson,
        )!.validatesProposal(
          proposal,
          jobId: outcome.job!.id,
          sessionId: 'session',
          characterId: 'character',
          messagesJson: session.messagesJson,
        ),
        isTrue,
      );
      restarted.dispose();
    },
  );

  for (final mutation in [
    "DELETE FROM card_evolution_collector_runs WHERE collector_ordinal = 1",
    "UPDATE card_evolution_collector_runs SET range_hash = 'changed' WHERE collector_ordinal = 1",
    "UPDATE card_evolution_collector_runs SET reconciliation_chain_hash = 'changed' WHERE collector_ordinal = 2",
  ]) {
    test(
      'historical cadence still rejects unresolved evidence: $mutation',
      () async {
        final historical = await fixture.seedHistoricalWriterClaim();
        await fixture.db.customStatement(mutation);
        final snapshot = await fixture.repo.readPromptSnapshotOutcome(
          claimId: historical.row.id,
          ownerId: 'historical-owner',
          now: 11,
        );
        expect(snapshot.snapshot, isNull);
        expect(snapshot.reason, 'collectorRunsUnresolved');
        expect(
          (await fixture.repo.getClaimById(
            historical.row.id,
          ))!.selectedInputJson,
          historical.selectedInputJson,
        );
      },
    );
  }

  test('saved automatic run IDs must match the exact ordered batch', () async {
    final historical = await fixture.seedHistoricalWriterClaim();
    final input = jsonDecode(historical.selectedInputJson) as Map;
    final limits = input['limits'] as Map;
    final ids = limits['reconciliationRunIds'] as List;
    limits['reconciliationRunIds'] = ids.reversed.toList();
    final changed = jsonEncode(input);
    await fixture.db.customStatement(
      'UPDATE card_evolution_claims SET selected_input_json = ?, input_hash = ? '
      'WHERE id = ?',
      [changed, computeHash(changed), historical.row.id],
    );
    final snapshot = await fixture.repo.readPromptSnapshotOutcome(
      claimId: historical.row.id,
      ownerId: 'historical-owner',
      now: 11,
    );
    expect(snapshot.snapshot, isNull);
    expect(snapshot.reason, 'collectorRunsUnresolved');
  });

  test('Collector uses the Studio Ledger API and response budget', () async {
    await fixture.seedReconciliationRun(ordinal: 1);
    await fixture.seedReconciliationRun(ordinal: 2);
    await fixture.seedReconciliationRun(ordinal: 3);
    AuxApiConfig? receivedConfig;
    int? receivedMaxTokens;
    final service = fixture.service(
      (_, _) async => _ok('{"observations":[]}'),
      onRequest: (config, maxTokens) {
        receivedConfig = config;
        receivedMaxTokens = maxTokens;
      },
    );

    final result = await service.runPendingCollectors('session');

    expect(result.kind, 'collectorCompleted');
    expect(receivedConfig?.endpoint, 'https://ledger.example');
    expect(receivedConfig?.model, 'ledger-model');
    expect(receivedMaxTokens, 6789);
  });

  test(
    'unexpected automatic lane failure leaves durable diagnostics',
    () async {
      final service = fixture.service((_, prompt) async {
        return _ok('{"observations":[]}');
      });
      for (var ordinal = 1; ordinal <= 5; ordinal++) {
        await service.runAfterReconciliation(
          await fixture.seedReconciliationRun(ordinal: ordinal),
        );
      }
      await fixture.db.customStatement(
        'DROP TABLE card_evolution_collector_runs',
      );

      final result = await service.runAfterReconciliation(
        await fixture.seedReconciliationRun(ordinal: 6),
      );

      expect(result.kind, 'unexpectedFailure');
      expect(result.detail, contains('card_evolution_collector_runs'));
      final debug = await fixture.db
          .select(fixture.db.cardEvolutionDebugRuns)
          .getSingle();
      expect(debug.stage, 'selection');
      expect(debug.status, 'unexpectedFailure');
      expect(debug.attemptsJson, contains('card_evolution_collector_runs'));
    },
  );

  test(
    'oversized writer streams all immutable history into one handoff',
    () async {
      final messages = List<Map<String, String>>.generate(41, (index) {
        return {
          'id': 'long-$index',
          'role': index.isEven ? 'assistant' : 'user',
          'content':
              '${index.isEven ? 'assistant' : 'user'}-$index ${'x' * 10300}',
        };
      });
      final starts = [0, 1, 21, 21];
      final prompts = <String>[];
      final contexts = <LlmCaptureContext>[];
      final service = fixture.service((_, prompt) async {
        prompts.add(prompt);
        if (prompt.contains('observation journal keeper')) {
          return _ok('{"observations":[]}');
        }
        if (prompt.contains('compact cumulative factual handoff')) {
          return _ok('complete history factual handoff');
        }
        return _ok('{"operations":[]}');
      }, onCaptureContext: contexts.add);
      CardEvolutionFinalizeOutcome? outcome;
      for (var ordinal = 1; ordinal <= 6; ordinal++) {
        outcome = await service.runAfterReconciliation(
          await fixture.seedReconciliationRun(
            ordinal: ordinal,
            messages: messages.sublist(
              starts[(ordinal - 1) * 3 ~/ 5],
              starts[(ordinal - 1) * 3 ~/ 5] + 20,
            ),
          ),
        );
      }
      await fixture.db.customStatement(
        'UPDATE chat_sessions SET messages_json = ? WHERE session_id = ?',
        [jsonEncode(messages), 'session'],
      );
      outcome = await service.runOneBatch('session');

      expect(outcome.kind, 'emptyModelProposal', reason: outcome.detail);
      expect(
        prompts.any(
          (prompt) => prompt.contains('compact cumulative factual handoff'),
        ),
        isTrue,
        reason: 'Expected oversized split; prompts=${prompts.length}',
      );
      final consolidations = prompts
          .where(
            (prompt) => prompt.contains('compact cumulative factual handoff'),
          )
          .toList();
      final writer = prompts.singleWhere(
        (prompt) => prompt.contains('Astoria card rewriter'),
      );
      expect(consolidations.first, contains('long-0'));
      expect(consolidations.last, contains('long-38'));
      expect(writer, contains('complete history factual handoff'));
      expect(writer, isNot(contains('long-0')));
      expect(writer, isNot(contains('long-38')));
      final consolidationContexts = contexts
          .where((context) => context.stage == 'card.history_consolidation')
          .toList();
      expect(consolidationContexts, hasLength(consolidations.length));
      expect(
        consolidationContexts.map((context) => context.stageOrdinal),
        List<int>.generate(consolidations.length, (index) => index + 1),
      );
      expect(
        consolidationContexts.map((context) => context.pipelineRunId).toSet(),
        hasLength(1),
      );
    },
  );

  test('one oversized history message fails with an explicit size', () async {
    final messages = [
      {'id': 'a0', 'role': 'assistant', 'content': 'opening'},
      {'id': 'u1', 'role': 'user', 'content': 'x' * 601000},
      {'id': 'a1', 'role': 'assistant', 'content': 'accepted'},
    ];
    final service = fixture.service((_, prompt) async {
      if (prompt.contains('observation journal keeper')) {
        return _ok('{"observations":[]}');
      }
      return _ok('{"operations":[]}');
    });
    CardEvolutionFinalizeOutcome? outcome;
    for (var ordinal = 1; ordinal <= 15; ordinal++) {
      outcome = await service.runAfterReconciliation(
        await fixture.seedReconciliationRun(
          ordinal: ordinal,
          messages: messages,
        ),
      );
    }

    expect(outcome?.kind, 'snapshotTooLarge');
    expect(outcome?.detail, contains('history message 2'));
    expect(outcome?.detail, contains('600000'));
  });

  test(
    'first high logical reconciliation batch becomes collector one',
    () async {
      await fixture.seedReconciliationRun(ordinal: 39);
      await fixture.seedReconciliationRun(ordinal: 40);
      final run = await fixture.seedReconciliationRun(ordinal: 41);
      final result = await fixture
          .service((_, prompt) async => _ok('{"observations":[]}'))
          .runAfterReconciliation(run);
      expect(result.kind, 'collectorCompleted');
      final collector = await fixture.db
          .select(fixture.db.cardEvolutionCollectorRuns)
          .getSingle();
      expect(collector.collectorOrdinal, 1);
      expect(collector.reconciliationRunOrdinal, 3);
    },
  );

  test('overdue writer uses exact completed collector boundary hash', () async {
    var writerCalls = 0;
    final service = fixture.service((_, prompt) async {
      if (prompt.contains('observation journal keeper')) {
        return _ok('{"observations":[]}');
      }
      writerCalls++;
      return _ok(writerCalls == 1 ? 'invalid' : '{"operations":[]}');
    });
    for (var ordinal = 10; ordinal <= 300; ordinal += 10) {
      await service.runAfterReconciliation(
        await fixture.seedReconciliationRun(ordinal: ordinal),
      );
    }
    expect(writerCalls, 3);
    final claim = await (fixture.db.select(
      fixture.db.cardEvolutionClaims,
    )..where((row) => row.predecessorRunOrdinal.equals(10))).getSingle();
    expect(claim.predecessorRunOrdinal, 10);
    final boundary = await (fixture.db.select(
      fixture.db.cardEvolutionCollectorRuns,
    )..where((row) => row.collectorOrdinal.equals(10))).getSingle();
    expect(claim.predecessorCursorHash, boundary.reconciliationChainHash);
  });

  test('minimal no_evidence response is accepted', () async {
    await fixture.seedReconciliationRun(ordinal: 1);
    await fixture.seedReconciliationRun(ordinal: 2);
    await fixture.seedReconciliationRun(ordinal: 3);
    await fixture.observationRepo.insertObservation(
      CardEvolutionObservation(
        id: 'minimal-no-evidence',
        sessionId: 'session',
        characterId: 'character',
        runOrdinal: 1,
        semanticScopeKey: 'character.preference.trust',
        observedChange: 'Tracked',
        evidenceClusters: const [
          ['a1'],
        ],
        retrievalKeys: const ['npc:Алиса'],
        targetKind: 'main_character_card',
        confidence: 0.5,
        status: 'active',
        firstSeenRun: 1,
        createdAt: 10,
        updatedAt: 10,
      ),
    );
    await fixture
        .service(
          (_, prompt) async => prompt.contains('observation journal keeper')
              ? _ok(
                  '{"observations":[{"action":"no_evidence","scopeKey":"character.preference.trust"}]}',
                )
              : _ok(fixture.cardBatchOutput),
        )
        .runOneBatch('session');
    expect(
      (await fixture.observationRepo.findById(
        'minimal-no-evidence',
      ))!.updatedAt,
      10,
    );
  });

  test('tracker fields normalize to one stable NPC group target', () async {
    await fixture.seedReconciliationRun(ordinal: 1);
    await fixture.seedReconciliationRun(
      ordinal: 2,
      opKeys: const ['npc:Квинн.location', 'npc:Квинн.current_goal'],
    );
    final run = await fixture.seedReconciliationRun(
      ordinal: 3,
      opKeys: const ['npc:Квинн.location', 'npc:Квинн.current_goal'],
    );
    String? collectorPrompt;
    await fixture
        .service((_, prompt) async {
          collectorPrompt = prompt;
          return _ok('{"observations":[]}');
        })
        .runAfterReconciliation(run);
    expect(collectorPrompt, contains('"key":"npc:Квинн"'));
    expect(collectorPrompt, isNot(contains('npc:Квинн.location')));
    expect(collectorPrompt, isNot(contains('npc:Квинн.current_goal')));
  });

  test(
    'dormant NPC observation returns only on exact current mention',
    () async {
      Future<String> promptFor(
        List<Map<String, String>> messages,
        int ordinal,
      ) async {
        await fixture.observationRepo.insertObservation(
          CardEvolutionObservation(
            id: 'quinn-$ordinal',
            sessionId: 'session',
            characterId: 'character',
            runOrdinal: 1,
            semanticScopeKey: 'npc:Квинн',
            observedChange: 'Квинн remembers the old promise',
            evidenceClusters: const [
              ['ancient-message'],
            ],
            retrievalKeys: const ['npc:Квинн'],
            targetKind: 'main_character_card',
            confidence: 0.8,
            status: 'active',
            firstSeenRun: 1,
            createdAt: 1,
            updatedAt: 1,
          ),
        );
        await fixture.seedReconciliationRun(
          ordinal: ordinal - 2,
          messages: messages,
          opKeys: const ['world:location'],
        );
        await fixture.seedReconciliationRun(
          ordinal: ordinal - 1,
          messages: messages,
          opKeys: const ['world:location'],
        );
        final run = await fixture.seedReconciliationRun(
          ordinal: ordinal,
          messages: messages,
          opKeys: const ['world:location'],
        );
        var prompt = '';
        await fixture
            .service((_, value) async {
              prompt = value;
              return _ok('{"observations":[]}');
            })
            .runAfterReconciliation(run);
        return prompt;
      }

      final unrelated = await promptFor(_messages, 1000);
      expect(unrelated, isNot(contains('Квинн remembers the old promise')));
      await (fixture.db.delete(
        fixture.db.cardEvolutionObservations,
      )..where((row) => row.id.equals('quinn-1000'))).go();
      await fixture.db.transaction(
        () => LedgerReconciliationRunRepo(fixture.db)
            .invalidateForMessageMutation(
              sessionId: 'session',
              messageIds: const {'a1'},
              reason: 'test_evidence_change',
              createdAt: 1001,
            ),
      );
      const returned = [
        {'id': 'a1', 'role': 'assistant', 'content': 'Квинн вошла в комнату.'},
        {'id': 'u1', 'role': 'user', 'content': 'Я приветствую Квинн.'},
        {'id': 'a2', 'role': 'assistant', 'content': 'assistant 2'},
        {'id': 'u2', 'role': 'user', 'content': 'user 2'},
      ];
      final related = await promptFor(returned, 1003);
      expect(related, contains('Квинн remembers the old promise'));
    },
  );

  test(
    'NPC mention fallback is token safe and arc groups retrieve directly',
    () async {
      await fixture.observationRepo.insertObservation(
        CardEvolutionObservation(
          id: 'quinn-token',
          sessionId: 'session',
          characterId: 'character',
          runOrdinal: 1,
          semanticScopeKey: 'npc:Квинн',
          observedChange: 'No substring match',
          evidenceClusters: const [
            ['old'],
          ],
          retrievalKeys: const ['npc:Квинн'],
          targetKind: 'main_character_card',
          confidence: 0.8,
          status: 'active',
          firstSeenRun: 1,
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      await fixture.observationRepo.insertObservation(
        CardEvolutionObservation(
          id: 'arc-sponsor',
          sessionId: 'session',
          characterId: 'character',
          runOrdinal: 1,
          semanticScopeKey: 'arc:Спонсорство',
          observedChange: 'Arc remains relevant',
          evidenceClusters: const [
            ['old'],
          ],
          retrievalKeys: const ['arc:Спонсорство'],
          targetKind: 'main_character_card',
          confidence: 0.8,
          status: 'active',
          firstSeenRun: 1,
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      const messages = [
        {'id': 'a1', 'role': 'assistant', 'content': 'Квинни здесь.'},
        {'id': 'u1', 'role': 'user', 'content': 'Продолжим.'},
        {'id': 'a2', 'role': 'assistant', 'content': 'assistant 2'},
        {'id': 'u2', 'role': 'user', 'content': 'user 2'},
      ];
      await fixture.seedReconciliationRun(
        ordinal: 1,
        messages: messages,
        opKeys: const ['arc:Спонсорство.status'],
      );
      await fixture.seedReconciliationRun(
        ordinal: 2,
        messages: messages,
        opKeys: const ['arc:Спонсорство.status'],
      );
      final run = await fixture.seedReconciliationRun(
        ordinal: 3,
        messages: messages,
        opKeys: const ['arc:Спонсорство.status'],
      );
      var prompt = '';
      await fixture
          .service((_, value) async {
            prompt = value;
            return _ok('{"observations":[]}');
          })
          .runAfterReconciliation(run);
      expect(prompt, contains('Arc remains relevant'));
      expect(prompt, isNot(contains('No substring match')));
    },
  );

  test('observation older than 200 rows is still retrieved', () async {
    await fixture.observationRepo.insertObservation(
      CardEvolutionObservation(
        id: 'old-quinn',
        sessionId: 'session',
        characterId: 'character',
        runOrdinal: 1,
        semanticScopeKey: 'npc:Квинн',
        observedChange: 'Old durable Quinn observation',
        evidenceClusters: const [
          ['ancient'],
        ],
        retrievalKeys: const ['npc:Квинн'],
        targetKind: 'main_character_card',
        confidence: 0.9,
        status: 'active',
        firstSeenRun: 1,
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    for (var index = 0; index < 220; index++) {
      await fixture.observationRepo.insertObservation(
        CardEvolutionObservation(
          id: 'new-$index',
          sessionId: 'session',
          characterId: 'character',
          runOrdinal: 1,
          semanticScopeKey: 'arc:other-$index',
          observedChange: 'unrelated $index',
          evidenceClusters: const [
            ['new'],
          ],
          retrievalKeys: ['arc:other-$index'],
          targetKind: 'main_character_card',
          confidence: 0.5,
          status: 'active',
          firstSeenRun: 1,
          createdAt: index + 2,
          updatedAt: index + 2,
        ),
      );
    }
    const messages = [
      {'id': 'a1', 'role': 'assistant', 'content': 'Квинн вернулась.'},
      {'id': 'u1', 'role': 'user', 'content': 'Привет, Квинн.'},
      {'id': 'a2', 'role': 'assistant', 'content': 'assistant 2'},
      {'id': 'u2', 'role': 'user', 'content': 'user 2'},
    ];
    await fixture.seedReconciliationRun(
      ordinal: 1,
      messages: messages,
      opKeys: const ['world:location'],
    );
    await fixture.seedReconciliationRun(
      ordinal: 2,
      messages: messages,
      opKeys: const ['world:location'],
    );
    final run = await fixture.seedReconciliationRun(
      ordinal: 3,
      messages: messages,
      opKeys: const ['world:location'],
    );
    var prompt = '';
    await fixture
        .service((_, value) async {
          prompt = value;
          return _ok('{"observations":[]}');
        })
        .runAfterReconciliation(run);
    expect(prompt, contains('Old durable Quinn observation'));
  });

  test('cadence waits for the next complete collector batch', () async {
    final service = fixture.service(
      (_, prompt) async => prompt.contains('observation journal keeper')
          ? _ok('{"observations":[]}')
          : _ok('{"operations":[]}'),
    );
    for (var ordinal = 1; ordinal <= 15; ordinal++) {
      final result = await service.runAfterReconciliation(
        await fixture.seedReconciliationRun(ordinal: ordinal),
      );
      expect(
        result.kind,
        ordinal < 15 ? 'collectorCompleted' : 'emptyModelProposal',
      );
    }
    await service.runAfterReconciliation(
      await fixture.seedReconciliationRun(ordinal: 16),
    );
    final result = await service.runAfterReconciliation(
      await fixture.seedReconciliationRun(ordinal: 17),
    );
    expect(result.kind, 'collectorCompleted');
    final completed = await service.runAfterReconciliation(
      await fixture.seedReconciliationRun(ordinal: 18),
    );
    expect(completed.kind, 'collectorCompleted');
    final claims = await fixture.db
        .select(fixture.db.cardEvolutionClaims)
        .get();
    expect(claims, hasLength(1));
    expect(claims.single.predecessorRunOrdinal, 5);
  });

  test('primary current groups survive retrieval target extras cap', () async {
    await fixture.seedReconciliationRun(ordinal: 1);
    await fixture.seedReconciliationRun(ordinal: 2);
    final run = await fixture.seedReconciliationRun(
      ordinal: 3,
      opKeys: [
        for (var index = 0; index < 85; index++) 'arc:Текущий$index.status',
      ],
    );
    var prompt = '';
    await fixture
        .service((_, value) async {
          prompt = value;
          return _ok('{"observations":[]}');
        })
        .runAfterReconciliation(run);
    expect(prompt, contains('"key":"arc:Текущий0"'));
    expect(prompt, contains('"key":"arc:Текущий84"'));
  });

  test('snapshot bounds oversized tracker values deterministically', () async {
    await fixture.db.customStatement(
      'UPDATE tracker_rows SET value = ? WHERE session_id = ?',
      ['Ж' * 50000, 'session'],
    );
    await fixture.seedReconciliationRun(ordinal: 1);
    await fixture.seedReconciliationRun(ordinal: 2);
    final run = await fixture.seedReconciliationRun(ordinal: 3);
    var prompt = '';
    await fixture
        .service((_, value) async {
          prompt = value;
          return _ok('{"observations":[]}');
        })
        .runAfterReconciliation(run);
    expect(prompt.length, lessThan(150000));
    expect(RegExp('Ж{2001}').hasMatch(prompt), isFalse);
  });

  test(
    'exact retry refuses obsolete captured evidence before claim or model call',
    () async {
      final first = await fixture.seedReconciliationRun(ordinal: 1);
      final middle = await fixture.seedReconciliationRun(ordinal: 2);
      final boundary = await fixture.seedReconciliationRun(ordinal: 3);
      final failed = await fixture.seedFailedCollector(
        first: first,
        middle: middle,
        boundary: boundary,
        prompt:
            '<lumiaooc>OOC_FORECAST_ALL_NPCS_IN_LOVE</lumiaooc> old collector rules',
      );
      String? receivedPrompt;
      final result = await fixture
          .service((_, prompt) async {
            receivedPrompt = prompt;
            return AuxCallOutcome(
              status: AgentOperationStatus.ok,
              text: fixture.observationNewOutput,
              captureContext: LlmCaptureContext(
                stage: 'card.collector',
                sessionId: 'session',
                pipelineRunId: failed.id,
                callId: 'retry-call',
                attempt: 1,
              ),
            );
          })
          .retryFailedCollector(failed.id);

      expect(result.kind, 'collectorPromptChanged');
      expect(receivedPrompt, isNull);
      final retained = await fixture.collectorRepo.getById(failed.id);
      expect(retained, failed);
      expect(
        (await fixture.captureRepo.exactPromptForCall(
          callId: 'failed-call',
          sessionId: 'session',
          pipelineRunId: failed.id,
          stage: 'card.collector',
        ))?.prompt,
        contains('OOC_FORECAST_ALL_NPCS_IN_LOVE'),
      );
      expect(
        await fixture.observationRepo.getActiveObservations('session'),
        isEmpty,
      );
    },
  );

  test('retry rebuilds prompt when exact capture is unavailable', () async {
    final first = await fixture.seedReconciliationRun(ordinal: 1);
    final middle = await fixture.seedReconciliationRun(ordinal: 2);
    final boundary = await fixture.seedReconciliationRun(ordinal: 3);
    final failed = await fixture.seedFailedCollector(
      first: first,
      middle: middle,
      boundary: boundary,
      prompt: 'discarded collector prompt',
    );
    await fixture.db.delete(fixture.db.llmRequestCaptureRows).go();
    String? receivedPrompt;

    final result = await fixture
        .service((_, prompt) async {
          receivedPrompt = prompt;
          return AuxCallOutcome(
            status: AgentOperationStatus.ok,
            text: fixture.observationNewOutput,
            captureContext: LlmCaptureContext(
              stage: 'card.collector',
              sessionId: 'session',
              pipelineRunId: failed.id,
              callId: 'rebuilt-retry-call',
              attempt: 1,
            ),
          );
        })
        .retryFailedCollector(failed.id);

    expect(result.kind, 'collectorCompleted');
    expect(
      receivedPrompt,
      contains('# Immutable chat history and effective canon'),
    );
    expect(receivedPrompt, isNot('discarded collector prompt'));
    final completed = await fixture.collectorRepo.getById(failed.id);
    expect(completed?.status, 'completed');
    expect(completed?.collectorOrdinal, failed.collectorOrdinal);
    expect(completed?.lastCallId, 'rebuilt-retry-call');
  });

  test(
    'manual correction completes failed collector without model call',
    () async {
      final first = await fixture.seedReconciliationRun(ordinal: 1);
      final middle = await fixture.seedReconciliationRun(ordinal: 2);
      final boundary = await fixture.seedReconciliationRun(ordinal: 3);
      final failed = await fixture.seedFailedCollector(
        first: first,
        middle: middle,
        boundary: boundary,
        prompt: 'unused prompt',
      );
      var calls = 0;
      final result = await fixture
          .service((_, _) async {
            calls++;
            return _ok('{}');
          })
          .correctFailedCollector(
            failed.id,
            response: fixture.observationNewOutput,
          );

      expect(result.kind, 'collectorCompleted');
      expect(calls, 0);
      expect(
        (await fixture.collectorRepo.getById(failed.id))?.status,
        'completed',
      );
      expect(
        await fixture.observationRepo.getActiveObservations('session'),
        hasLength(1),
      );
    },
  );

  test(
    'invalid manual correction preserves the immutable capture for review',
    () async {
      final first = await fixture.seedReconciliationRun(ordinal: 1);
      final middle = await fixture.seedReconciliationRun(ordinal: 2);
      final boundary = await fixture.seedReconciliationRun(ordinal: 3);
      final failed = await fixture.seedFailedCollector(
        first: first,
        middle: middle,
        boundary: boundary,
        prompt: 'captured collector prompt',
      );

      LlmCallEventCapture.sink = fixture.captureRepo;
      addTearDown(() {
        if (identical(LlmCallEventCapture.sink, fixture.captureRepo)) {
          LlmCallEventCapture.sink = null;
        }
      });
      final result = await fixture
          .service((_, _) async => _ok('{}'))
          .correctFailedCollector(failed.id, response: 'not json');

      expect(result.kind, 'parserRejected');
      final retained = await fixture.collectorRepo.getById(failed.id);
      expect(retained?.status, 'failed');
      expect(retained?.lastCallId, 'failed-call');
      expect(
        (await fixture.captureRepo.exactPromptForCall(
          callId: 'failed-call',
          sessionId: 'session',
          pipelineRunId: failed.id,
          stage: 'card.collector',
        ))?.prompt,
        'captured collector prompt',
      );
      final events = await fixture.captureRepo.callEventsForArtifact(
        'session',
        failed.id,
      );
      expect(events.single.kind, 'parser_rejected');
      expect(events.single.responseText, 'not json');
      expect(jsonDecode(events.single.payloadJson), {
        'source': 'manual_correction',
      });
    },
  );
}

AuxCallOutcome _ok(String text) =>
    AuxCallOutcome(status: AgentOperationStatus.ok, text: text);

final class _Fixture {
  _Fixture(
    this.db,
    this.repo,
    this.observationRepo,
    this.collectorRepo,
    this.captureRepo,
  );

  final AppDatabase db;
  final CardEvolutionRepo repo;
  final CardEvolutionObservationRepo observationRepo;
  final CardEvolutionCollectorRunRepo collectorRepo;
  final LlmRequestCaptureRepo captureRepo;

  static Future<_Fixture> create() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final characters = CharacterRepo(db);
    final revisions = CharacterRevisionRepo(db);
    const character = Character(
      id: 'character',
      name: 'Card',
      description: 'Alice is cautious.',
    );
    await characters.put(character);
    final hash = CardCanonicalizer.sha256(character);
    await revisions.insert(
      CharacterRevisionRecord(
        characterId: 'character',
        revision: 1,
        revisionHash: hash,
        parentRevisionHash: '',
        snapshotJson: jsonEncode(character.toJson()),
        createdAt: 1,
      ),
    );
    await db.customStatement(
      'INSERT INTO chat_sessions (session_id, character_id, session_index, messages_json) VALUES (?, ?, 0, ?)',
      ['session', 'character', jsonEncode(_messages)],
    );
    await db.customStatement(
      "INSERT INTO tracker_rows (session_id, name, value, scope) VALUES (?, ?, ?, 'ledger')",
      ['session', 'npc:Алиса.доверие', 'растёт'],
    );
    // Current selection is snapshot/effect-first. A live row by itself is not
    // historical canon evidence; seed the actual committed fixture boundary.
    await TrackerSnapshotRepo(db).upsert(
      const TrackerSnapshot(
        sessionId: 'session',
        messageId: 'a1',
        swipeId: 0,
        agentSwipeId: 0,
        committed: true,
        createdAt: 1,
        trackers: [
          Tracker(
            sessionId: 'session',
            name: 'npc:Алиса.доверие',
            value: 'растёт',
            scope: 'ledger',
          ),
        ],
      ),
    );
    final reader = EffectiveCanonReadRepository(
      db: db,
      characterRepo: characters,
      revisionRepo: revisions,
      baselineRepo: CharacterSessionBaselineRepo(db),
      factRepo: CharacterKnowledgeFactRepo(db),
      transitionRepo: AppliedCanonTransitionRepo(db),
      transitionFactRefRepo: CanonTransitionFactRefRepo(db),
    );
    final jobs = ManualRewriteJobRepo(
      db: db,
      rawTrackerStateReader: LedgerRawTrackerStateReader(db),
    );
    final repo = CardEvolutionRepo(db: db, canonReader: reader, jobRepo: jobs);
    final observationRepo = CardEvolutionObservationRepo(db);
    return _Fixture(
      db,
      repo,
      observationRepo,
      CardEvolutionCollectorRunRepo(db),
      LlmRequestCaptureRepo(db),
    );
  }

  Future<CardEvolutionCollectorRunRow> seedFailedCollector({
    required LedgerReconciliationSuccessfulRunRow first,
    required LedgerReconciliationSuccessfulRunRow middle,
    required LedgerReconciliationSuccessfulRunRow boundary,
    required String prompt,
  }) async {
    final snapshot = await repo.buildObservationSnapshotForRuns([
      first,
      middle,
      boundary,
    ]);
    final batch = CardEvolutionCollectorBatch([first, middle, boundary]);
    final claim = await collectorRepo.claim(
      reconciliationRun: boundary,
      characterId: 'character',
      inputHash: computeHash(snapshot!.selectedInputJson),
      ownerId: 'failed-owner',
      now: 10,
      leaseSeconds: 60,
      rangeHash: batch.rangeHash,
    );
    final row = claim.row!;
    await captureRepo.record(
      LlmRequestCapture.build(
        ChatTransportRequest(
          endpoint: 'https://rewrite.example',
          apiKey: 'secret',
          model: 'model',
          messages: [
            {'role': 'user', 'content': prompt},
          ],
          maxTokens: 40000,
          temperature: 0.2,
          topP: 1,
          captureContext: LlmCaptureContext(
            stage: 'card.collector',
            sessionId: 'session',
            pipelineRunId: row.id,
            callId: 'failed-call',
            relatedArtifactId: row.id,
            attempt: 1,
          ),
        ),
      ),
    );
    expect(
      await collectorRepo.markFailed(
        id: row.id,
        ownerId: 'failed-owner',
        now: 20,
        code: 'parserRejected',
        callId: 'failed-call',
      ),
      isTrue,
    );
    return (await collectorRepo.getById(row.id))!;
  }

  Future<CardEvolutionClaim> seedHistoricalWriterClaim() async {
    final collectorService = service(
      (_, _) async => _ok('{"observations":[]}'),
    );
    for (var ordinal = 1; ordinal <= 6; ordinal++) {
      await collectorService.runAfterReconciliation(
        await seedReconciliationRun(ordinal: ordinal),
      );
    }
    collectorService.dispose();
    final collectors = await collectorRepo.completedBoundary(
      'session',
      2,
      count: 2,
    );
    final runs = await collectorRepo.runsForCollectors('session', collectors);
    final claimed = await repo.claim(
      sessionId: 'session',
      ownerId: 'historical-owner',
      now: 10,
      leaseSeconds: 60,
      throughCollectorOrdinal: 2,
      collectorBoundaryHash: collectors.last.reconciliationChainHash,
      reconciliationRunIds: [for (final run in runs) run.id],
      writerOptionsJson: '{"lorebookEnabled":false}',
    );
    expect(claimed.kind, 'claimed', reason: claimed.detail);
    expect(
      (await repo.readPromptSnapshotOutcome(
        claimId: claimed.claim!.row.id,
        ownerId: 'historical-owner',
        now: 10,
      )).snapshot,
      isNotNull,
    );
    return claimed.claim!;
  }

  Future<LedgerReconciliationSuccessfulRunRow> seedReconciliationRun({
    required int ordinal,
    List<Map<String, String>> messages = _messages,
    List<String> opKeys = const ['npc:Алиса.доверие'],
    List<String> presentEntities = const [],
  }) async {
    await db.customStatement(
      'UPDATE chat_sessions SET messages_json = ? WHERE session_id = ?',
      [jsonEncode(messages), 'session'],
    );
    final anchors = <ReconciliationAnchor>[
      for (final message in messages)
        ReconciliationAnchor(
          agentSwipeId: 0,
          contentHash: computeHash(message['content']!),
          messageId: message['id']!,
          role: message['role']!,
          swipeId: 0,
        ),
    ];
    final existing =
        await (db.select(db.ledgerReconciliationSuccessfulRuns)
              ..where((row) => row.sessionId.equals('session'))
              ..orderBy([(row) => OrderingTerm.desc(row.ordinal)])
              ..limit(1))
            .getSingleOrNull();
    final run = LedgerReconciliationRun(
      id: 'run-$ordinal',
      sessionId: 'session',
      ordinal: (existing?.ordinal ?? 0) + 1,
      anchors: anchors,
      acceptedManifestRefs: const [],
      effectiveCanonStamp: 'canon-stamp-$ordinal',
      effectiveCanonRevision: 1,
      effectiveCanonHash: 'canon-hash-$ordinal',
      canonicalResult: {
        'export': {
          'ops': [
            for (final key in opKeys) {'op': 'set', 'key': key, 'value': ''},
          ],
          'sceneState': {
            'presentEntities': [
              for (final name in presentEntities) {'name': name},
            ],
          },
        },
      },
      predecessorChainHash: existing?.chainHash ?? '',
      contractVersion: 1,
      opsApplied: const [],
      createdAt: ordinal * 10,
    );
    final reconciliationRepo = LedgerReconciliationRunRepo(db);
    final state = await reconciliationRepo.captureState('session');
    expect(
      await reconciliationRepo.append(run),
      isA<ReconciliationRunAppended>(),
    );
    await reconciliationRepo.recordEffect(
      runId: run.id,
      sessionId: 'session',
      before: state,
      after: state,
      createdAt: run.createdAt,
    );
    return (db.select(
      db.ledgerReconciliationSuccessfulRuns,
    )..where((row) => row.id.equals('run-$ordinal'))).getSingle();
  }

  String get cardBatchOutput => jsonEncode({
    'operations': [
      {
        'field': CardRewriteField.description.wireName,
        'patches': [
          {
            'scopeKey': 'npc:Алиса',
            'anchor': 'Alice is cautious.',
            'anchorSha256': CardCanonicalizer.scalarSha256(
              'Alice is cautious.',
            ),
            'value': 'Alice is increasingly trusting.',
          },
        ],
        'transition': {
          'id': 'transition',
          'scopeKey': 'npc:Алиса',
          'canonicalClaim': 'Alice is increasingly trusting.',
          'promotionDestination': 'card',
          'affectedTrackerKeys': <String>[],
          'factIds': <String>[],
          'chatSessionId': null,
        },
      },
    ],
  });

  String get observationNewOutput => jsonEncode({
    'observations': [
      {
        'action': 'new',
        'scopeKey': 'character.preference.trust',
        'observedChange': 'Alice is becoming more trusting',
        'canonicalClaim': 'Alice has become more trusting over time',
        'retrievalKeys': ['npc:Алиса'],
        'targetKind': 'main_character_card',
        'evidenceMessageIds': ['a1', 'u1'],
        'cardFieldPath': 'personality',
        'confidence': 0.8,
      },
    ],
  });

  String get observationConfirmOutput => jsonEncode({
    'observations': [
      {
        'action': 'confirm',
        'scopeKey': 'character.preference.trust',
        'observedChange': 'Alice is becoming more trusting',
        'retrievalKeys': ['npc:Алиса'],
        'targetKind': 'main_character_card',
        'confidence': 0.85,
        'evidenceMessageIds': ['a2', 'u2'],
      },
    ],
  });

  AutomatedCardEvolutionService service(
    Future<AuxCallOutcome> Function(CancelToken? token, String prompt)
    executor, {
    int Function()? observationExpiryRuns,
    void Function(LlmCaptureContext context)? onCaptureContext,
    void Function(AuxApiConfig config, int maxTokens)? onRequest,
    Future<bool> Function()? isCommitCurrent,
  }) => AutomatedCardEvolutionService(
    repo: repo,
    isCommitCurrent: isCommitCurrent,
    observationRepo: observationRepo,
    collectorRunRepo: collectorRepo,
    requestCaptureRepo: captureRepo,
    resolveModel: () async => const AuxApiConfig(
      endpoint: 'https://rewrite.example',
      apiKey: 'key',
      model: 'model',
      protocol: 'openai',
      maxTokens: 12345,
    ),
    resolveCollectorModel: (_) async => const AuxApiConfig(
      endpoint: 'https://ledger.example',
      apiKey: 'ledger-key',
      model: 'ledger-model',
      protocol: 'openai',
      maxTokens: 6789,
    ),
    executor:
        ({
          required config,
          required prompt,
          required maxTokens,
          required temperature,
          required timeoutMs,
          cancelToken,
          captureContext,
        }) {
          if (captureContext != null) onCaptureContext?.call(captureContext);
          onRequest?.call(config, maxTokens);
          return executor(cancelToken, prompt);
        },
    observationPromotionThreshold: () => 3,
    observationMinConfidence: () => 0.7,
    observationExpiryRuns: observationExpiryRuns ?? () => 4,
  );
}

const _messages = [
  {'id': 'a1', 'role': 'assistant', 'content': 'assistant 1'},
  {'id': 'u1', 'role': 'user', 'content': 'user 1'},
  {'id': 'a2', 'role': 'assistant', 'content': 'assistant 2'},
  {'id': 'u2', 'role': 'user', 'content': 'user 2'},
];
