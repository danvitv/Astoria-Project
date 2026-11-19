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
}

List<Map<String, Object?>> _pieces(nav.NavigationResult result) =>
    (result.wire['pieces']! as List<Object?>).cast<Map<String, Object?>>();

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
