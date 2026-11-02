import 'dart:convert';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/application/chat_source_mutation_registry.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/memory_book_repo.dart';
import 'package:glaze_flutter/core/db/repositories/memory_catalog_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/memory_source_manifest.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/state/chat_native_owner_registry.dart';
import 'package:glaze_flutter/features/chat/state/chat_session_write_queue.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_app_action.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/native/support_native_domain_adapter.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/native/support_native_domain_sources.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/session_memory/session_memory_guard.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/session_memory/support_app_memory_adapter.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_service.dart';

import 'helpers/support_automatic_sources_fixture.dart';
import 'app_control/session_memory/session_memory_fixture.dart'
    show SessionMemoryConfirmation;

export 'helpers/support_automatic_sources_fixture.dart';
export 'package:glaze_flutter/features/support_assistant/services/support_model_service.dart';

/// Uses the existing real FILE/model Send fixture, not a fake source grant.
/// Native UI gesture/idle host are synthetic seams; ROOT, consumed custody,
/// original registered native queue, repositories, CAS and rollback are real.
void memoryCatalogSendTest(
  String name,
  Future<void> Function(MemoryCatalogSendFixture) body, {
  bool grant = true,
}) => test(name, () async {
  final f = MemoryCatalogSendFixture();
  await HttpOverrides.runZoned(
    () => IOOverrides.runWithIOOverrides(() async {
      try {
        await f.model.initialize(grant: grant, nativeAdapters: f.initialize);
        await body(f);
      } finally {
        await f.queue.settle();
        f.container?.dispose();
        f.owners.dispose();
        f.mutations.dispose();
        await f.model.close();
      }
    }, f.model.io),
    createHttpClient: (_) => f.model.io.block('HTTP/socket'),
  );
});

final class MemoryCatalogSendFixture {
  static const target = 'catalog-send_0', other = 'catalog-send_1';
  static const body = 'SYNTHETIC_CATALOG_LOCAL_ONLY_BODY';
  final model = AutomaticSourcesFixture();
  final queue = ChatSessionWriteQueue();
  final mutations = ChatSourceMutationRegistry();
  final owners = ChatNativeOwnerRegistry();
  final confirmation = SessionMemoryConfirmation();
  ProviderContainer? container;
  late MemoryCatalogPreparationBook books;
  late MemoryCatalogPreparationChat chats;
  late MemoryCatalogSendObserver catalog;
  late void Function() unregister;
  int refreshed = 0;
  void Function()? afterCatalog;

