import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/memory_source_manifest.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/chat_source_mutation_provider.dart';
import 'package:glaze_flutter/core/state/lorebook_embedding_provider.dart';
import 'package:glaze_flutter/core/state/memory_book_ops_provider.dart';
import 'package:glaze_flutter/core/state/memory_settings_provider.dart';
import 'package:glaze_flutter/features/chat/widgets/memory_books_tab.dart';
import 'package:glaze_flutter/features/chat/state/chat_native_owner_registry.dart';
import 'package:glaze_flutter/features/memory/state/memory_draft_jobs_provider.dart';
import 'package:glaze_flutter/features/memory/state/memory_native_entry_owner.dart';
import 'package:glaze_flutter/features/support_assistant/support_assistant_screen.dart';

import 'support_app_domain_loop_fixture.dart';
export 'support_app_domain_loop_fixture.dart';

const draftTextId = 'exact-native-pending-draft';
const draftTextBefore = ' Original draft.\nSecond line. ';
const draftTextAfter = ' Exact edit.\n\nWhitespace stays. ';

Map<String, Object?> draftTextArguments([String content = draftTextAfter]) => {
  'sessionId': DomainLoopFixture.session,
  'draftId': draftTextId,
  'content': content,
};

Future<void> startDraftText(
  WidgetTester tester,
  DomainLoopFixture f, {
  bool confirmation = true,
  bool undo = false,
}) => f.start(
  tester,
  confirmation: confirmation,
  instruction: undo
      ? 'Отмени изменение текста черновика Memory'
      : 'Измени текст черновика Memory',
);

void allowDraftMemory(DomainLoopFixture f) =>
    f.screen.core.isolation.extraAllowed.addAll({
      memoryBookOpsProvider,
      memoryDraftJobsProvider,
      memoryGlobalSettingsProvider,
      pipelineSettingsProvider,
      embeddingRepoProvider,
      vectorSearchAvailableProvider,
    });

Future<void> seedDraftText(
  WidgetTester tester,
  DomainLoopFixture f, {
  String status = 'pending_approval',
  bool vector = false,
  String content = draftTextBefore,
  String Function(String raw)? draftRaw,
}) => configurationAction(tester, () async {
  final c = f.screen.core.container, db = f.screen.core.native.db;
  final session = (await c
      .read(chatRepoProvider)
      .getById(DomainLoopFixture.session))!;
  await c
      .read(memoryBookRepoProvider)
      .put(
        MemoryBook(
          id: 'memorybook_${session.id}',
          sessionId: session.id,
          settings: const MemoryBookSettings(
            autoCreateEnabled: false,
            autoGenerateEnabled: false,
            vectorSearchEnabled: false,
          ),
          entries: const [
            MemoryEntry(
              id: 'approved-untouched',
              content: DomainLoopFixture.private,
            ),
          ],
          pendingDrafts: [
            MemoryDraft(
              id: draftTextId,
              title: 'Selected native draft',
              content: content,
              status: status,
              vectorSearch: vector,
              keys: const ['unchanged-key'],
              keyParagraphs: const {
                'unchanged-key': [0],
              },
              messageIds: [session.messages.first.id],
              sourceManifest: MemorySourceManifest.capture(
                session.id,
                [session.messages.first],
                [session.messages.first.id],
              ),
              error: DomainLoopFixture.private,
              source: 'scan_chat',
              createdAt: 11,
              updatedAt: 12,
              generatedAt: 13,
            ),
            const MemoryDraft(
              id: 'sibling-draft',
              content: DomainLoopFixture.private,
            ),
          ],
          lastProcessedMessageCount: 9,
        ),
      );
  final row = await (db.select(
    db.memoryBookRows,
  )..where((t) => t.sessionId.equals(session.id))).getSingle();
  final drafts = jsonDecode(row.pendingDraftsJson) as List;
  (drafts.first as Map)['unknownDraft'] = {
    'nested': ['preserve', 123],
  };
  (drafts.first as Map)['unknownNumber'] = 123;
  var raw = const JsonEncoder.withIndent('  ').convert(drafts);
  raw = raw.replaceFirst('"unknownNumber": 123', '"unknownNumber": 1.2300e+02');
  if (draftRaw != null) raw = draftRaw(raw);
  await (db.update(db.memoryBookRows)
        ..where((t) => t.sessionId.equals(session.id)))
      .write(MemoryBookRowsCompanion(pendingDraftsJson: Value(raw)));
});

