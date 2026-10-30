import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/application/sync_reconciliation_source.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_collector_run_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_run_repo.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';
import 'package:glaze_flutter/features/cloud_sync/adapters/ext_blocks_sync_stores.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_serialization.dart';

void main() {
  late AppDatabase sourceDb;
  late AppDatabase pagedDb;
  late AppDatabase legacyDb;
  late ReconciliationStateSyncStore sourceStore;
  late _NoLegacyStore pagedStore;
  late ReconciliationStateSyncStore legacyStore;

  setUp(() async {
    sourceDb = AppDatabase.forTesting(NativeDatabase.memory());
    pagedDb = AppDatabase.forTesting(NativeDatabase.memory());
    legacyDb = AppDatabase.forTesting(NativeDatabase.memory());
    sourceStore = ReconciliationStateSyncStore(sourceDb);
    pagedStore = _NoLegacyStore(pagedDb);
    legacyStore = ReconciliationStateSyncStore(legacyDb);
    for (final db in [sourceDb, pagedDb, legacyDb]) {
      await _seedSession(db);
    }
  });

  tearDown(() async {
    await sourceDb.close();
    await pagedDb.close();
    await legacyDb.close();
  });

  test(
    'paged fingerprint exactly matches every legacy section and key order',
    () async {
      await _completeFixture(sourceDb, invalidEffect: true);
      await _invalidate(sourceDb, 'run-2');
      final legacy = (await sourceStore.getBySessionId('session'))!;
      final scalable = _NoLegacyStore(sourceDb);

      expect(await scalable.hasBySessionId('session'), isTrue);
      final fingerprint = (await scalable.fingerprintBySessionId('session'))!;
      expect(fingerprint.hash, SyncSerialization.computeSyncHash(legacy));
      expect(fingerprint.jsonBytes, utf8.encode(jsonEncode(legacy)).length);
      expect(
        (legacy['manifestEntries'] as List).map(
          (row) => (row as Map)['entryOrder'],
        ),
        [1, 10, 2],
      );
      expect(legacy['completedClaims'], hasLength(1));
      expect(legacy['effects'], hasLength(5));
      expect(legacy['collectors'], hasLength(2));
      expect(
        (legacy['observations'] as List).map(
          (row) => (row as Map)['semanticScopeKey'],
        ),
        [
          'character.personality.trust',
          'character.personality.😀',
          'character.personality.\uE000',
        ],
      );
      expect((legacy['collectors'] as List).first, containsPair('ownerId', ''));
      expect(
        (legacy['observations'] as List).first,
        containsPair(
          'id',
          'cloud-observation-${computeHash('session\u001fcharacter.personality.trust')}',
        ),
      );
    },
  );

  test('an export source cannot escape its transaction', () async {
    expect(await pagedStore.hasBySessionId('session'), isFalse);
    expect(await pagedStore.fingerprintBySessionId('session'), isNull);
    await _appendRuns(pagedDb, 1);
    late ReconciliationStateSource escaped;
    final count = await pagedStore.withExportSnapshot('session', (
      source,
    ) async {
      escaped = source;
      return (await source
              .readSection(ReconciliationSection.runs)
              .take(1)
              .toList())
          .length;
    });
    expect(count, 1);
    expect(
      await pagedDb
          .customSelect(
            "SELECT name FROM sqlite_temp_master "
            "WHERE name LIKE '__reconciliation_export_page_%'",
          )
          .get(),
      isEmpty,
    );
    await expectLater(
      escaped.readSection(ReconciliationSection.runs).toList(),
      throwsStateError,
    );
  });

  test(
    'paged import matches legacy and replays all variations before selections',
    () async {
      await _completeFixture(sourceDb);
      final payload = (await sourceStore.getBySessionId('session'))!;
      // A selection is the first physical acceptance row. Its variation is last.
      expect(
        (payload['acceptances'] as List).first,
        containsPair('acceptanceKind', 'selection'),
      );
      final source = _RecordingSource(payload);
      await pagedStore.mergeFromSource('session', source);
      await legacyStore.mergeBySessionId('session', payload);

      expect(await _payload(pagedDb), await _payload(legacyDb));
      expect(source.reads[ReconciliationSection.acceptances], 2);
      expect((await _payload(pagedDb))!['acceptances'], hasLength(2));
      expect((await _payload(pagedDb))!['collectors'], hasLength(2));
      expect((await _payload(pagedDb))!['completedClaims'], hasLength(1));
    },
  );

  test(
    'invalidations reset derived state globally and stale replay cannot resurrect it',
    () async {
      await _completeFixture(sourceDb);
      final stale = (await sourceStore.getBySessionId('session'))!;
      await pagedStore.mergeFromSource('session', _RecordingSource(stale));
      await legacyStore.mergeBySessionId('session', stale);
      final invalidated = {
        ...stale,
        'invalidations': [_invalidation('run-6')],
      };
      for (final payload in [invalidated, stale]) {
        await pagedStore.mergeFromSource('session', _RecordingSource(payload));
        await legacyStore.mergeBySessionId('session', payload);
        expect(await _payload(pagedDb), await _payload(legacyDb));
      }
      final result = (await _payload(pagedDb))!;
      expect(result['runs'], hasLength(6));
      expect(result['invalidations'], hasLength(1));
      expect(result['collectors'], hasLength(1));
      expect(result['observations'], isEmpty);
      // A completed writer claim remains immutable physically, but is no longer
      // exported when its completed collector boundary is absent.
      expect(result['completedClaims'], isEmpty);
      expect(
        await pagedDb.select(pagedDb.cardEvolutionClaims).get(),
        hasLength(1),
      );
    },
  );

  test(
    'late malformed evidence retains prefix/source and skips effects and derived rows',
    () async {
      await _completeFixture(sourceDb);
      final payload = (await sourceStore.getBySessionId('session'))!
        ..['invalidations'] = [_invalidation('unknown-run')];
      for (final db in [pagedDb, legacyDb]) {
        await db.customStatement(
          'UPDATE chat_sessions SET messages_json = ? WHERE session_id = ?',
          [
            jsonEncode([
              _messages[0],
              _messages[1],
              {
                ..._messages[2],
                'content': 'edited',
                'swipes': ['edited'],
              },
              _messages[3],
            ]),
            'session',
          ],
        );
      }
      final source = _RecordingSource(payload);
      await pagedStore.mergeFromSource('session', source);
      await legacyStore.mergeBySessionId('session', payload);
      final result = (await _payload(pagedDb))!;
      expect(result, await _payload(legacyDb));
      expect(result['runs'], hasLength(5));
      expect(result['manifests'], hasLength(1));
      expect(result['manifestEntries'], hasLength(3));
      expect(result['effects'], isEmpty);
      expect(result['invalidations'], isEmpty);
      expect(result['collectors'], isEmpty);
      expect(result['observations'], isEmpty);
      expect(source.reads[ReconciliationSection.effects], isNull);
    },
  );

  test(
    'a late invalid collector suppresses every collector insertion',
    () async {
      await _completeFixture(sourceDb);
      final payload = (await sourceStore.getBySessionId('session'))!;
      final collectors = (payload['collectors'] as List)
          .cast<Map<String, dynamic>>();
      payload['collectors'] = [
        collectors.first,
        {...collectors.last, 'rangeHash': 'stale'},
      ];
      final source = _RecordingSource(payload);
      await pagedStore.mergeFromSource('session', source);
      await legacyStore.mergeBySessionId('session', payload);
      final result = (await _payload(pagedDb))!;
      expect(result, await _payload(legacyDb));
      expect(result['runs'], hasLength(6));
      expect(result['collectors'], isEmpty);
      expect(result['observations'], isEmpty);
      expect(result['completedClaims'], isEmpty);
      expect(source.reads[ReconciliationSection.observations], isNull);
    },
  );

  test(
    'a source failure after an observation insert rolls back the entire import',
    () async {
      await _completeFixture(sourceDb);
      await _appendRuns(pagedDb, 1);
      final before = await _payload(pagedDb);
      final payload = (await sourceStore.getBySessionId('session'))!;
      final source = _RecordingSource(
        payload,
        failAfter: ReconciliationSection.observations,
      );

      await expectLater(
        pagedStore.mergeFromSource('session', source),
        throwsStateError,
      );

      expect(await _payload(pagedDb), before);
      expect(
        await pagedDb.select(pagedDb.cardEvolutionObservations).get(),
        isEmpty,
      );
      expect(
        await pagedDb.select(pagedDb.cardEvolutionCollectorRuns).get(),
        isEmpty,
      );
      expect(await pagedDb.select(pagedDb.cardEvolutionClaims).get(), isEmpty);
    },
  );

  test(
    'run metadata is capped before normalization or any domain write',
    () async {
      await expectLater(
        pagedStore.mergeFromSource('session', _OverflowSource()),
        throwsFormatException,
      );
      expect(await _payload(pagedDb), isNull);
      expect(await pagedDb.select(pagedDb.lorebookUseManifests).get(), isEmpty);
    },
  );

  test(
    'metadata byte budget applies to direct compatibility imports too',
    () async {
      await expectLater(
        pagedStore.mergeFromSource('session', _WideMetadataSource()),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('byte budget'),
          ),
        ),
      );
      expect(await _payload(pagedDb), isNull);
    },
  );

  test(
    'local preflight budgets failed collectors without exporting them',
    () async {
      await _appendRuns(pagedDb, 1);
      await _appendRuns(sourceDb, 1);
      await _invalidate(sourceDb, 'run-1');
      final incoming = (await sourceStore.getBySessionId('session'))!;
      final detail = 'x' * (25 * 1024 * 1024);
      for (var index = 0; index < 3; index++) {
        await pagedDb
            .into(pagedDb.cardEvolutionCollectorRuns)
            .insert(
              CardEvolutionCollectorRunsCompanion.insert(
                id: 'failed-$index',
                sessionId: 'session',
                characterId: 'character',
                collectorOrdinal: index + 1,
                reconciliationRunId: 'unused-$index',
                reconciliationRunOrdinal: index + 1,
                reconciliationChainHash: 'chain-$index',
                rangeHash: 'range-$index',
                inputHash: 'input-$index',
                ownerId: 'local',
                status: 'failed',
                leaseExpiresAt: 0,
                failureDetail: Value(detail),
                createdAt: 1,
              ),
            );
      }
      final before = await _payload(pagedDb);
      expect(before!['collectors'], isEmpty);
      await expectLater(
        pagedStore.mergeFromSource(
          'session',
          MapReconciliationStateSource(incoming),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('memory budget'),
          ),
        ),
      );
      expect(await _payload(pagedDb), before);
    },
  );

  test(
    'an oversized merged observation rolls back despite valid input records',
    () async {
      await _completeFixture(sourceDb);
      final payload = (await sourceStore.getBySessionId('session'))!;
      await pagedStore.mergeFromSource(
        'session',
        MapReconciliationStateSource(payload),
      );
      final a = 'a' * (8 * 1024 * 1024 + 4096);
      final b = 'b' * (8 * 1024 * 1024 + 4096);
      await (pagedDb.update(pagedDb.cardEvolutionObservations)..where(
            (row) => row.semanticScopeKey.equals('character.personality.trust'),
          ))
          .write(
            CardEvolutionObservationsCompanion(
              evidenceMessageIds: Value(jsonEncode([a])),
              evidenceClustersJson: Value(
                jsonEncode([
                  [a],
                ]),
              ),
            ),
          );
      final before = await _payload(pagedDb);
      final observations = (payload['observations'] as List)
          .cast<Map<String, dynamic>>();
      payload['observations'] = [
        for (final row in observations)
          if (row['semanticScopeKey'] == 'character.personality.trust')
            {
              ...row,
              'evidenceMessageIds': jsonEncode([b]),
              'evidenceClustersJson': jsonEncode([
                [b],
              ]),
            }
          else
            row,
      ];
      await expectLater(
        pagedStore.mergeFromSource(
          'session',
          MapReconciliationStateSource(payload),
        ),
        throwsFormatException,
      );
      expect(await _payload(pagedDb), before);
    },
  );

  test(
    'a stale guard rolls back DB-only derived resets before commit',
    () async {
      await _completeFixture(sourceDb);
      final base = (await sourceStore.getBySessionId('session'))!;
      await pagedStore.mergeFromSource(
        'session',
        MapReconciliationStateSource(base),
      );
      final before = await _payload(pagedDb);
      await _invalidate(sourceDb, 'run-2');
      final invalidated = (await sourceStore.getBySessionId('session'))!;
      await expectLater(
        pagedStore.mergeFromSource('session', _LateStaleSource(invalidated)),
        throwsStateError,
      );
      expect(await _payload(pagedDb), before);
    },
  );
}

