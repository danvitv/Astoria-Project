import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/applied_canon_transition_repo.dart';
import 'package:glaze_flutter/core/db/repositories/canon_transition_fact_ref_repo.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_observation_repo.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_repo.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_writer_call_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_knowledge_fact_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_revision_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_session_baseline_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_raw_tracker_state_reader.dart';
import 'package:glaze_flutter/core/db/repositories/lorebook_use_manifest_repo.dart';
import 'package:glaze_flutter/core/db/repositories/manual_rewrite_job_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_snapshot_repo.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/aux_retry_runner.dart';
import 'package:glaze_flutter/core/llm/prompt/exact_lorebook_manifest.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/models/agent_operation_record.dart';
import 'package:glaze_flutter/core/models/card_evolution_observation.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/models/tracker_snapshot.dart';
import 'package:glaze_flutter/core/services/card_rewriter/automated_card_evolution_service.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewrite_operation_parser.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_read_repository.dart';
import 'package:glaze_flutter/core/utils/time_helpers.dart';

void main() {
  late _Fixture fixture;

  setUp(() async {
    fixture = await _Fixture.create();
  });
  tearDown(() => fixture.db.close());

  test('empty chat history makes zero executor calls', () async {
    await fixture.db.customStatement(
      "UPDATE chat_sessions SET messages_json = '[]' WHERE session_id = 'session'",
    );
    var calls = 0;
    final result = await fixture
        .service((_, _) async {
          calls++;
          return _ok(fixture.cardBatchOutput);
        })
        .runOneBatch('session');
    expect(result.kind, 'notEligible');
    expect(calls, 0);
    await fixture.expectNoProposalOrCanonWrites();
  });

  test('disabled automation makes zero claim or executor calls', () async {
    var calls = 0;
    final service = AutomatedCardEvolutionService(
      repo: fixture.repo,
      resolveModel: () async => throw StateError('must not resolve'),
      resolveCollectorModel: (_) async => throw StateError('must not resolve'),
      isEnabled: () => false,
      executor:
          ({
            required config,
            required prompt,
            required maxTokens,
            required temperature,
            required timeoutMs,
            cancelToken,
            captureContext,
          }) async {
            calls++;
            return _ok(fixture.cardBatchOutput);
          },
    );

    expect((await service.runOneBatch('session')).kind, 'disabled');
    expect(calls, 0);
    expect(
      await fixture.db.select(fixture.db.cardEvolutionClaims).get(),
      isEmpty,
    );
    await fixture.expectNoProposalOrCanonWrites();
  });

  test('successful output persists a pending proposal', () async {
    var calls = 0;
    final result = await fixture
        .service((token, prompt) async {
          calls++;
          expect(token, isNotNull);
          return _ok(fixture.cardBatchOutput);
        })
        .runOneBatch('session');
    expect(result.kind, 'persisted');
    expect(calls, 1);
    expect(
      (await fixture.db.select(fixture.db.rewriteJobs).getSingle()).status,
      'pending',
    );
    expect(
      await fixture.db.select(fixture.db.cardEvolutionProposalRuns).get(),
      hasLength(1),
    );
    final claim = await fixture.db
        .select(fixture.db.cardEvolutionClaims)
        .getSingle();
    // The writer renews the lease right before the model call, so a second
    // boundary tick between claim creation and renewal legitimately extends
    // the observed span beyond the base 600s lease.
    expect(claim.leaseExpiresAt - claim.createdAt, inInclusiveRange(600, 660));
    final operations = await fixture.db
        .select(fixture.db.rewriteOperations)
        .get();
    expect(operations, hasLength(1));
    expect(
      operations
          .map(
            (operation) =>
                jsonDecode(operation.operationJson)['field'] as String,
          )
          .toSet(),
      {CardRewriteField.description.wireName},
    );
    await fixture.expectCanonRowsUnchanged();
  });

  test(
    'automatic writer receives IC evidence without assistant route forecasts',
    () async {
      final session = await fixture.db
          .select(fixture.db.chatSessions)
          .getSingle();
      final messages = jsonDecode(session.messagesJson) as List;
      for (final message in messages.whereType<Map<String, dynamic>>()) {
        if (message['role'] == 'assistant') {
          message['content'] =
              '<lumiaooc>OOC_FORECAST_SENTINEL_ALL_NPCS_IN_LOVE</lumiaooc>'
              '${message['content']}';
        }
      }
      await fixture.db.customStatement(
        'UPDATE chat_sessions SET messages_json = ? WHERE session_id = ?',
        [jsonEncode(messages), 'session'],
      );
      var calls = 0;
      final result = await fixture
          .service((_, prompt) async {
            calls++;
            expect(
              prompt,
              isNot(contains('OOC_FORECAST_SENTINEL_ALL_NPCS_IN_LOVE')),
            );
            expect(prompt, contains('NOT narrated IC facts'));
            return _ok(fixture.cardBatchOutput);
          })
          .runOneBatch('session');
      expect(result.kind, 'persisted');
      expect(calls, 1);
      final claim = await fixture.db
          .select(fixture.db.cardEvolutionClaims)
          .getSingle();
      // Fence/evidence source retains original text; prompt projection is not a
      // transcript mutation or an attempt to forge a different source hash.
      expect(
        claim.selectedInputJson,
        contains('OOC_FORECAST_SENTINEL_ALL_NPCS_IN_LOVE'),
      );
      expect(
        (await fixture.db.select(fixture.db.chatSessions).getSingle())
            .messagesJson,
        contains('OOC_FORECAST_SENTINEL_ALL_NPCS_IN_LOVE'),
      );
      await fixture.expectCanonRowsUnchanged();
    },
  );

  test('model failure retains failed claim and call for resume', () async {
    var fail = true;
    var calls = 0;
    final service = fixture.service((_, _) async {
      calls++;
      if (!fail) return _ok(fixture.cardBatchOutput);
      return const AuxCallOutcome(
        status: AgentOperationStatus.httpError,
        attempts: [
          AgentOperationAttempt(
            attempt: 1,
            statusCode: 503,
            status: 'http_5xx',
            error: 'upstream unavailable',
            startedAtMs: 1,
            elapsedMs: 2,
          ),
        ],
      );
    });
    final first = await service.runOneBatch('session');
    expect(first.kind, 'cardModelFailed');
    expect(
      first.detail,
      '1 attempt(s), http_5xx HTTP 503: upstream unavailable',
    );
    final debug = await fixture.db
        .select(fixture.db.cardEvolutionDebugRuns)
        .getSingle();
    expect(debug.stage, 'card');
    expect(debug.status, 'httpError');
    expect(debug.output, isNull);
    expect(debug.attemptsJson, contains('upstream unavailable'));
    await fixture.expectNoProposalOrCanonWrites();
    final claim = await fixture.db
        .select(fixture.db.cardEvolutionClaims)
        .getSingle();
    final call = await fixture.db
        .select(fixture.db.cardEvolutionWriterCalls)
        .getSingle();
    expect(claim.status, 'failed');
    expect(call.status, 'failed');

    fail = false;
    final resumed = await service.resumeFailedWriter(claim.id);
    expect(resumed.kind, 'persisted');
    expect(calls, 2);
    expect(
      (await fixture.db.select(fixture.db.cardEvolutionWriterCalls).getSingle())
          .id,
      call.id,
    );
  });

  test('malformed parser output gets exactly one repair attempt', () async {
    var calls = 0;
    final contexts = <LlmCaptureContext>[];
    final result = await fixture
        .service((_, _) async {
          calls++;
          return _ok('not json');
        }, onCaptureContext: contexts.add)
        .runOneBatch('session');
    expect(result.kind, 'invalidCardOutput');
    expect(calls, 2);
    expect(contexts.map((context) => context.stage), [
      'card.writer',
      'card.writer_repair',
    ]);
    expect(contexts.every((context) => context.sessionId == 'session'), isTrue);
    expect(contexts[0].pipelineRunId, contexts[1].pipelineRunId);
    expect(
      (await fixture.db.select(fixture.db.cardEvolutionDebugRuns).getSingle())
          .output,
      'not json',
    );
    await fixture.expectNoProposalOrCanonWrites();
    expect(
      (await fixture.db.select(fixture.db.cardEvolutionClaims).getSingle())
          .status,
      'failed',
    );
  });

  test('malformed JSON can recover on the single repair attempt', () async {
    var calls = 0;
    final prompts = <String>[];
    final result = await fixture
        .service((_, prompt) async {
          calls++;
          prompts.add(prompt);
          return _ok(calls == 1 ? '{"operations":[' : fixture.cardBatchOutput);
        })
        .runOneBatch('session');

    expect(result.kind, 'persisted');
    expect(calls, 2);
    expect(prompts.last, contains('no JSON object was found'));
    expect(prompts.last, contains('exactly one valid JSON object'));
  });

  test('failed repair resumes without repeating completed card call', () async {
    var calls = 0;
    var repairFails = true;
    final service = fixture.service((_, _) async {
      calls++;
      if (calls == 1) return _ok('not json');
      if (repairFails) {
        return const AuxCallOutcome(status: AgentOperationStatus.httpError);
      }
      return _ok(fixture.cardBatchOutput);
    });

    expect((await service.runOneBatch('session')).kind, 'cardModelFailed');
    final claim = await fixture.db
        .select(fixture.db.cardEvolutionClaims)
        .getSingle();
    final before = await fixture.db
        .select(fixture.db.cardEvolutionWriterCalls)
        .get();
    expect(before.map((row) => row.status), ['completed', 'failed']);

    repairFails = false;
    expect((await service.resumeFailedWriter(claim.id)).kind, 'persisted');
    expect(calls, 3);
    final after = await fixture.db
        .select(fixture.db.cardEvolutionWriterCalls)
        .get();
    expect(after, hasLength(2));
    expect(after.first.responseText, 'not json');
  });

  test(
    'manual correction completes failed repair without a model call',
    () async {
      var calls = 0;
      final service = fixture.service((_, _) async {
        calls++;
        return calls == 1
            ? _ok('not json')
            : const AuxCallOutcome(status: AgentOperationStatus.httpError);
      });
      expect((await service.runOneBatch('session')).kind, 'cardModelFailed');
      final failedCall =
          (await fixture.db.select(fixture.db.cardEvolutionWriterCalls).get())
              .last;

      final result = await service.correctFailedWriterCall(
        failedCall.id,
        response: fixture.cardBatchOutput,
      );

      expect(result.kind, 'persisted');
      expect(calls, 2);
      final rows = await fixture.db
          .select(fixture.db.cardEvolutionWriterCalls)
          .get();
      expect(rows.last.source, 'manual_correction');
    },
  );

  test('invalid manual correction remains failed', () async {
    var calls = 0;
    final service = fixture.service((_, _) async {
      calls++;
      return const AuxCallOutcome(status: AgentOperationStatus.httpError);
    });
    await service.runOneBatch('session');
    final failedCall = await fixture.db
        .select(fixture.db.cardEvolutionWriterCalls)
        .getSingle();

    final result = await service.correctFailedWriterCall(
      failedCall.id,
      response: 'still invalid',
    );

    expect(result.kind, 'invalidCardOutput');
    expect(calls, 1);
    expect(
      (await fixture.db.select(fixture.db.cardEvolutionWriterCalls).getSingle())
          .status,
      'failed',
    );
  });

  test('expired claim does not start a repair call', () async {
    var calls = 0;
    final result = await fixture
        .service((_, _) async {
          calls++;
          await fixture.db.customStatement(
            "UPDATE card_evolution_claims SET lease_expires_at = 0 WHERE session_id = 'session'",
          );
          return _ok('not json');
        })
        .runOneBatch('session');

    expect(result.kind, 'leaseLost');
    expect(calls, 1);
    await fixture.expectNoProposalOrCanonWrites();
  });

  test('invalid scope gets one constrained repair attempt', () async {
    var calls = 0;
    final prompts = <String>[];
    final invalid = jsonDecode(fixture.cardBatchOutput) as Map<String, dynamic>;
    final operation = (invalid['operations'] as List).single as Map;
    ((operation['patches'] as List).single as Map)['scopeKey'] =
        'relationship:alice';
    (operation['transition'] as Map)['scopeKey'] = 'relationship:alice';

    final result = await fixture
        .service((_, prompt) async {
          calls++;
          prompts.add(prompt);
          return _ok(
            calls == 1 ? jsonEncode(invalid) : fixture.cardBatchOutput,
          );
        })
        .runOneBatch('session');

    expect(result.kind, 'persisted');
    expect(calls, 2);
    expect(prompts.last, contains('# Required correction'));
    expect(prompts.last, contains('unparsable patch scopeKey'));
    expect(
      (await fixture.db.select(fixture.db.cardEvolutionDebugRuns).getSingle())
          .output,
      fixture.cardBatchOutput,
    );
  });

  test(
    'missing promotion destination is called out in repair prompt',
    () async {
      var calls = 0;
      final prompts = <String>[];
      final invalid =
          jsonDecode(fixture.cardBatchOutput) as Map<String, dynamic>;
      final operation = (invalid['operations'] as List).single as Map;
      (operation['transition'] as Map).remove('promotionDestination');

      final result = await fixture
          .service((_, prompt) async {
            calls++;
            prompts.add(prompt);
            return _ok(
              calls == 1 ? jsonEncode(invalid) : fixture.cardBatchOutput,
            );
          })
          .runOneBatch('session');

      expect(result.kind, 'persisted');
      expect(calls, 2);
      expect(prompts.first, contains('transition.promotionDestination'));
      expect(prompts.last, contains('missingPromotionDestination'));
      expect(
        prompts.last,
        contains(
          'transition.promotionDestination to the non-empty string matching',
        ),
      );
      await fixture.expectCanonRowsUnchanged();
    },
  );

  test('invalid scope is rejected after exactly one repair attempt', () async {
    var calls = 0;
    final invalid = jsonDecode(fixture.cardBatchOutput) as Map<String, dynamic>;
    final operation = (invalid['operations'] as List).single as Map;
    ((operation['patches'] as List).single as Map)['scopeKey'] =
        'relationship:alice';
    (operation['transition'] as Map)['scopeKey'] = 'relationship:alice';

    final result = await fixture
        .service((_, _) async {
          calls++;
          return _ok(jsonEncode(invalid));
        })
        .runOneBatch('session');

    expect(result.kind, 'invalidCardOutput');
    expect(calls, 2);
    await fixture.expectNoProposalOrCanonWrites();
  });

  test('changed macro tokens get one constrained repair attempt', () async {
    var calls = 0;
    final prompts = <String>[];
    final invalid = jsonDecode(fixture.cardBatchOutput) as Map<String, dynamic>;
    final operation = (invalid['operations'] as List).single as Map;
    final patch = (operation['patches'] as List).single as Map;
    patch['value'] = '${patch['value']} {{user}}';

    final result = await fixture
        .service((_, prompt) async {
          calls++;
          prompts.add(prompt);
          return _ok(
            calls == 1 ? jsonEncode(invalid) : fixture.cardBatchOutput,
          );
        })
        .runOneBatch('session');

    expect(result.kind, 'persisted');
    expect(calls, 2);
    expect(prompts.last, contains('# Required correction'));
    expect(prompts.last, contains('macro-token multiset'));
    expect(prompts.last, contains('Never add, remove, rename'));
  });

  test('changed macro tokens are rejected after one repair attempt', () async {
    var calls = 0;
    final invalid = jsonDecode(fixture.cardBatchOutput) as Map<String, dynamic>;
    final operation = (invalid['operations'] as List).single as Map;
    final patch = (operation['patches'] as List).single as Map;
    patch['value'] = '${patch['value']} {{user}}';

    final result = await fixture
        .service((_, _) async {
          calls++;
          return _ok(jsonEncode(invalid));
        })
        .runOneBatch('session');

    expect(result.kind, 'invalidCardOutput');
    expect(calls, 2);
    await fixture.expectNoProposalOrCanonWrites();
  });

  test('cancellation reaches dedicated token and leaves no proposal', () async {
    final started = Completer<CancelToken>();
    final release = Completer<AuxCallOutcome>();
    final service = fixture.service((token, _) {
      started.complete(token!);
      return release.future;
    });
    final future = service.runOneBatch('session');
    final token = await started.future;
    service.cancelSession('session');
    expect(token.isCancelled, isTrue);
    release.complete(
      const AuxCallOutcome(status: AgentOperationStatus.aborted),
    );
    expect((await future).kind, 'cancelled');
    await fixture.expectNoProposalOrCanonWrites();
    expect(
      (await fixture.db.select(fixture.db.cardEvolutionClaims).getSingle())
          .status,
      'failed',
    );
  });

  test('canon changes after generation block proposal', () async {
    var changedCanon = false;
    final result = await fixture
        .service((_, prompt) async {
          if (!changedCanon) {
            changedCanon = true;
            await fixture.db.customStatement(
              "INSERT INTO tracker_rows (session_id, name, value, scope, provenance, updated_at) VALUES ('session', 'canon_lock:npc:alice', 'locked', 'ledger', 'manual', 2)",
            );
          }
          return _ok(fixture.cardBatchOutput);
        })
        .runOneBatch('session');
    expect(result.kind, 'staleEvidence');
    await fixture.expectNoProposalOrCanonWrites();
  });

  test('injected lorebook entries use a separate second call', () async {
    await _seedManifest(fixture.db, 'a1', 'entry one');
    var calls = 0;
    String? lorebookPrompt;
    final contexts = <LlmCaptureContext>[];
    final result = await fixture
        .service((_, prompt) async {
          calls++;
          if (prompt.contains('Astoria lorebook rewriter')) {
            lorebookPrompt = prompt;
            return _ok(fixture.lorebookBatchOutput);
          }
          return _ok(fixture.cardBatchOutput);
        }, onCaptureContext: contexts.add)
        .runOneBatch('session');

    expect(calls, 2);
    expect(contexts.map((context) => context.stage), [
      'card.writer',
      'card.lorebook_writer',
    ]);
    expect(result.kind, 'persisted');
    expect(lorebookPrompt, contains('"description":"Alice is cautious."'));
    expect(lorebookPrompt, contains('# Proposed card operations (read-only)'));
    expect(lorebookPrompt, contains('increasingly trusting'));
    // Without a session overlay the entry must not carry a duplicated base.
    expect(lorebookPrompt, contains('"content":"entry one"'));
    expect(lorebookPrompt, isNot(contains('"baseContent":"entry one"')));
    final operations = await fixture.db
        .select(fixture.db.rewriteOperations)
        .get();
    expect(operations, hasLength(2));
    expect(
      operations.map(
        (operation) => jsonDecode(operation.operationJson)['target'],
      ),
      contains('lorebook'),
    );
    final debug = await fixture.db
        .select(fixture.db.cardEvolutionDebugRuns)
        .get();
    expect(debug.map((row) => row.stage), containsAll(['card', 'lorebook']));
  });

  test(
    'lore-only card target gets one repair then a pending lore job',
    () async {
      await fixture.seedLoreOnlyObservation();
      final contexts = <LlmCaptureContext>[];
      final prompts = <String>[];
      final result = await fixture
          .service((_, prompt) async {
            prompts.add(prompt);
            if (prompt.contains('Astoria lorebook rewriter')) {
              expect(prompt, contains('lore-only-observation'));
              expect(prompt, contains('npc:alice.attitude'));
              expect(
                prompt,
                contains('# Proposed card operations (read-only)\n[]'),
              );
              return _ok(fixture.lorebookBatchOutput);
            }
            // The card evidence projection still retains Ledger facts but omits
            // lore observations. The destination fence must use the full input.
            expect(prompt, isNot(contains('lore-only-observation')));
            expect(prompt, contains('npc:alice.attitude'));
            return _ok(
              prompts.length == 1
                  ? fixture.cardBatchOutput
                  : '{"operations":[]}',
            );
          }, onCaptureContext: contexts.add)
          .runOneBatch('session');

      expect(result.kind, 'persisted', reason: result.detail);
      expect(contexts.map((context) => context.stage), [
        'card.writer',
        'card.writer_repair',
        'card.lorebook_writer',
      ]);
      final correction = prompts[1].split('# Required correction').last;
      expect(correction, contains('invalidCardObservationTarget'));
      expect(correction, contains('transition.scopeKey "npc:alice"'));
      expect(correction, contains('No available scope key is permitted'));
      expect(correction, contains('Remove lore-only card operations'));
      expect(correction, contains('Leave those facts for the lorebook writer'));
      expect(correction, isNot(contains('available keys: ["npc:alice"]')));
      final calls = await CardEvolutionWriterCallRepo(fixture.db).readChain(
        (await fixture.db.select(fixture.db.cardEvolutionClaims).getSingle())
            .id,
      );
      expect(calls.map((row) => row.status), [
        'completed',
        'completed',
        'completed',
      ]);
      expect(calls.first.parserCode, 'invalidOutput');
      expect(calls.first.responseText, fixture.cardBatchOutput);
      expect(calls[1].parserCode, 'accepted');
      expect(calls[1].resultJson, '[]');
      final operations = await fixture.db
          .select(fixture.db.rewriteOperations)
          .get();
      expect(operations, hasLength(1));
      expect(jsonDecode(operations.single.operationJson)['target'], 'lorebook');
      expect(
        (await fixture.db.select(fixture.db.rewriteJobs).getSingle()).status,
        'pending',
      );
      await fixture.expectCanonRowsUnchanged();
      expect(
        await fixture.db.select(fixture.db.sessionLorebookEvolutionRows).get(),
        isEmpty,
      );
    },
  );

  test(
    'forbidden repair fails before lore and retains both responses',
    () async {
      await fixture.seedLoreOnlyObservation();
      var calls = 0;
      final invalidMacro = jsonDecode(fixture.cardBatchOutput) as Map;
      final operation = (invalidMacro['operations'] as List).single as Map;
      ((operation['patches'] as List).single as Map)['value'] =
          'Alice is increasingly trusting {{user}}.';
      final rejected = jsonEncode(invalidMacro);
      final result = await fixture
          .service((_, prompt) async {
            calls++;
            expect(prompt, isNot(contains('Astoria lorebook rewriter')));
            return _ok(calls == 1 ? rejected : fixture.cardBatchOutput);
          })
          .runOneBatch('session');

      expect(result.kind, 'invalidCardOutput');
      expect(result.detail, contains('invalidCardObservationTarget'));
      expect(calls, 2);
      final claim = await fixture.db
          .select(fixture.db.cardEvolutionClaims)
          .getSingle();
      final chain = await CardEvolutionWriterCallRepo(
        fixture.db,
      ).readChain(claim.id);
      expect(claim.status, 'failed');
      expect(chain.map((row) => row.stage), ['card_writer', 'card_repair']);
      expect(chain.map((row) => row.status), ['completed', 'failed']);
      expect(chain.first.parserDetail, contains('macroTokensChanged'));
      expect(chain.first.responseText, rejected);
      expect(chain.last.responseText, fixture.cardBatchOutput);
      expect(chain.last.parserDetail, contains('invalidCardObservationTarget'));
      expect(chain.last.completedAt, isNull);
      await fixture.expectNoProposalOrCanonWrites();
    },
  );

  test(
    'unrelated valid card scope remains writable beside lore-only scope',
    () async {
      await fixture.seedLoreOnlyObservation(
        scope: 'npc:bob',
        additionalTrackers: const {
          'npc:alice.attitude': 'increasingly trusting',
        },
      );
      var calls = 0;
      final result = await fixture
          .service((_, prompt) async {
            calls++;
            return _ok(
              prompt.contains('Astoria lorebook rewriter')
                  ? fixture.lorebookBatchOutput
                  : fixture.cardBatchOutput,
            );
          })
          .runOneBatch('session');

      expect(result.kind, 'persisted', reason: result.detail);
      expect(calls, 2);
      final operations = await fixture.db
          .select(fixture.db.rewriteOperations)
          .get();
      expect(operations, hasLength(2));
      await fixture.expectCanonRowsUnchanged();
    },
  );

  test(
    'repair advertises only permitted scope keys without discarding lore facts',
    () async {
      await fixture.seedLoreOnlyObservation(
        additionalTrackers: const {'npc:bob.attitude': 'observant'},
      );
      var calls = 0;
      final result = await fixture
          .service((_, prompt) async {
            calls++;
            if (calls == 1) return _ok(fixture.cardBatchOutput);
            if (calls == 2) {
              final correction = prompt.split('# Required correction').last;
              expect(correction, contains('available keys: ["npc:bob"]'));
              expect(
                correction,
                isNot(contains('available keys: ["npc:alice"')),
              );
              expect(correction, contains('do not retarget or rename'));
              expect(
                correction,
                contains(
                  '{"operations":[]} if no allowed card operations remain',
                ),
              );
              return _ok('{"operations":[]}');
            }
            expect(prompt, contains('lore-only-observation'));
            expect(prompt, contains('npc:alice.attitude'));
            return _ok(fixture.lorebookBatchOutput);
          })
          .runOneBatch('session');

      expect(result.kind, 'persisted', reason: result.detail);
      expect(calls, 3);
      await fixture.expectCanonRowsUnchanged();
    },
  );

  test(
    'legacy completed forbidden repair is not replayed or overwritten',
    () async {
      await fixture.seedLoreOnlyObservation();
      var calls = 0;
      final service = fixture.service((_, _) async {
        calls++;
        return _ok(fixture.cardBatchOutput);
      });
      expect((await service.runOneBatch('session')).kind, 'invalidCardOutput');
      final failed = await fixture.db
          .select(fixture.db.cardEvolutionClaims)
          .getSingle();
      const owner = 'legacy-fixture-owner';
      final now = currentTimestampSeconds();
      final claimed = await fixture.repo.claimFailedWriter(
        claimId: failed.id,
        ownerId: owner,
        now: now,
        leaseSeconds: 600,
      );
      expect(claimed.isClaimed, isTrue);
      final checkpoints = CardEvolutionWriterCallRepo(fixture.db);
      final repair = (await checkpoints.readChain(failed.id)).last;
      expect(
        await checkpoints.retryFailed(
          id: repair.id,
          claimId: failed.id,
          ownerId: owner,
          now: now,
        ),
        isTrue,
      );
      // Emulate a legacy version that accepted this structurally valid repair,
      // then completed lore, before finalization rejected the card destination.
      final cardOperations = CardRewriteOperationParser.parseEvolutionBatch(
        fixture.cardBatchOutput,
      )!;
      expect(
        await checkpoints.completeCall(
          id: repair.id,
          claimId: failed.id,
          ownerId: owner,
          now: now,
          responseText: fixture.cardBatchOutput,
          resultJson: _encodedOperations(cardOperations),
          source: 'model',
          parserCode: 'accepted',
          lastCallId: 'legacy-card-repair-call',
        ),
        isTrue,
      );
      final lore = await checkpoints.prepareNextCall(
        claimId: failed.id,
        ownerId: owner,
        now: now,
        ordinal: 3,
        stage: 'lorebook_writer',
        stageOrdinal: 1,
        prompt: 'saved legacy lorebook request',
        parentCallId: 'legacy-card-repair-call',
      );
      expect(
        await checkpoints.completeCall(
          id: lore.row!.id,
          claimId: failed.id,
          ownerId: owner,
          now: now,
          responseText: fixture.lorebookBatchOutput,
          resultJson: _encodedOperations(
            CardRewriteOperationParser.parseLorebookEvolutionBatch(
              fixture.lorebookBatchOutput,
            )!,
          ),
          source: 'model',
          parserCode: 'accepted',
          lastCallId: 'legacy-lore-call',
        ),
        isTrue,
      );
      await fixture.repo.markWriterFailed(
        claimId: failed.id,
        ownerId: owner,
        now: now,
        code: 'invalidCardObservationTarget',
      );
      final before = await checkpoints.readChain(failed.id);

      final replay = await service.resumeFailedWriter(failed.id);

      expect(replay.kind, 'invalidCardObservationTarget');
      expect(
        replay.detail,
        contains('Stored completed card_repair checkpoint ${repair.id}'),
      );
      expect(replay.detail, contains('immutable checkpoint is retained'));
      expect(calls, 2);
      expect(await checkpoints.readChain(failed.id), before);
      expect((await fixture.repo.getClaimById(failed.id))!.status, 'failed');
      await fixture.expectNoProposalOrCanonWrites();
    },
  );

  test(
    'legacy accepted card checkpoint fails replay without another model call',
    () async {
      await fixture.seedLoreOnlyObservation();
      var calls = 0;
      final service = fixture.service((_, _) async {
        calls++;
        return const AuxCallOutcome(status: AgentOperationStatus.httpError);
      });
      expect((await service.runOneBatch('session')).kind, 'cardModelFailed');
      final failed = await fixture.db
          .select(fixture.db.cardEvolutionClaims)
          .getSingle();
      const owner = 'legacy-card-fixture-owner';
      final now = currentTimestampSeconds();
      expect(
        (await fixture.repo.claimFailedWriter(
          claimId: failed.id,
          ownerId: owner,
          now: now,
          leaseSeconds: 600,
        )).isClaimed,
        isTrue,
      );
      final checkpoints = CardEvolutionWriterCallRepo(fixture.db);
      final card = (await checkpoints.readChain(failed.id)).single;
      expect(
        await checkpoints.retryFailed(
          id: card.id,
          claimId: failed.id,
          ownerId: owner,
          now: now,
        ),
        isTrue,
      );
      expect(
        await checkpoints.completeCall(
          id: card.id,
          claimId: failed.id,
          ownerId: owner,
          now: now,
          responseText: fixture.cardBatchOutput,
          resultJson: _encodedOperations(
            CardRewriteOperationParser.parseEvolutionBatch(
              fixture.cardBatchOutput,
            )!,
          ),
          source: 'model',
          parserCode: 'accepted',
          lastCallId: 'legacy-card-call',
        ),
        isTrue,
      );
      await fixture.repo.markWriterFailed(
        claimId: failed.id,
        ownerId: owner,
        now: now,
        code: 'invalidCardObservationTarget',
      );
      final before = await checkpoints.readChain(failed.id);

      final replay = await service.resumeFailedWriter(failed.id);

      expect(replay.kind, 'invalidCardObservationTarget');
      expect(
        replay.detail,
        contains('Stored completed card_writer checkpoint ${card.id}'),
      );
      expect(calls, 1);
      expect(await checkpoints.readChain(failed.id), before);
      await fixture.expectNoProposalOrCanonWrites();
    },
  );

  test('evolved lorebook entries keep their diverged base', () async {
    await _seedManifest(fixture.db, 'a1', 'entry one');
    await fixture.db
        .into(fixture.db.sessionLorebookEvolutionRows)
        .insert(
          SessionLorebookEvolutionRowsCompanion.insert(
            chatSessionId: 'session',
            lorebookId: 'book-a1',
            entryId: 'entry-a1-0',
            baseContent: 'entry one',
            baseContentHash: CardCanonicalizer.scalarSha256('entry one'),
            content: 'entry one evolved',
            contentHash: CardCanonicalizer.scalarSha256('entry one evolved'),
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    String? lorebookPrompt;
    final result = await fixture
        .service((_, prompt) async {
          if (prompt.contains('Astoria lorebook rewriter')) {
            lorebookPrompt = prompt;
            return _ok(
              jsonEncode({
                'operations': [
                  {
                    'lorebookId': 'book-a1',
                    'entryId': 'entry-a1-0',
                    // Service-owned target metadata is normalized from the
                    // immutable snapshot rather than trusted from model echo.
                    'baseContent': 'entry one evolved',
                    'expectedContentHash': CardCanonicalizer.scalarSha256(
                      'entry one evolved',
                    ),
                    'patches': [
                      {
                        'anchor': 'evolved',
                        'anchorSha256': CardCanonicalizer.scalarSha256(
                          'evolved',
                        ),
                        'value': 'evolved further',
                      },
                    ],
                  },
                ],
              }),
            );
          }
          return _ok(fixture.cardBatchOutput);
        })
        .runOneBatch('session');

    expect(result.kind, 'persisted', reason: result.detail);
    expect(lorebookPrompt, contains('"baseContent":"entry one"'));
    expect(lorebookPrompt, contains('"content":"entry one evolved"'));
    final loreOperation =
        (await fixture.db.select(fixture.db.rewriteOperations).get())
            .map((row) => jsonDecode(row.operationJson))
            .singleWhere((operation) => operation['target'] == 'lorebook');
    expect(loreOperation['baseContent'], 'entry one');
    expect(
      loreOperation['expectedContentHash'],
      CardCanonicalizer.scalarSha256('entry one evolved'),
    );
  });

  test('oversized shared context reports the context gate limit', () async {
    await _seedManifestEntries(
      fixture.db,
      'a1',
      List.generate(7, (index) => 'x' * 60000),
    );
    final result = await fixture
        .service((_, prompt) async => _ok('{"operations":[]}'))
        .runOneBatch('session');

    expect(result.kind, 'snapshotTooLarge');
    expect(result.detail, contains('safe request limit is 400000'));
  });

  test(
    'lorebook failure resumes lorebook without repeating card call',
    () async {
      await _seedManifest(fixture.db, 'a1', 'entry one');
      var cardCalls = 0;
      var lorebookCalls = 0;
      var lorebookFails = true;
      final service = fixture.service((_, prompt) async {
        if (prompt.contains('Astoria lorebook rewriter')) {
          lorebookCalls++;
          return lorebookFails
              ? const AuxCallOutcome(status: AgentOperationStatus.httpError)
              : _ok(fixture.lorebookBatchOutput);
        }
        cardCalls++;
        return _ok(fixture.cardBatchOutput);
      });

      expect(
        (await service.runOneBatch('session')).kind,
        'lorebookModelFailed',
      );
      final claim = await fixture.db
          .select(fixture.db.cardEvolutionClaims)
          .getSingle();
      lorebookFails = false;

      expect((await service.resumeFailedWriter(claim.id)).kind, 'persisted');
      expect(cardCalls, 1);
      expect(lorebookCalls, 2);
      expect(
        await fixture.db.select(fixture.db.cardEvolutionProposalRuns).get(),
        hasLength(1),
      );
    },
  );

  test('accepts injected lorebook entries up to 60000 characters', () async {
    final content = List.filled(59999, 'x').join();
    await _seedManifest(fixture.db, 'a2', content);
    String? lorebookPrompt;
    final service = fixture.service((token, prompt) async {
      if (prompt.contains('Astoria lorebook rewriter')) {
        lorebookPrompt = prompt;
        return _ok(fixture.lorebookBatchOutput);
      }
      return _ok(fixture.cardBatchOutput);
    });

    await service.runOneBatch('session');

    expect(lorebookPrompt, isNotNull);
    expect(lorebookPrompt, contains(content));
  });

  test('uses the configured writer idle timeout', () async {
    int? receivedTimeout;
    final result = await fixture
        .service(
          (_, _) async => _ok(fixture.cardBatchOutput),
          timeoutMs: 180000,
          onTimeout: (timeoutMs) => receivedTimeout = timeoutMs,
        )
        .runOneBatch('session');

    expect(result.kind, 'persisted');
    expect(receivedTimeout, 180000);
  });

  test('uses the Card Rewriter API response budget for writer calls', () async {
    int? receivedMaxTokens;
    final result = await fixture
        .service(
          (_, _) async => _ok(fixture.cardBatchOutput),
          onMaxTokens: (maxTokens) => receivedMaxTokens = maxTokens,
        )
        .runOneBatch('session');

    expect(result.kind, 'persisted');
    expect(receivedMaxTokens, 12345);
  });

  test('disabled lorebook evolution skips its second model call', () async {
    await _seedManifest(fixture.db, 'a1', 'entry one');
    var calls = 0;
    final result = await fixture
        .service((_, _) async {
          calls++;
          return _ok(fixture.cardBatchOutput);
        }, isLorebookEvolutionEnabled: () => false)
        .runOneBatch('session');

    expect(result.kind, 'persisted');
    expect(calls, 1);
    final operations = await fixture.db
        .select(fixture.db.rewriteOperations)
        .get();
    expect(operations, hasLength(1));
    final debug = await fixture.db
        .select(fixture.db.cardEvolutionDebugRuns)
        .get();
    expect(debug.map((row) => row.stage), ['card']);
  });

  test('empty card field is excluded from evolution operations', () async {
    await fixture.db.customStatement(
      "UPDATE characters SET description = '' WHERE char_id = 'character'",
    );
    var calls = 0;
    final result = await fixture
        .service((_, _) async {
          calls++;
          return _ok(fixture.cardBatchOutput);
        })
        .runOneBatch('session');

    expect(result.kind, 'emptyModelProposal');
    expect(calls, 0);
    await fixture.expectNoProposalOrCanonWrites();
  });
}

typedef _Executor =
    Future<AuxCallOutcome> Function(CancelToken? token, String prompt);

final class _Fixture {
  _Fixture(this.db, this.repo, this.revisionCount);

  final AppDatabase db;
  final CardEvolutionRepo repo;
  final int revisionCount;

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
    return _Fixture(db, repo, 1);
  }

  String get cardBatchOutput => jsonEncode({
    'operations': [
      {
        'field': CardRewriteField.description.wireName,
        'patches': [
          {
            'scopeKey': 'npc:alice',
            'anchor': 'Alice is cautious.',
            'anchorSha256': CardCanonicalizer.scalarSha256(
              'Alice is cautious.',
            ),
            'value': 'Alice is increasingly trusting.',
          },
        ],
        'transition': {
          'id': 'transition',
          'scopeKey': 'npc:alice',
          'canonicalClaim': 'Alice is increasingly trusting.',
          'promotionDestination': 'card',
          'affectedTrackerKeys': <String>[],
          'factIds': <String>[],
          'chatSessionId': null,
        },
      },
    ],
  });

  String get lorebookBatchOutput => jsonEncode({
    'operations': [
      {
        'lorebookId': 'book-a1',
        'entryId': 'entry-a1-0',
        'baseContent': 'entry one',
        'expectedContentHash': CardCanonicalizer.scalarSha256('entry one'),
        'patches': [
          {
            'anchor': 'entry one',
            'anchorSha256': CardCanonicalizer.scalarSha256('entry one'),
            'value': 'entry one updated',
          },
        ],
      },
    ],
  });

  AutomatedCardEvolutionService service(
    _Executor executor, {
    bool Function()? isLorebookEvolutionEnabled,
    int timeoutMs = 180000,
    void Function(int timeoutMs)? onTimeout,
    void Function(int maxTokens)? onMaxTokens,
    void Function(LlmCaptureContext context)? onCaptureContext,
  }) => AutomatedCardEvolutionService(
    repo: repo,
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
          onTimeout?.call(timeoutMs);
          onMaxTokens?.call(maxTokens);
          if (captureContext != null) onCaptureContext?.call(captureContext);
          return executor(cancelToken, prompt);
        },
    isLorebookEvolutionEnabled: isLorebookEvolutionEnabled,
    timeoutMs: timeoutMs,
  );

  Future<void> seedLoreOnlyObservation({
    String scope = 'npc:alice',
    Map<String, String> additionalTrackers = const {},
  }) async {
    await _seedManifest(db, 'a1', 'entry one');
    final trackers = [
      for (final entry in {
        '$scope.attitude': 'increasingly trusting',
        ...additionalTrackers,
      }.entries)
        Tracker(
          sessionId: 'session',
          name: entry.key,
          value: entry.value,
          scope: 'ledger',
          provenance: 'ledger',
          updatedAt: 1,
        ),
    ];
    for (final tracker in trackers) {
      await db.customStatement(
        'INSERT INTO tracker_rows (session_id, name, value, scope, provenance, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        [
          tracker.sessionId,
          tracker.name,
          tracker.value,
          tracker.scope,
          tracker.provenance,
          tracker.updatedAt,
        ],
      );
    }
    await CardEvolutionObservationRepo(db).insertObservation(
      CardEvolutionObservation(
        id: 'lore-only-observation',
        sessionId: 'session',
        characterId: 'character',
        runOrdinal: 1,
        semanticScopeKey: scope,
        observedChange: 'The injected entry needs an update.',
        canonicalClaim: 'A durable lore-only update.',
        evidenceClusters: const [
          ['a1'],
        ],
        retrievalKeys: [scope],
        targetKind: 'injected_lorebook_entry',
        lorebookEntryId: 'entry-a1-0',
        confidence: 0.9,
        status: 'active',
        firstSeenRun: 1,
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    // Writer selection reads the committed historical state before a2, not
    // live NPC rows. Seed one complete snapshot on the included a1 anchor,
    // before any writer claim fixes its immutable selected input.
    await TrackerSnapshotRepo(db).upsert(
      TrackerSnapshot(
        sessionId: 'session',
        messageId: 'a1',
        swipeId: 0,
        agentSwipeId: 0,
        trackers: trackers,
        committed: true,
        createdAt: 1,
      ),
    );
    final snapshot = await repo.buildObservationSnapshot('session');
    expect(snapshot, isNotNull);
    final selected = jsonDecode(snapshot!.selectedInputJson) as Map;
    expect(
      (selected['accumulatedObservations'] as List).map(
        (observation) => (observation as Map)['id'],
      ),
      contains('lore-only-observation'),
    );
    expect(
      ((selected['effectiveCanon'] as Map)['trackers'] as List).map(
        (tracker) => (tracker as Map)['name'],
      ),
      containsAll(trackers.map((tracker) => tracker.name)),
    );
    expect(
      (selected['availableObservationRetrievalTargets'] as List).map(
        (target) => (target as Map)['key'],
      ),
      contains(scope),
    );
  }

  Future<void> expectNoProposalOrCanonWrites() async {
    expect(await db.select(db.rewriteJobs).get(), isEmpty);
    expect(await db.select(db.cardEvolutionProposalRuns).get(), isEmpty);
    await expectCanonRowsUnchanged();
  }

  Future<void> expectCanonRowsUnchanged() async {
    expect(
      await db.select(db.characterRevisionRows).get(),
      hasLength(revisionCount),
    );
    expect(await db.select(db.characterSessionBaselineRows).get(), isEmpty);
  }
}

const _messages = [
  {'id': 'a1', 'role': 'assistant', 'content': 'assistant 1'},
  {'id': 'u1', 'role': 'user', 'content': 'user 1'},
  {'id': 'a2', 'role': 'assistant', 'content': 'assistant 2'},
  {'id': 'u2', 'role': 'user', 'content': 'user 2'},
];

Future<void> _seedManifest(AppDatabase db, String messageId, String content) =>
    _seedManifestEntries(db, messageId, [content]);

Future<void> _seedManifestEntries(
  AppDatabase db,
  String messageId,
  List<String> contents,
) async {
  final entries = [
    for (var index = 0; index < contents.length; index++)
      ExactLorebookManifestEntry.fromMergedEntry(
        entry: LorebookEntry(
          id: 'entry-$messageId-$index',
          lorebookId: 'book-$messageId',
          content: contents[index],
          position: 'worldInfoBefore',
        ),
        source: 'keyword',
        classification: 'worldInfoBefore',
        injectionIndex: index,
        renderedContent: contents[index],
      ),
  ];
  final manifest = ExactLorebookManifest(
    entries: entries,
    promptProvenance: const ExactLorebookPromptProvenance(
      characterId: 'character',
      sessionId: 'session',
      presetSnapshotHash: 'preset',
    ),
    providerMessagesHash: 'prompt-$messageId',
  );
  final identity = LorebookUseGenerationIdentity(
    sessionId: 'session',
    messageId: messageId,
    swipeId: 0,
    agentSwipeId: 0,
  );
  final repo = LorebookUseManifestRepo(db);
  await repo.insertGenerationManifest(
    identity: identity,
    manifest: LorebookUseManifestInput(
      manifestJson: manifest.canonicalJson,
      manifestHash: manifest.canonicalHash,
      manifestSchemaVersion: 1,
      finalPromptHash: manifest.providerMessagesHash,
      presetSnapshotHash: manifest.promptProvenance.presetSnapshotHash,
    ),
    createdAt: 1,
    entries: [
      for (var index = 0; index < entries.length; index++)
        LorebookUseManifestEntryInput(
          lorebookId: entries[index].lorebookId,
          entryId: entries[index].entryId,
          entryOrder: index,
          evidenceJson: jsonEncode(entries[index].toJson()),
        ),
    ],
  );
}

AuxCallOutcome _ok(String text) =>
    AuxCallOutcome(status: AgentOperationStatus.ok, text: text);

String _encodedOperations(Iterable<RewriteOperationSnapshot> operations) =>
    jsonEncode([
      for (final operation in operations)
        jsonDecode(RewriteOperationSnapshotCodec.encode(operation)),
    ]);
