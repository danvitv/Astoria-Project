import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/memory_consolidation_job_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_source_text_repo.dart';
import 'package:glaze_flutter/core/llm/transport/native_tool_types.dart';
import 'package:glaze_flutter/core/support/source_navigation.dart' as nav;
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:sqlite3/sqlite3.dart';

import '../credentials/fake_credential_storage.dart';

void main() {
  test('Source4 reads local queue coverage without private job data', () async {
    final scratch = await Directory.systemTemp.createTemp(
      'astoria-memory-source-',
    );
    addTearDown(() => scratch.delete(recursive: true));
    final db = AppDatabase.openedNative(
      sqlite3.open('${scratch.path}/source.db'),
    );
    addTearDown(db.close);
    await db.customStatement(
      '''INSERT INTO characters(char_id,name,hidden)
      VALUES('public-card','Synthetic card',0),('hidden-card','Hidden card',1)''',
    );
    await db.customStatement(
      '''INSERT INTO chat_sessions(session_id,character_id,session_index,messages_json)
      VALUES('private-session','public-card',0,'[]'),('private-hidden-session','hidden-card',0,'[]')''',
    );
    final jobs = MemoryConsolidationJobRepo(db, clock: () => 1700000000);
    Future<MemoryConsolidationJobRow> seed(
      String key,
      String branch, {
      String session = 'private-session',
      String revision = 'private-revision',
    }) => jobs.createOrGet(
      sessionId: session,
      branchId: branch,
      requestKey: key,
      items: [
        MemoryConsolidationJobItemInput(
          memoryEntryId: 'private-entry',
          revisionId: revision,
          fingerprint: 'a' * 64,
          proposedEventId: 'private-proposed-event',
        ),
      ],
    );
    final superseded = await seed('private-first-job', 'private-branch');
    final unmatched = await seed('private-second-job', 'private-other-branch');
    final completed = await seed('private-third-job', 'private-branch');
    final hidden = await seed(
      'private-hidden-job',
      'private-hidden-branch',
      session: 'private-hidden-session',
    );
    for (final job in [superseded, unmatched]) {
      await jobs.cancel(job.id, reason: 'source_context_changed');
    }
    await db.customStatement(
      'UPDATE memory_consolidation_job_item_rows SET status=\'accepted\' WHERE job_id=?',
      [completed.id],
    );
    await db.customStatement(
      '''UPDATE memory_consolidation_job_rows
      SET status='completed', package_draft_json='{"content":"PRIVATE_DRAFT"}',
          last_error='PRIVATE_RAW_ERROR' WHERE id=?''',
      [completed.id],
    );
    expect(await jobs.watchSupersededCancelledJobIds('private-session').first, {
      superseded.id,
    });

    final redactor = SecretRedactor();
    final repo = SupportSourceNavigationRepo(
      boundary: SupportSourceTextRepo(
        db: db,
        cipher: SupportPayloadCipher(
          vault: CredentialVault(
            storage: FakeCredentialStorage(),
            buildChannel: 'synthetic_memory_source',
          ),
        ),
        currentRedactor: () => redactor,
      ),
      isCurrent: () => true,
    );
    final ports = _Ports(repo);
    final engine = nav.SourceNavigationEngine(
      run: nav.RunContext(
        Object(),
        'synthetic-run',
        const nav.Recipient('p', 'c', 'openai', 'm'),
      ),
      repository: repo,
      owner: ports,
      approval: ports,
      projection: ports,
      provenance: ports,
    );
    addTearDown(engine.stop);

    Map<String, Object?>? dataset;
    Object? cursor;
    do {
      final listed = await engine.invoke('astoria_sources_list', {
        'domain': 'applicationData',
        'cursor': ?cursor,
      });
      expect(listed.wire['status'], 'ok');
      final pieces = _pieces(listed);
      final observations = repo.nativeDiscoveryCandidates;
      expect(pieces, hasLength(observations.length));
      for (var i = 0; i < pieces.length; i++) {
        if (repo
                .nativeLabel(observations[i])
                ?.startsWith('Maintenance status:') ==
            true) {
          dataset = pieces[i];
        }
      }
      cursor = listed.wire['nextCursor'];
    } while (dataset == null && cursor != null);
    expect(dataset, isNotNull);
    final source = dataset!['source'];
    final sections = await engine.invoke('astoria_source_contents', {
      'source': source,
    });
    final queue = _pieces(sections).singleWhere(
      (item) => (item['label'] as String).startsWith(
        'Saved Memory consolidation packages',
      ),
    );
    final listed = await engine.invoke('astoria_source_contents', {
      'source': source,
      'section': queue['selector'],
    });
    expect(listed.wire['status'], 'ok');
    expect(_pieces(listed), hasLength(3));
    final byCoverage = <String?, Map<String, Object?>>{};
    for (final job in _pieces(listed)) {
      final result = await engine.invoke('astoria_source_read', {
        'source': source,
        'selector': job['selector'],
      });
      expect(result.wire['status'], 'ok');
      final payload =
          _pieces(result).single['payload']! as Map<String, Object?>;
      byCoverage[payload['cancellationCoverage'] as String?] = payload;
      final encoded = jsonEncode(result.wire);
      expect(
        () => NativeToolResult(
          callId: 'read',
          name: 'astoria_source_read',
          content: {
            'data': {'sourceText': encoded},
          },
        ),
        returnsNormally,
      );
      for (final canary in [
        'PRIVATE_DRAFT',
        'PRIVATE_RAW_ERROR',
        'private-session',
        'private-branch',
        'private-entry',
        'private-revision',
        'private-proposed-event',
        superseded.id,
        unmatched.id,
        completed.id,
        hidden.id,
        'a' * 64,
      ]) {
        expect(encoded, isNot(contains(canary)));
      }
    }
    expect(
      byCoverage.keys,
      unorderedEquals(['superseded', 'not_superseded', 'not_applicable']),
    );
    expect(byCoverage['superseded'], containsPair('jobStatus', 'cancelled'));
    expect(
      byCoverage['not_superseded'],
      containsPair('reasonCode', 'source_context_changed'),
    );
    expect(
      byCoverage['not_applicable'],
      containsPair('jobStatus', 'completed'),
    );
    expect(byCoverage['not_applicable'], containsPair('reasonCode', 'unknown'));
    expect(
      byCoverage['superseded'],
      containsPair('createdAtEpochSeconds', 1700000000),
    );
    expect(
      byCoverage['superseded'],
      containsPair('scope', 'local_saved_queue_only'),
    );

    await db.customStatement(
      'UPDATE memory_consolidation_job_rows SET updated_at=updated_at+1 WHERE id=?',
      [superseded.id],
    );
    final changed = await engine.invoke('astoria_source_read', {
      'source': source,
      'selector': _pieces(listed).first['selector'],
    });
    expect(changed.wire['status'], isNot('ok'));
    expect(jsonEncode(changed.wire), isNot(contains('cancellationCoverage')));
  });

  test('Source4 reads bounded Memory event sync metadata without prose', () async {
    final scratch = await Directory.systemTemp.createTemp(
      'astoria-memory-event-source-',
    );
    addTearDown(() => scratch.delete(recursive: true));
    final db = AppDatabase.openedNative(
      sqlite3.open('${scratch.path}/source.db'),
    );
    addTearDown(db.close);
    await db.customStatement(
      "INSERT INTO characters(char_id,name,hidden) VALUES('card','Card',0)",
    );
    await db.customStatement(
      "INSERT INTO chat_sessions(session_id,character_id,session_index,messages_json) VALUES('private-session','card',0,'[]')",
    );
    await db.customStatement('''INSERT INTO memory_event_rows
      (id,session_id,branch_id,kind,description,state,status,revision,
       accepted_at,accepted_by,created_at)
      VALUES
      ('private-event-a','private-session','private-session','promise',
       'PRIVATE_EVENT_PROSE_A','open','active',2,1700000000000,
       'PRIVATE_ACCEPTOR',1700000000000),
      ('private-event-b','private-session','private-session','result',
       'PRIVATE_EVENT_PROSE_B','completed','active',1,1700000010,
       'user',1700000010)''');
    for (final suffix in ['a', 'b']) {
      await db.customStatement(
        '''INSERT INTO memory_event_source_rows
        (id,event_id,session_id,branch_id,memory_entry_id,revision_id,
         fingerprint,source_manifest_json,message_ids_json)
        VALUES(?,?,?,?,?,?,?,?,?)''',
        [
          'private-source-$suffix',
          'private-event-$suffix',
          'private-session',
          'private-session',
          'private-entry-$suffix',
          'private-revision-$suffix',
          suffix * 64,
          jsonEncode({
            'version': 1,
            'originSessionId': 'private-session',
            'messages': [
              {
                'messageId': 'private-message-$suffix',
                'swipeId': 0,
                'agentSwipeId': 0,
                'contentHash': 'c' * 64,
              },
            ],
            'invalidated': false,
            'privateCanary': 'PRIVATE_SOURCE_MANIFEST',
          }),
          '["private-message-$suffix"]',
        ],
      );
    }
    await db.customStatement(
      '''INSERT INTO memory_event_link_rows
      (id,session_id,branch_id,from_event_id,to_event_id,relation,status,
       revision,accepted_at) VALUES(?,?,?,?,?,'fulfills','active',1,1700000010)''',
      [
        'private-link',
        'private-session',
        'private-session',
        'private-event-a',
        'private-event-b',
      ],
    );
    await db.customStatement(
      '''INSERT INTO memory_event_invalidation_rows
      (session_id,branch_id,target_type,target_id,cause_memory_entry_id,
       reason,created_at) VALUES(?,?,'event',?,?,?,1700000020)''',
      [
        'private-session',
        'private-session',
        'private-event-a',
        'private-entry-a',
        'PRIVATE_INVALIDATION_REASON',
      ],
    );

    final redactor = SecretRedactor();
    final repo = SupportSourceNavigationRepo(
      boundary: SupportSourceTextRepo(
        db: db,
        cipher: SupportPayloadCipher(
          vault: CredentialVault(
            storage: FakeCredentialStorage(),
            buildChannel: 'synthetic_memory_event_source',
          ),
        ),
        currentRedactor: () => redactor,
      ),
      isCurrent: () => true,
    );
    final ports = _Ports(repo);
    final engine = nav.SourceNavigationEngine(
      run: nav.RunContext(
        Object(),
        'synthetic-event-run',
        const nav.Recipient('p', 'c', 'openai', 'm'),
      ),
      repository: repo,
      owner: ports,
      approval: ports,
      projection: ports,
      provenance: ports,
    );
    addTearDown(engine.stop);

    final dataset = await _dataset(engine, repo, 'memoryEventRegistryStatus');
    final source = dataset['source'];
    final sections = await engine.invoke('astoria_source_contents', {
      'source': source,
    });
    final section = _pieces(sections).singleWhere(
      (item) => (item['label'] as String).startsWith(
        'Accepted event sync participation',
      ),
    );
    final records = await engine.invoke('astoria_source_contents', {
      'source': source,
      'section': section['selector'],
    });
    expect(_pieces(records), hasLength(2));
    final payloads = <Map<String, Object?>>[];
    for (final record in _pieces(records)) {
      final read = await engine.invoke('astoria_source_read', {
        'source': source,
        'selector': record['selector'],
      });
      expect(read.wire['status'], 'ok');
      final payload = _pieces(read).single['payload']! as Map<String, Object?>;
      payloads.add(payload);
      final encoded = jsonEncode(read.wire);
      expect(
        () => NativeToolResult(
          callId: 'read',
          name: 'astoria_source_read',
          content: {
            'data': {'sourceText': encoded},
          },
        ),
        returnsNormally,
      );
      for (final canary in [
        'PRIVATE_',
        'private-session',
        'private-event',
        'private-source',
        'private-entry',
        'private-revision',
        'private-message',
        'private-link',
        'a' * 64,
        'b' * 64,
        'c' * 64,
      ]) {
        expect(encoded, isNot(contains(canary)));
      }
    }
    final promise = payloads.singleWhere(
      (payload) => payload['eventKind'] == 'promise',
    );
    expect(promise, containsPair('acceptedAtEpochSeconds', 1700000000));
    expect(promise, containsPair('createdAtEpochSeconds', 1700000000));
    expect(promise, containsPair('sourceCount', 1));
    expect(promise, containsPair('linkCount', 1));
    expect(promise, containsPair('invalidationCount', 1));
    expect(
      promise,
      containsPair(
        'syncParticipation',
        'included_in_local_session_registry_aggregate',
      ),
    );
    expect(promise, containsPair('cloudPresence', 'unknown_not_attested'));
    expect(promise, containsPair('collisionObserved', 'unknown_not_persisted'));
    expect(
      promise,
      containsPair(
        'collisionPolicy',
        'semantic_and_exact_source_variants_preserved',
      ),
    );

    await db.customStatement(
      "UPDATE memory_event_rows SET revision=revision+1 WHERE id='private-event-a'",
    );
    final stale = await engine.invoke('astoria_source_read', {
      'source': source,
      'selector': _pieces(records).first['selector'],
    });
    expect(stale.wire['status'], isNot('ok'));
    expect(jsonEncode(stale.wire), isNot(contains('syncParticipation')));
  });
}

