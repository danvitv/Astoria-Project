import 'dart:convert';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/state/chat_source_mutation_provider.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/state/chat_native_owner_registry.dart';

import 'memory_setup_native_fixture.dart';

void main() {
  memorySetupTest('actual repository same-settings ABA retires painted approval and retained Undo', (tester, f) async {
    await configurationAction(tester, () async {
      final books = f.domain.screen.core.container.read(memoryBookRepoProvider);
      const original = MemoryBookSettings(enabled: false);
      await books.put(const MemoryBook(id: 'memorybook_domain-character_0',
        sessionId: DomainLoopFixture.session, settings: original));
      final review = (await f.service.prepare(const MemorySetupAnswers(), MemorySetupScope.session))!;
      await books.updateSettings(DomainLoopFixture.session, original.copyWith(enabled: true));
      await books.updateSettings(DomainLoopFixture.session, original);
      expect((await f.service.apply(review)).effect, MemorySetupEffect.refused);
      final fresh = (await f.service.prepare(const MemorySetupAnswers(), MemorySetupScope.session))!;
      final applied = await f.service.apply(fresh);
      expect(applied.effect, MemorySetupEffect.applied);
      final durable = (await books.getBySessionId(DomainLoopFixture.session))!.settings;
      await books.updateSettings(DomainLoopFixture.session, durable.copyWith(enabled: false));
      await books.updateSettings(DomainLoopFixture.session, durable);
      expect(await f.service.prepareUndo(applied.receipt!), isNull);
    });
  });
  memorySetupTest(
    'native session exact plan applies atomically and changed-field Undo preserves later bodies',
    (tester, f) async {
      await configurationAction(tester, () async {
        final c = f.domain.screen.core.container;
        final books = c.read(memoryBookRepoProvider),
            db = f.domain.screen.core.native.db;
        await c.read(chatRepoProvider).put(ChatSession(id: 'wizard-other',
          characterId: DomainLoopFixture.character, sessionIndex: 1));
        const otherBook = MemoryBook(id: 'memorybook_wizard-other',
          sessionId: 'wizard-other', entries: [MemoryEntry(id: 'other-entry', content: 'other body')]);
        await books.put(otherBook);
        final otherBefore = await books.getBySessionId('wizard-other');
        await books.put(
          const MemoryBook(
            id: 'memorybook_domain-character_0',
            sessionId: DomainLoopFixture.session,
            settings: MemoryBookSettings(enabled: false),
            entries: [MemoryEntry(id: 'kept-entry', content: 'kept body')],
            pendingDrafts: [
              MemoryDraft(id: 'kept-draft', content: 'kept draft'),
            ],
          ),
        );
        await db.customStatement(
          r"UPDATE memory_book_rows SET settings_json = json_set(settings_json, '$.unknown', 'private-unknown') WHERE session_id = ?",
          [DomainLoopFixture.session],
        );
        final review = (await f.service.prepare(
          const MemorySetupAnswers(tokens: 1024),
          MemorySetupScope.session,
        ))!;
        final before = jsonEncode(review.before),
            after = jsonEncode(review.after);
        expect(before, isNot(contains('kept body')));
        expect(after, contains('1024'));
        expect(
          () => (review.after['settings'] as Map)['enabled'] = false,
          throwsUnsupportedError,
        );
        final applied = await f.service.apply(review);
        expect(applied.effect, MemorySetupEffect.applied);
        expect(
          (await f.service.apply(review)).effect,
          MemorySetupEffect.refused,
        );
        final durable = (await books.getBySessionId(
          DomainLoopFixture.session,
        ))!;
        expect(durable.entries.single.content, 'kept body');
        expect(durable.pendingDrafts.single.content, 'kept draft');
        expect(
          c.read(chatProvider(DomainLoopFixture.character)).value!.session!.id,
          DomainLoopFixture.session,
        );
        final rows = await db
            .customSelect(
              'SELECT * FROM support_mutation_journal WHERE domain = ?',
              variables: [Variable('memory_setup')],
            )
            .get();
        expect(rows.single.data['status'], 'applied');
        expect(
          rows.single.data['before_ciphertext'].toString(),
          isNot(contains(before)),
        );
        // Synthetic later body-only write; do not involve the older ordinary
        // full-book writer's unrelated unknown-settings normalization.
        await db.customStatement(
          'UPDATE memory_book_rows SET pending_drafts_json = ? WHERE session_id = ?',
          [jsonEncode([
            ...durable.pendingDrafts.map((d) => d.toJson()),
            const MemoryDraft(id: 'later-draft', content: 'later body').toJson(),
          ]), DomainLoopFixture.session],
        );
        final undo = (await f.service.prepareUndo(applied.receipt!))!;
        expect((await f.service.apply(undo)).effect, MemorySetupEffect.undone);
        final restored = (await books.getBySessionId(
          DomainLoopFixture.session,
        ))!;
        expect(restored.settings.enabled, false);
        expect(
          restored.pendingDrafts.map((d) => d.id),
          contains('later-draft'),
        );
        final raw = await db
            .customSelect(
              'SELECT settings_json FROM memory_book_rows WHERE session_id = ?',
              variables: [Variable(DomainLoopFixture.session)],
            )
            .getSingle();
        expect(
          raw.data['settings_json'].toString(),
          contains('private-unknown'),
        );
        expect(await books.getBySessionId('wizard-other'), otherBefore);
      });
    },
  );

  memorySetupTest(
    'exact absence refuses a competing book and new-book Undo never deletes later drafts',
    (tester, f) async {
      await configurationAction(tester, () async {
        final books = f.domain.screen.core.container.read(
          memoryBookRepoProvider,
        );
        final review = (await f.service.prepare(
          const MemorySetupAnswers(),
          MemorySetupScope.session,
        ))!;
        // Raw synthetic competitor exercises final exact-absence SQL admission
        // independently of the repository's native intent ticket.
        await f.domain.screen.core.native.db.customStatement(
          'INSERT INTO memory_book_rows (session_id) VALUES (?)',
          [DomainLoopFixture.session],
        );
        expect(
          (await f.service.apply(review)).effect,
          MemorySetupEffect.conflict,
        );
        await books.deleteBySessionId(DomainLoopFixture.session);
        final fresh = (await f.service.prepare(
          const MemorySetupAnswers(),
          MemorySetupScope.session,
        ))!;
        final applied = await f.service.apply(fresh);
        expect(applied.effect, MemorySetupEffect.applied);
        await books.appendDrafts(DomainLoopFixture.session, const [
          MemoryDraft(id: 'later'),
        ]);
        expect(await f.service.prepareUndo(applied.receipt!), isNull);
        expect(
          (await books.getBySessionId(
            DomainLoopFixture.session,
          ))!.pendingDrafts.single.id,
          'later',
        );
      });
    },
  );

  memorySetupTest(
    'reentrant source intent is not adopted and owner replacement cannot revive approval',
    (tester, f) async {
      await configurationAction(tester, () async {
        final c = f.domain.screen.core.container;
        final sources = c.read(chatSourceMutationRegistryProvider);
        final review = (await f.service.prepare(
          const MemorySetupAnswers(),
          MemorySetupScope.session,
        ))!;
        var reentered = false;
        final stop = sources.subscribe((change) {
          if (!reentered) {
            reentered = true;
            sources.beginMutation(sessionId: DomainLoopFixture.session)();
          }
        });
        expect(
          (await f.service.apply(review)).effect,
          MemorySetupEffect.conflict,
        );
        stop();
        expect(
          await c
              .read(memoryBookRepoProvider)
              .getBySessionId(DomainLoopFixture.session),
          isNull,
        );
        c.invalidate(chatProvider(DomainLoopFixture.character));
        await c.read(chatProvider(DomainLoopFixture.character).future);
        expect(f.service.current, isFalse);
        expect(
          (await f.service.apply(review)).effect,
          MemorySetupEffect.refused,
        );
        expect(c.read(chatNativeOwnerRegistryProvider).loaded, hasLength(1));
      });
    },
  );
}