class _WideMetadataSource extends MapReconciliationStateSource {
  _WideMetadataSource() : super({'sessionId': 'session', 'schemaVersion': 2});
  @override
  Stream<Map<String, dynamic>> readSection(
    ReconciliationSection section,
  ) async* {
    if (section != ReconciliationSection.runs) return;
    final text = 'x' * (25 * 1024 * 1024);
    for (var index = 0; index < 3; index++) {
      yield {'canonicalResultJson': text};
    }
  }
}

class _LateStaleSource extends MapReconciliationStateSource
    implements ReconciliationSourceGuard {
  _LateStaleSource(super.data);
  bool stale = false;
  @override
  void checkCurrent() {
    if (stale) throw StateError('Old import generation');
  }

  @override
  Stream<Map<String, dynamic>> readSection(
    ReconciliationSection section,
  ) async* {
    yield* super.readSection(section);
    if (section == ReconciliationSection.collectors) {
      unawaited(
        Future<void>.microtask(() {
          stale = true;
        }),
      );
    }
  }
}

class _NoLegacyStore extends ReconciliationStateSyncStore {
  _NoLegacyStore(super.db);

  @override
  Future<Map<String, dynamic>?> getBySessionId(String sessionId) =>
      throw StateError('The scalable path materialized the legacy payload');
}