List<Map<String, Object?>> _pieces(nav.NavigationResult result) =>
    (result.wire['pieces']! as List<Object?>).cast<Map<String, Object?>>();

Future<Map<String, Object?>> _dataset(
  nav.SourceNavigationEngine engine,
  SupportSourceNavigationRepo repo,
  String labelPrefix,
) async {
  Object? cursor;
  do {
    final listed = await engine.invoke('astoria_sources_list', {
      'domain': 'applicationData',
      'cursor': ?cursor,
    });
    expect(
      listed.wire['status'],
      'ok',
      reason:
          'cursor=$cursor candidates=${repo.nativeDiscoveryCandidates.map((item) => item.key.nativeId).join(',')}',
    );
    final pieces = _pieces(listed);
    final observations = repo.nativeDiscoveryCandidates;
    expect(pieces, hasLength(observations.length));
    for (var i = 0; i < pieces.length; i++) {
      if (observations[i].key.nativeId == labelPrefix ||
          repo.nativeLabel(observations[i])?.startsWith(labelPrefix) == true) {
        return pieces[i];
      }
    }
    cursor = listed.wire['nextCursor'];
  } while (cursor != null);
  throw TestFailure('Application dataset not found: $labelPrefix');
}

// Model transport is synthetic; the engine, SQLite reader, selectors and
// revalidation are the real Source4 path. No permissions or stores are opened.
final class _Ports
    implements
        nav.OwnerPort,
        nav.ApprovalPort,
        nav.ApprovalLease,
        nav.ProjectionPort,
        nav.ProvenancePort {
  _Ports(this.repo);
  final SupportSourceNavigationRepo repo;
  static const _stamp = nav.ProjectionStamp('synthetic-projection', 0);

  @override
  bool isOriginalOwnerCurrent(nav.RunContext run) => true;
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
  @override
  Future<nav.ProjectedRecord> project(nav.DataRecord record) async =>
      nav.ProjectedRecord(record.payload, _stamp);
  @override
  Future<nav.ProjectionStamp> currentStamp() async => _stamp;
  @override
  Future<nav.ProjectedWire> wire(nav.WireCandidate candidate) async =>
      nav.ProjectedWire(candidate, candidate.wire, _stamp);
  @override
  Future<nav.ProvenanceReceipt> append(nav.ProvenanceEntry entry) async =>
      nav.ProvenanceReceipt(
        entry,
        durableEncrypted: repo.privateDigestFor(entry) != null,
      );
}
