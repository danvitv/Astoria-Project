import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/db/repositories/character_revision_repo.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/features/memory/state/memory_book_revision_provider.dart';

import 'session_memory_fixture.dart';

void main() {
  sessionMemoryTest(
    'typed persisted session inspection has stable IDs, no body, no hydration',
    (f) async {
      final before = await f.raw('chat_sessions');
      final result = await f.call('astoria_roleplay_inspect', {
        'sessionId': SessionMemoryFixture.target,
        'view': 'messages',
      });
      expect(result.content['code'], 'completed');
      final data = result.content['data']! as Map;
      final messages = data['messages']! as List;
      expect((messages[0] as Map)['messageId'], 'msg-a');
      expect((messages[1] as Map)['messageId'], 'msg-b');
      expect((messages[1] as Map)['swipeId'], 1);
      expect((messages[1] as Map)['swipeCount'], 2);
      expect(
        jsonEncode(result.content),
        isNot(contains(SessionMemoryFixture.bodyCanary)),
      );
      expect(await f.raw('chat_sessions'), before);
      expect(f.confirmation.last, isNull);
    },
  );

  sessionMemoryTest(
    'native exact confirmation creates only an empty target book with paid automation off',
    (f) async {
      final chatsBefore = await f.raw('chat_sessions');
      final result = await f.call('astoria_memory_create', {
        'sessionId': SessionMemoryFixture.target,
        'enabled': true,
      });
      expect(result.content['code'], 'completed');
      expect(result.content['effect'], 'persisted');
      final request = f.confirmation.last!;
      expect(request.action, 'astoria_memory_create');
      expect(request.target, SessionMemoryFixture.target);
      expect(request.arguments, {
        'sessionId': SessionMemoryFixture.target,
        'enabled': true,
      });
      expect(request.preview['automation'], false);
      final book = (await f.books.getBySessionId(SessionMemoryFixture.target))!;
      expect(book.settings.enabled, true);
      expect(book.settings.autoCreateEnabled, false);
      expect(book.settings.autoGenerateEnabled, false);
      expect(book.settings.vectorSearchEnabled, false);
      expect(book.entries, isEmpty);
      expect(book.pendingDrafts, isEmpty);
      expect(await f.books.getBySessionId(SessionMemoryFixture.other), isNull);
      expect(await f.raw('chat_sessions'), chatsBefore);
      final repeated = await f.call('astoria_memory_create', {
        'sessionId': SessionMemoryFixture.target,
        'enabled': false,
      });
      expect(repeated.content['code'], 'noChange');
      expect(
        (await f.books.getBySessionId(
          SessionMemoryFixture.target,
        ))!.settings.enabled,
        true,
      );
    },
  );

  sessionMemoryTest(
    'confirmed scalar patch preserves body/history, unknown settings and independent book',
    (f) async {
      await f.seedBooks();
      final before = (await f.books.getBySessionId(
        SessionMemoryFixture.target,
      ))!;
      final other = await f.books.getBySessionId(SessionMemoryFixture.other);
      final chatsBefore = await f.raw('chat_sessions');
      final rawRow =
          await (f.db.select(f.db.memoryBookRows)
                ..where((r) => r.sessionId.equals(SessionMemoryFixture.target)))
              .getSingle();
      final settings = jsonDecode(rawRow.settingsJson) as Map<String, dynamic>;
      settings['futurePrivateBinding'] = SessionMemoryFixture.bodyCanary;
      await (f.db.update(
        f.db.memoryBookRows,
      )..where((r) => r.sessionId.equals(SessionMemoryFixture.target))).write(
        MemoryBookRowsCompanion(settingsJson: Value(jsonEncode(settings))),
      );
      final result = await f.call('astoria_memory_settings', {
        'sessionId': SessionMemoryFixture.target,
        'enabled': true,
        'maxInjectedEntries': 11,
        'memoryPackingMode': 'full',
      });
      expect(result.content['code'], 'completed');
      expect(result.content['effect'], 'persisted');
      expect(f.container.read(memoryBookRevisionProvider), 1);
      final after = (await f.books.getBySessionId(
        SessionMemoryFixture.target,
      ))!;
      expect(after.settings.enabled, true);
      expect(after.settings.maxInjectedEntries, 11);
      expect(after.settings.promptPreset, SessionMemoryFixture.bodyCanary);
      expect(after.settings.autoGenerateEnabled, true);
      expect(after.entries, before.entries);
      expect(after.pendingDrafts, before.pendingDrafts);
      expect(await f.books.getBySessionId(SessionMemoryFixture.other), other);
      final persisted =
          await (f.db.select(f.db.memoryBookRows)
                ..where((r) => r.sessionId.equals(SessionMemoryFixture.target)))
              .getSingle();
      expect(
        (jsonDecode(persisted.settingsJson) as Map)['futurePrivateBinding'],
        SessionMemoryFixture.bodyCanary,
      );
      expect(await f.raw('chat_sessions'), chatsBefore);
      expect(
        jsonEncode(f.confirmation.last!.preview),
        isNot(contains(SessionMemoryFixture.bodyCanary)),
      );
    },
  );

  sessionMemoryTest(
    'idle draft vector control writes exact ID only and preserves text/provenance/history',
    (f) async {
      await f.seedBooks();
      final before = (await f.books.getBySessionId(
        SessionMemoryFixture.target,
      ))!;
      final other = await f.books.getBySessionId(SessionMemoryFixture.other);
      final result = await f.call('astoria_memory_draft_vector', {
        'sessionId': SessionMemoryFixture.target,
        'draftId': 'draft-a',
        'vectorSearch': true,
      });
      expect(result.content['code'], 'completed');
      expect(f.confirmation.last!.preview['draftId'], 'draft-a');
      final after = (await f.books.getBySessionId(
        SessionMemoryFixture.target,
      ))!;
      expect(
        after.pendingDrafts.single,
        before.pendingDrafts.single.copyWith(vectorSearch: true),
      );
      expect(after.entries, before.entries);
      expect(await f.books.getBySessionId(SessionMemoryFixture.other), other);
      final inspect = await f.call('astoria_memory_inspect', {
        'sessionId': SessionMemoryFixture.target,
        'view': 'drafts',
      });
      expect(inspect.content['code'], 'completed');
      expect(
        jsonEncode(inspect.content),
        isNot(contains(SessionMemoryFixture.bodyCanary)),
      );
    },
  );

  sessionMemoryTest(
    'local catalog requires original source lease and exact native confirmation',
    (f) async {
      await f.seedBooks();
      final catalog = f.container.read(memoryCatalogRepoProvider);
      await catalog.rebuildForMemoryBook(
        (await f.books.getBySessionId(SessionMemoryFixture.other))!,
      );
      final otherBefore = await catalog.getBySessionId(
        SessionMemoryFixture.other,
      );
      final noLease = await f.call('astoria_memory_catalog_rebuild', {
        'sessionId': SessionMemoryFixture.target,
      });
      expect(noLease.content['code'], 'unavailable');
      expect(
        await catalog.getBySessionId(SessionMemoryFixture.target),
        isEmpty,
      );
      final bookBefore = await f.books.getBySessionId(
        SessionMemoryFixture.target,
      );
      final withLease = await f.call('astoria_memory_catalog_rebuild', {
        'sessionId': SessionMemoryFixture.target,
      }, original: f.context(sourceLease: true));
      expect(withLease.content['code'], 'completed');
      expect(withLease.content['effect'], 'persisted');
      expect(f.source.observation, same(f.confirmation.last!.observation));
      expect(f.source.releases, 1);
      final rows = await catalog.getBySessionId(SessionMemoryFixture.target);
      expect(rows.single.memoryEntryId, 'entry-a');
      expect(rows.single.chatSessionId, SessionMemoryFixture.target);
      expect(rows.single.abstractText, SessionMemoryFixture.bodyCanary);
      expect(
        await catalog.getBySessionId(SessionMemoryFixture.other),
        otherBefore,
      );
      expect(
        await f.books.getBySessionId(SessionMemoryFixture.target),
        bookBefore,
      );
      expect(await f.raw('embeddings'), '[]');
      expect(await f.raw('memory_entity_rows'), '[]');
      expect(
        jsonEncode(withLease.content),
        isNot(contains(SessionMemoryFixture.bodyCanary)),
      );
    },
  );

  sessionMemoryTest(
    'canon validation uses actual reads without lineage writes or source fingerprints',
    (f) async {
      final before = await f.raw('character_revision_rows');
      final result = await f.call('astoria_canon_validate', {
        'sessionId': SessionMemoryFixture.target,
      });
      expect(result.content['code'], 'completed');
      expect((result.content['data']! as Map)['status'], 'assembled');
      expect(await f.raw('character_revision_rows'), before);
      expect(await f.raw('session_canon_checkpoint_rows'), '[]');
      expect(await f.raw('tracker_snapshots'), '[]');
      expect(
        jsonEncode(result.content),
        isNot(contains(SessionMemoryFixture.bodyCanary)),
      );
    },
  );

  sessionMemoryTest(
    'memory control preserves populated committed canon and immutable history',
    (f) async {
      await f.seedBooks();
      final character = (await f.container
          .read(characterRepoProvider)
          .getById('char-a'))!;
      await f.container
          .read(characterRevisionRepoProvider)
          .insert(
            CharacterRevisionRecord(
              characterId: character.id,
              revision: 1,
              revisionHash: 'fixture-lineage-hash',
              parentRevisionHash: '',
              snapshotJson: jsonEncode(character.toJson()),
              createdAt: 1,
            ),
          );
      await f.db.transaction(
        () => f.container
            .read(sessionCanonCheckpointRepoProvider)
            .appendRootInTransaction(
              sessionId: SessionMemoryFixture.target,
              characterId: character.id,
              characterRevision: 1,
              characterRevisionHash: 'fixture-lineage-hash',
            ),
      );
      await f.container
          .read(trackerSnapshotRepoProvider)
          .upsertTrackers(
            sessionId: SessionMemoryFixture.target,
            messageId: 'msg-b',
            swipeId: 1,
            agentSwipeId: 0,
            committed: true,
            trackers: const [
              Tracker(
                sessionId: SessionMemoryFixture.target,
                name: 'world:private',
                value: SessionMemoryFixture.bodyCanary,
                scope: 'ledger',
              ),
            ],
          );
      final checkpointBefore = await f.raw('session_canon_checkpoint_rows');
      final revisionsBefore = await f.raw('character_revision_rows');
      final snapshotsBefore = await f.raw('tracker_snapshots');
      expect(
        (await f.call('astoria_memory_settings', {
          'sessionId': SessionMemoryFixture.target,
          'enabled': true,
        })).content['code'],
        'completed',
      );
      expect(await f.raw('session_canon_checkpoint_rows'), checkpointBefore);
      expect(await f.raw('character_revision_rows'), revisionsBefore);
      expect(await f.raw('tracker_snapshots'), snapshotsBefore);
      final diagnostics = await f.call('astoria_session_diagnostics', {
        'sessionId': SessionMemoryFixture.target,
        'view': 'checkpoints',
      });
      expect(diagnostics.content['code'], 'completed');
      expect((diagnostics.content['data']! as Map)['canonCheckpointCount'], 1);
      expect(
        jsonEncode(diagnostics.content),
        isNot(contains('fixture-lineage-hash')),
      );
    },
  );

  sessionMemoryTest(
    'actual capture/event diagnostics are bounded counts not request bodies',
    (f) async {
      // Synthetic row seed, not live transport; adapters use the owning repo.
      await f.db
          .into(f.db.llmRequestCaptureRows)
          .insert(
            LlmRequestCaptureRowsCompanion.insert(
              sequence: 1,
              sessionId: const Value(SessionMemoryFixture.target),
              stage: const Value('private-stage'),
              eventJson: SessionMemoryFixture.bodyCanary,
              truncated: false,
              createdAtMs: 10,
            ),
          );
      final before = await f.raw('llm_request_capture_rows');
      final result = await f.call('astoria_session_diagnostics', {
        'sessionId': SessionMemoryFixture.target,
        'view': 'requests',
      });
      expect(result.content['code'], 'completed');
      expect((result.content['data']! as Map)['captureSampleCount'], 1);
      expect(
        jsonEncode(result.content),
        isNot(contains(SessionMemoryFixture.bodyCanary)),
      );
      expect(jsonEncode(result.content), isNot(contains('private-stage')));
      expect(await f.raw('llm_request_capture_rows'), before);
    },
  );
}