class _RecordingSource extends MapReconciliationStateSource {
  _RecordingSource(super.data, {this.failAfter});
  final ReconciliationSection? failAfter;
  final reads = <ReconciliationSection, int>{};

  @override
  Stream<Map<String, dynamic>> readSection(
    ReconciliationSection section,
  ) async* {
    reads.update(section, (count) => count + 1, ifAbsent: () => 1);
    await for (final row in super.readSection(section)) {
      yield row;
    }
    if (section == failAfter) {
      throw StateError('Late local snapshot read failure');
    }
  }
}

class _OverflowSource implements ReconciliationStateSource {
  @override
  String get sessionId => 'session';
  @override
  int get schemaVersion => 2;
  @override
  Stream<Map<String, dynamic>> readSection(
    ReconciliationSection section,
  ) async* {
    if (section != ReconciliationSection.runs) return;
    for (var i = 0; i <= ReconciliationJsonCodec.maxRunRows; i++) {
      yield {'ordinal': i + 1};
    }
  }
}

Future<Map<String, dynamic>?> _payload(AppDatabase db) =>
    ReconciliationStateSyncStore(db).getBySessionId('session');

// The same small real-DB fixture pattern as reconciliation_state_sync_store_test:
// append through the production repo, then complete collectors at exact batches.
Future<void> _seedSession(AppDatabase db) => db.customStatement(
  'INSERT INTO chat_sessions (session_id, character_id, session_index, messages_json) '
  'VALUES (?, ?, 0, ?)',
  ['session', 'character', jsonEncode(_messages)],
);