/// Real already-mounted tab in the SAME container; no replacement authority.
Future<OverlayEntry> mountDraftMemory(
  WidgetTester tester,
  DomainLoopFixture f,
) async {
  allowDraftMemory(f);
  final context = tester.element(find.byType(SupportAssistantScreen));
  final overlay = OverlayEntry(
    builder: (_) => const Offstage(
      child: Material(
        child: SizedBox(
          width: 800,
          height: 600,
          child: MemoryBooksTab(
            sessionId: DomainLoopFixture.session,
            charId: DomainLoopFixture.character,
          ),
        ),
      ),
    ),
  );
  Overlay.of(context).insert(overlay);
  await tester.pump();
  for (var n = 0; n < 128; n++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    if (f.screen.core.container
            .read(memoryNativeEntryOwnerRegistryProvider)
            .existing(
              DomainLoopFixture.session,
              originContainer: f.screen.core.container,
            ) !=
        null)
      break;
  }
  expect(find.byType(MemoryBooksTab, skipOffstage: false), findsOneWidget);
  expect(
    ProviderScope.containerOf(
      tester.element(find.byType(MemoryBooksTab, skipOffstage: false)),
      listen: false,
    ),
    same(f.screen.core.container),
  );
  return overlay;
}

Future<void> unmountDraftMemory(WidgetTester tester, OverlayEntry tab) async {
  tab.remove();
  await tester.pump();
  tab.dispose();
}

MemoryNativeEntryOwner draftMemoryOwner(DomainLoopFixture f) => f
    .screen
    .core
    .container
    .read(memoryNativeEntryOwnerRegistryProvider)
    .existing(
      DomainLoopFixture.session,
      originContainer: f.screen.core.container,
    )!;

/// Same actual loaded Memory/chat/source owners as the model fixture. This is
/// observation/native-owner coverage, not a replacement ROOT or policy waiver.
bool Function() draftNativeCurrent(DomainLoopFixture f) {
  final c = f.screen.core.container, owner = draftMemoryOwner(f);
  final chatOwners = c.read(chatNativeOwnerRegistryProvider);
  final chat = chatOwners.existing(DomainLoopFixture.session)!;
  final mutations = c.read(chatSourceMutationRegistryProvider);
  final checkpoint = mutations.sessionCheckpoint(DomainLoopFixture.session);
  final lifetime = owner.captureNativeGuard();
  return () =>
      lifetime() &&
      chatOwners.retains(chat, DomainLoopFixture.session) &&
      !mutations.isSessionPending(DomainLoopFixture.session) &&
      identical(
        mutations.sessionCheckpoint(DomainLoopFixture.session),
        checkpoint,
      );
}

Future<MemoryBookRow> draftTextRow(WidgetTester tester, DomainLoopFixture f) =>
    configurationAction(
      tester,
      () =>
          (f.screen.core.native.db.select(
                f.screen.core.native.db.memoryBookRows,
              )..where((t) => t.sessionId.equals(DomainLoopFixture.session)))
              .getSingle(),
    );

void preservedDraftText(
  MemoryBookRow before,
  MemoryBookRow after,
  String content,
) {
  expect(after.entriesJson, before.entriesJson);
  expect(after.settingsJson, before.settingsJson);
  expect(after.updatedAt, before.updatedAt);
  expect(after.lastProcessedMessageCount, before.lastProcessedMessageCount);
  final original =
      (jsonDecode(before.pendingDraftsJson) as List).first['content'] as String;
  expect(
    after.pendingDraftsJson,
    before.pendingDraftsJson.replaceFirst(
      '"content": ${jsonEncode(original)}',
      '"content": ${jsonEncode(content)}',
    ),
  );
}

Future<void> noDraftJournal(WidgetTester tester, DomainLoopFixture f) async {
  expect(
    await configurationAction(
      tester,
      () => f.screen.core.native.db
          .select(f.screen.core.native.db.supportMutationJournal)
          .get(),
    ),
    isEmpty,
  );
}

void draftNonEgressControls(DomainLoopFixture f) {
  for (final canary in [
    DomainLoopFixture.private,
    f.screen.core.boundSyntheticSecret,
    'SYNTHETIC_HIDDEN_PROMPT',
    'SYNTHETIC_EXCLUDED_BODY',
  ]) {
    expect(() => f.noEgress(canary), throwsA(isA<TestFailure>()));
  }
  f.noEgress();
}