  Future<List<SupportAppActionAdapter>> initialize() async {
    final n = model.native;
    container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(n.db),
        memoryBookRepoProvider.overrideWith(
          (ref) => MemoryCatalogPreparationBook(n.db, ref),
        ),
      ],
    );
    books =
        container!.read(memoryBookRepoProvider) as MemoryCatalogPreparationBook;
    chats = MemoryCatalogPreparationChat(n.db);
    catalog = MemoryCatalogSendObserver(n.db, () => afterCatalog?.call());
    await CharacterRepo(
      n.db,
    ).put(const Character(id: 'catalog-send', name: 'Synthetic catalog'));
    for (final id in [target, other]) {
      final message = ChatMessage(
        id: '$id-source',
        role: 'user',
        content: body,
      );
      await chats.put(
        ChatSession(
          id: id,
          characterId: 'catalog-send',
          sessionIndex: id == target ? 0 : 1,
          messages: [message],
        ),
      );
      await books.put(
        MemoryBook(
          id: 'memorybook_$id',
          sessionId: id,
          settings: const MemoryBookSettings(
            enabled: false,
            autoCreateEnabled: false,
            autoGenerateEnabled: false,
          ),
          entries: [
            MemoryEntry(
              id: '$id-entry',
              title: body,
              content: '$body\n second paragraph',
              messageIds: [message.id],
              sourceManifest: MemorySourceManifest.capture(
                id,
                [message],
                [message.id],
              ),
              locked: true,
            ),
          ],
          pendingDrafts: const [
            MemoryDraft(
              id: 'retained-draft',
              content: body,
              status: 'pending_approval',
              vectorSearch: true,
            ),
          ],
        ),
      );
      await catalog.rebuildForMemoryBook((await books.getBySessionId(id))!);
      await catalog.updateAbstractText(
        sessionId: id,
        memoryEntryId: '$id-entry',
        abstractText: 'old disposable catalog',
      );
    }
    n.handle.execute(
      "INSERT INTO embeddings (entry_id, source_type, source_id, vectors_blob) VALUES (?, ?, ?, X'01020304')",
      ['$target-entry', 'memory_entry', target],
    );
    n.handle.execute(
      'INSERT INTO memory_entity_rows (id, chat_session_id, memory_entry_id, name) VALUES (?, ?, ?, ?)',
      ['retained-entity', target, '$target-entry', body],
    );
    unregister = owners.register(
      ChatNativeOwner(
        characterId: 'catalog-send',
        sessionId: () => target,
        isIdle: () => true,
        queue: queue,
        refresh: (_, publication, sourceCurrent) async {
          if (!sourceCurrent()) return false;
          refreshed++;
          return sourceCurrent() && queue.isCurrentPublication(publication);
        },
      ),
    );
    catalog.rebuilds = 0;
    return [
      SupportNativeDomainAdapter(
        adapter: SupportAppMemoryAdapter(
          books: books,
          chats: chats,
          catalog: catalog,
          guard: SessionMemoryGuard(mutations),
          isDraftBusy: (_) => false,
          onBookChanged: (_) {},
        ),
        chats: chats,
        sources: SupportNativeDomainSources(
          mutations: mutations,
          owners: owners,
          isOriginalOwnerCurrent: () => n.rootCurrent && n.native.isCurrent,
        ),
      ),
    ];
  }

  Future<SupportModelRunResult> send({bool extraCall = false}) async {
    final start = model.wire.length;
    model.script = (round) => round == start + 1
        ? AutomaticSourcesFixture.calls([
            (
              'catalog-call',
              'astoria_memory_catalog_rebuild',
              {'sessionId': target},
            ),
            if (extraCall)
              (
                'unreachable-call',
                'astoria_memory_settings',
                {'sessionId': target, 'enabled': true},
              ),
          ])
        : AutomaticSourcesFixture.answer();
    final submission = await model.start(
      toolUi: SupportModelToolUiPorts(confirmation: confirmation),
    );
    expect(await submission.accepted, true);
    return submission.finished.timeout(const Duration(seconds: 20));
  }

  int get rebuilds => catalog.rebuilds;
  String raw(String table) {
    const allowed = {
      'memory_book_rows',
      'chat_sessions',
      'memory_catalog_rows',
      'embeddings',
      'memory_entity_rows',
    };
    if (!allowed.contains(table)) throw StateError('Unknown synthetic table');
    return jsonEncode(
      model.native.handle
          .select('SELECT * FROM $table ORDER BY rowid')
          .map((r) => Map<String, Object?>.from(r))
          .toList(),
    );
  }

  void noEgress(String reply) {
    expect('${jsonEncode(model.wire)}$reply', isNot(contains(body)));
    expect(
      '${jsonEncode(model.wire)}$reply',
      isNot(contains(model.native.sourcePath)),
    );
  }
}

final class MemoryCatalogPreparationBook extends MemoryBookRepo {
  MemoryCatalogPreparationBook(AppDatabase db, Ref ref) : super(db, ref);
  int observations = 0;
  @override
  Future<MemoryBookControlObservation?> observeForControl(String sessionId) {
    observations++;
    return super.observeForControl(sessionId);
  }
}

final class MemoryCatalogPreparationChat extends ChatRepo {
  MemoryCatalogPreparationChat(super.db);
  int preparations = 0;
  @override
  Future<ChatSession?> getById(String id) {
    preparations++;
    return super.getById(id);
  }
}

/// Scheduling seam only, after the REAL nested replacement and before the REAL
/// owning MemoryBook transaction's post-write lease check/commit.
final class MemoryCatalogSendObserver extends MemoryCatalogRepo {
  MemoryCatalogSendObserver(super.db, this.after);
  final void Function() after;
  int rebuilds = 0;
  @override
  Future<List<MemoryCatalogRow>> rebuildForMemoryBook(MemoryBook book) async {
    rebuilds++;
    final rows = await super.rebuildForMemoryBook(book);
    after();
    return rows;
  }
}