Future<void> _seedProvenance(AppDatabase db) async {
  await db
      .into(db.lorebookUseManifests)
      .insert(
        LorebookUseManifestsCompanion.insert(
          sessionId: 'session',
          messageId: 'opening',
          swipeId: 0,
          agentSwipeId: 0,
          manifestHash: const Value('manifest'),
          createdAt: 1,
        ),
        mode: InsertMode.insertOrIgnore,
      );
  for (final order in [2, 10, 1]) {
    await db
        .into(db.lorebookUseManifestEntries)
        .insert(
          LorebookUseManifestEntriesCompanion.insert(
            sessionId: 'session',
            messageId: 'opening',
            swipeId: 0,
            agentSwipeId: 0,
            lorebookId: 'lorebook',
            entryId: 'entry',
            entryOrder: order,
            evidenceJson: Value(jsonEncode({'order': order})),
          ),
          mode: InsertMode.insertOrIgnore,
        );
  }
  await db
      .into(db.lorebookUseAcceptanceRecords)
      .insert(
        LorebookUseAcceptanceRecordsCompanion.insert(
          acceptanceId: 'z-variation',
          sessionId: 'session',
          messageId: 'opening',
          swipeId: 0,
          agentSwipeId: 0,
          acceptanceKind: 'variation',
          acceptedByUserMessageId: const Value('user'),
          acceptedAt: 1,
        ),
        mode: InsertMode.insertOrIgnore,
      );
  await db
      .into(db.lorebookUseAcceptanceRecords)
      .insert(
        LorebookUseAcceptanceRecordsCompanion.insert(
          acceptanceId: 'a-selection',
          sessionId: 'session',
          messageId: 'opening',
          swipeId: 0,
          agentSwipeId: 0,
          acceptanceKind: 'selection',
          selectedLorebookId: const Value('lorebook'),
          selectedEntryId: const Value('entry'),
          selectedEntryOrder: const Value(1),
          acceptedAt: 2,
        ),
        mode: InsertMode.insertOrIgnore,
      );
}

