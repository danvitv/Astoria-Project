import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_raw_tracker_state_reader.dart';
import 'package:glaze_flutter/core/db/repositories/manual_rewrite_job_repo.dart';
import 'package:glaze_flutter/core/db/repositories/rewrite_job_history_sync_repo.dart';

void main() {
  late AppDatabase source;
  late AppDatabase target;
  late RewriteJobHistorySyncRepo sourceHistory;
  late RewriteJobHistorySyncRepo targetHistory;

  setUp(() async {
    source = AppDatabase.forTesting(NativeDatabase.memory());
    target = AppDatabase.forTesting(NativeDatabase.memory());
    sourceHistory = RewriteJobHistorySyncRepo(source);
    targetHistory = RewriteJobHistorySyncRepo(target);
    for (final db in [source, target]) {
      await db.customStatement(
        'INSERT INTO chat_sessions (session_id, character_id, session_index, '
        'messages_json) VALUES (?, ?, 0, ?)',
        ['session', 'character', '[]'],
      );
    }
  });

  tearDown(() async {
    await source.close();
    await target.close();
  });

  test(
    'imports applied history for review, once, without active jobs',
    () async {
      await _seedJob(source, 'applied-job');
      await _seedJob(source, 'pending-job', status: 'pending');
      final payload = (await sourceHistory.getBySessionId('session'))!;

      expect(await sourceHistory.getAllSessionIds(), ['session']);
      expect((payload['jobs'] as List), hasLength(1));
      expect((payload['operations'] as List), hasLength(1));
      expect((payload['revisions'] as List), hasLength(2));
      expect((payload['evidence'] as List), hasLength(1));
      expect((payload['evidence'] as List).single['evidenceJson'], '{}');
      expect(jsonEncode(payload), isNot(contains('private-selected-input')));

      await targetHistory.mergeBySessionId('session', payload);
      await targetHistory.mergeBySessionId('session', payload);

      expect(await targetHistory.getBySessionId('session'), payload);
      final review = await ManualRewriteJobRepo(
        db: target,
        rawTrackerStateReader: LedgerRawTrackerStateReader(target),
      ).watchJob('applied-job').first;
      expect(review?.job.status, 'applied');
      expect(review?.operations.single.currentSnapshotJson, '{"after":true}');
      expect(review?.operations.single.evidenceCount, 1);
      expect(await target.select(target.rewriteJobs).get(), hasLength(1));
    },
  );

  test('union preserves local applied jobs on both sides', () async {
    await _seedJob(source, 'source-job');
    await _seedJob(target, 'target-job');
    final merged = await targetHistory.mergeBySessionId(
      'session',
      (await sourceHistory.getBySessionId('session'))!,
    );
    expect((merged['jobs'] as List), hasLength(2));
    await sourceHistory.mergeBySessionId('session', merged);
    expect(await sourceHistory.getBySessionId('session'), merged);
  });

  test('rejects foreign and active jobs atomically', () async {
    await _seedJob(source, 'source-job');
    final payload = (await sourceHistory.getBySessionId('session'))!;
    final jobs = (payload['jobs'] as List).cast<Map<String, dynamic>>();
    final foreign = {
      ...payload,
      'jobs': [
        {...jobs.single, 'chatSessionId': 'another-session'},
      ],
    };
    await expectLater(
      targetHistory.mergeBySessionId('session', foreign),
      throwsFormatException,
    );
    final pending = {
      ...payload,
      'jobs': [
        {...jobs.single, 'status': 'pending'},
      ],
    };
    await expectLater(
      targetHistory.mergeBySessionId('session', pending),
      throwsFormatException,
    );
    final rawEvidence = {
      ...payload,
      'evidence': [
        {
          ...(payload['evidence'] as List).single as Map<String, dynamic>,
          'evidenceJson': '{"private":"raw chat"}',
        },
      ],
    };
    await expectLater(
      targetHistory.mergeBySessionId('session', rawEvidence),
      throwsFormatException,
    );
    expect(await targetHistory.getBySessionId('session'), isNull);
  });

  test(
    'rejects an incomplete applied snapshot without importing its job',
    () async {
      await _seedJob(source, 'source-job');
      final payload = (await sourceHistory.getBySessionId('session'))!;
      final incomplete = {...payload, 'revisions': <dynamic>[]};

      await expectLater(
        targetHistory.mergeBySessionId('session', incomplete),
        throwsFormatException,
      );
      expect(await targetHistory.getBySessionId('session'), isNull);
    },
  );

  test('empty cloud history cannot erase local applied jobs', () async {
    await _seedJob(target, 'local-job');
    final local = await targetHistory.getBySessionId('session');
    await expectLater(
      targetHistory.mergeBySessionId('session', {
        ...local!,
        'jobs': <dynamic>[],
        'operations': <dynamic>[],
        'revisions': <dynamic>[],
        'evidence': <dynamic>[],
      }),
      throwsFormatException,
    );
    expect(await targetHistory.getBySessionId('session'), local);
  });

  test('collision rolls back all imported jobs and dependencies', () async {
    await _seedJob(source, 'source-job');
    await _seedJob(source, 'conflicting-job');
    await _seedJob(target, 'conflicting-job', requestJson: '{"local":true}');

    await expectLater(
      targetHistory.mergeBySessionId(
        'session',
        (await sourceHistory.getBySessionId('session'))!,
      ),
      throwsStateError,
    );
    expect(
      (await targetHistory.getBySessionId('session'))!['jobs'],
      hasLength(1),
    );
    expect(
      (await target.select(target.rewriteJobs).get()).single.requestJson,
      '{"local":true}',
    );
  });
}

Future<void> _seedJob(
  AppDatabase db,
  String id, {
  String status = 'applied',
  String requestJson = '{}',
}) async {
  await db
      .into(db.rewriteJobs)
      .insert(
        RewriteJobsCompanion.insert(
          id: id,
          chatSessionId: 'session',
          characterId: 'character',
          status: Value(status),
          requestJson: Value(requestJson),
          updatedAt: const Value(10),
        ),
      );
  final operationId = '$id-operation';
  await db
      .into(db.rewriteOperations)
      .insert(
        RewriteOperationsCompanion.insert(
          id: operationId,
          rewriteJobId: id,
          chatSessionId: 'session',
          operationJson: const Value('{"after":true}'),
          status: Value(status == 'applied' ? 'applied' : 'reviewable'),
          currentRevision: const Value(2),
          decision: const Value('approved'),
          validationStatus: const Value('valid'),
        ),
      );
  for (final (number, snapshot) in [
    (1, '{"before":true}'),
    (2, '{"after":true}'),
  ]) {
    await db
        .into(db.rewriteOperationRevisions)
        .insert(
          RewriteOperationRevisionsCompanion.insert(
            rewriteOperationId: operationId,
            revision: number,
            snapshotJson: snapshot,
          ),
        );
  }
  await db
      .into(db.rewriteEvidenceRows)
      .insert(
        RewriteEvidenceRowsCompanion.insert(
          id: '$id-evidence',
          rewriteOperationId: operationId,
          evidenceJson: jsonEncode({'source': 'private-selected-input'}),
        ),
      );
}