Future<void> _appendRuns(AppDatabase db, int count) async {
  await _seedProvenance(db);
  final repo = LedgerReconciliationRunRepo(db);
  var predecessor = '';
  for (var ordinal = 1; ordinal <= count; ordinal++) {
    final last = ordinal == 6;
    final run = LedgerReconciliationRun(
      id: 'run-$ordinal',
      sessionId: 'session',
      ordinal: ordinal,
      anchors: [
        ReconciliationAnchor(
          messageId: last ? 'last' : 'opening',
          swipeId: 0,
          agentSwipeId: 0,
          role: 'assistant',
          contentHash: computeHash(last ? 'Last response.' : 'Welcome.'),
        ),
      ],
      acceptedManifestRefs: last
          ? const []
          : const [
              AcceptedManifestRef(
                acceptanceId: 'z-variation',
                sessionId: 'session',
                messageId: 'opening',
                swipeId: 0,
                agentSwipeId: 0,
                manifestHash: 'manifest',
                acceptedByUserMessageId: 'user',
              ),
            ],
      effectiveCanonStamp: 'stamp-$ordinal',
      effectiveCanonRevision: ordinal,
      effectiveCanonHash: 'canon-$ordinal',
      canonicalResult: {
        'facts': ['result-$ordinal'],
      },
      predecessorChainHash: predecessor,
      contractVersion: 1,
      opsApplied: const [],
      createdAt: ordinal,
    );
    expect(await repo.append(run), isA<ReconciliationRunAppended>());
    predecessor = run.chainHash;
  }
}

Future<void> _completeFixture(
  AppDatabase db, {
  bool invalidEffect = false,
}) async {
  await _appendRuns(db, 6);
  final runRepo = LedgerReconciliationRunRepo(db);
  final runs = await runRepo.readSession('session');
  final state = await runRepo.captureState('session');
  for (final run in runs) {
    if (invalidEffect && run.ordinal == 2) {
      await db
          .into(db.ledgerReconciliationEffects)
          .insert(
            LedgerReconciliationEffectsCompanion.insert(
              runId: run.id,
              sessionId: 'session',
              beforeLedgerJson: state.ledgerJson,
              afterLedgerJson: state.ledgerJson,
              beforeKnowledgeJson: state.knowledgeJson,
              afterKnowledgeJson: state.knowledgeJson,
              actualEffectsJson: '{}',
              beforeStateHash: state.hash,
              afterStateHash: state.hash,
              effectsHash: 'tampered',
              createdAt: run.createdAt,
            ),
          );
      continue;
    }
    await runRepo.recordEffect(
      runId: run.id,
      sessionId: 'session',
      before: state,
      after: state,
      createdAt: run.createdAt,
    );
  }
  final collectors = <CardEvolutionCollectorRunRow>[];
  for (var i = 0; i < runs.length; i += collectorReconciliationBatchSize) {
    final batch = CardEvolutionCollectorBatch(
      runs.sublist(i, i + collectorReconciliationBatchSize),
    );
    final repo = CardEvolutionCollectorRunRepo(db);
    final claim = await repo.claim(
      reconciliationRun: batch.boundary,
      characterId: 'character',
      inputHash: 'input-$i',
      ownerId: 'source-owner',
      now: 10 + i,
      leaseSeconds: 30,
      rangeHash: batch.rangeHash,
    );
    expect(
      await repo.complete(
        id: claim.row!.id,
        ownerId: 'source-owner',
        modelOutputHash: 'output-$i',
        now: 11 + i,
      ),
      isTrue,
    );
    collectors.add(
      (await (db.select(
        db.cardEvolutionCollectorRuns,
      )..where((row) => row.id.equals(claim.row!.id))).getSingle()),
    );
  }
  await db
      .into(db.cardEvolutionCollectorRuns)
      .insert(
        CardEvolutionCollectorRunsCompanion.insert(
          id: 'active-collector',
          sessionId: 'session',
          characterId: 'character',
          collectorOrdinal: 3,
          reconciliationRunId: 'future-boundary',
          reconciliationRunOrdinal: 9,
          reconciliationChainHash: 'future-chain',
          rangeHash: 'future-range',
          inputHash: 'future-input',
          ownerId: 'active-owner',
          status: 'claimed',
          leaseExpiresAt: 100,
          createdAt: 20,
        ),
      );
  await db
      .into(db.cardEvolutionObservations)
      .insert(
        CardEvolutionObservationsCompanion.insert(
          id: 'local-observation',
          sessionId: 'session',
          characterId: 'character',
          runOrdinal: 1,
          semanticScopeKey: 'character.personality.trust',
          observedChange: 'Trust increases.',
          canonicalClaim: const Value('Trusts the protagonist.'),
          evidenceMessageIds: '["opening"]',
          evidenceClustersJson: const Value('[["opening"]]'),
          retrievalKeysJson: const Value('["npc:Alice"]'),
          targetKind: const Value('main_character_card'),
          cardFieldPath: const Value('personality'),
          confidence: 0.8,
          status: 'active',
          firstSeenRun: 1,
          createdAt: 10,
          updatedAt: 10,
        ),
      );
  final observation = await db.select(db.cardEvolutionObservations).getSingle();
  for (final scope in [
    'character.personality.\uE000',
    'character.personality.😀',
  ]) {
    await db
        .into(db.cardEvolutionObservations)
        .insert(observation.copyWith(id: scope, semanticScopeKey: scope));
  }
  for (final valid in [true, false]) {
    await db
        .into(db.cardEvolutionClaims)
        .insert(
          CardEvolutionClaimsCompanion.insert(
            id: valid ? 'completed-claim' : 'orphan-claim',
            sessionId: 'session',
            characterId: 'character',
            ownerId: 'source-owner',
            status: 'completed',
            leaseExpiresAt: 123,
            chatHistoryHash: 'history',
            effectiveCanonIdentity: 'canon',
            predecessorCursorHash: valid
                ? collectors.last.reconciliationChainHash
                : 'wrong-boundary',
            predecessorRunOrdinal: collectors.last.collectorOrdinal,
            inputHash: valid ? 'claim-input' : 'orphan-input',
            selectedInputJson: const Value('{"private":true}'),
            writerOptionsJson: const Value('{"private":true}'),
            rewriteJobId: const Value('local-job'),
            createdAt: 12,
            completedAt: const Value(13),
          ),
        );
  }
}

Map<String, dynamic> _invalidation(String runId) => {
  'id': 0,
  'sessionId': 'session',
  'runId': runId,
  'causeMessageId': 'last',
  'reason': 'message_evidence_changed',
  'createdAt': 30,
};

Future<void> _invalidate(AppDatabase db, String runId) => db
    .into(db.ledgerReconciliationRunInvalidations)
    .insert(
      LedgerReconciliationRunInvalidationsCompanion.insert(
        sessionId: 'session',
        runId: runId,
        causeMessageId: 'last',
        reason: 'message_evidence_changed',
        createdAt: 30,
      ),
    );

const _messages = [
  {
    'id': 'opening',
    'role': 'assistant',
    'content': 'Welcome.',
    'swipes': ['Welcome.'],
    'agentSwipes': <Object>[],
  },
  {'id': 'user', 'role': 'user', 'content': 'Begin.'},
  {
    'id': 'last',
    'role': 'assistant',
    'content': 'Last response.',
    'swipes': ['Last response.'],
    'agentSwipes': <Object>[],
  },
  {'id': 'last-user', 'role': 'user', 'content': 'Continue.'},
];
