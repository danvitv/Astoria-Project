import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/state/chat_source_mutation_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/memory/state/memory_active_drafts_provider.dart';

import 'session_memory_fixture.dart';

void main() {
  sessionMemoryTest(
    'unknown arguments, body fields and unsupported session mutation have no effect',
    (f) async {
      await f.seedBooks();
      final before = await f.raw('memory_book_rows');
      for (final args in <Map<String, Object?>>[
        {
          'sessionId': SessionMemoryFixture.target,
          'enabled': true,
          'unexpected': true,
        },
        {
          'sessionId': SessionMemoryFixture.target,
          'content': 'multiline\nBODY',
        },
        {'sessionId': SessionMemoryFixture.target, 'enabled': 'true'},
        {'sessionId': SessionMemoryFixture.target, 'maxInjectedEntries': -1},
        {'sessionId': SessionMemoryFixture.target},
      ]) {
        final result = await f.call('astoria_memory_settings', args);
        expect(result.content['code'], 'invalidArguments');
        expect(result.content['effect'], 'none');
      }
      for (final name in [
        'astoria_roleplay_delete',
        'astoria_roleplay_branch',
        'astoria_message_edit',
        'astoria_memory_draft_generate',
      ]) {
        expect(
          (await f.call(name, {
            'sessionId': SessionMemoryFixture.target,
          })).content['code'],
          'unknownAction',
        );
      }
      expect(f.registry.definitions.length, 8);
      expect(await f.raw('memory_book_rows'), before);
      expect(f.confirmation.last, isNull);
    },
  );

  sessionMemoryTest(
    'missing native confirmation, rejection and expired native UI never write',
    (f) async {
      await f.seedBooks();
      final before = await f.raw('memory_book_rows');
      final args = {'sessionId': SessionMemoryFixture.target, 'enabled': true};
      final missing = await f.call(
        'astoria_memory_settings',
        args,
        original: f.context(confirm: false),
      );
      expect(missing.content['code'], 'unavailable');
      f.confirmation.accept = false;
      expect(
        (await f.call('astoria_memory_settings', args)).content['code'],
        'denied',
      );
      f.confirmation.accept = true;
      f.confirmation.uiCurrent = false;
      expect(
        (await f.call('astoria_memory_settings', args)).content['code'],
        'denied',
      );
      expect(await f.raw('memory_book_rows'), before);
    },
  );

  sessionMemoryTest(
    'rooted writes remain unavailable without a genuine memory terminal owner',
    (f) async {
      await f.seedBooks();
      final before = await f.raw('memory_book_rows');
      final root = SessionMemoryTerminalRoot();
      final result = await f.call('astoria_memory_settings', {
        'sessionId': SessionMemoryFixture.target,
        'enabled': true,
      }, original: f.context(terminal: root));
      expect(result.content['code'], 'unavailable');
      expect(result.content['effect'], 'none');
      expect(root.admissions, 0);
      expect(f.confirmation.last, isNull);
      expect(await f.raw('memory_book_rows'), before);
    },
  );

  sessionMemoryTest(
    'a native gesture retained from another exact plan is not transferable',
    (f) async {
      await f.seedBooks();
      f.confirmation.accept = false;
      await f.call('astoria_memory_settings', {
        'sessionId': SessionMemoryFixture.other,
        'enabled': true,
      });
      f.confirmation.replacement = f.confirmation.last;
      f.confirmation.accept = true;
      final before = await f.raw('memory_book_rows');
      final result = await f.call('astoria_memory_settings', {
        'sessionId': SessionMemoryFixture.target,
        'enabled': true,
      });
      expect(result.content['code'], 'denied');
      expect(await f.raw('memory_book_rows'), before);
    },
  );

  sessionMemoryTest(
    'source mutation begun and settled during native review retires the original plan',
    (f) async {
      await f.seedBooks();
      final before = await f.raw('memory_book_rows');
      final mutations = f.container.read(chatSourceMutationRegistryProvider);
      f.confirmation.beforeDecision = (_) async {
        final settle = mutations.beginMutation(
          sessionId: SessionMemoryFixture.target,
          messageIds: {'msg-b'},
        );
        settle(); // Does not resurrect the checkpoint taken before the dialog.
      };
      final result = await f.call('astoria_memory_settings', {
        'sessionId': SessionMemoryFixture.target,
        'enabled': true,
      });
      expect(result.content['code'], 'denied');
      expect(result.content['effect'], 'none');
      expect(await f.raw('memory_book_rows'), before);
    },
  );

  sessionMemoryTest(
    'Stop during queued preparation prevents the real repository write',
    (f) async {
      await f.seedBooks();
      final barrier = SessionMemoryBarrier();
      f.books.beforePatch = barrier;
      final before = await f.raw('memory_book_rows');
      final pending = f.call('astoria_memory_settings', {
        'sessionId': SessionMemoryFixture.target,
        'enabled': true,
      });
      await barrier.waitForEntry(pending);
      f.cancel.cancel();
      barrier.release.complete();
      final result = await pending;
      expect(result.content['code'], 'cancelled');
      expect(result.content['effect'], 'none');
      expect(await f.raw('memory_book_rows'), before);
    },
  );

  sessionMemoryTest(
    'queued head/source mutation invalidates exact plan without altering another book',
    (f) async {
      await f.seedBooks();
      final barrier = SessionMemoryBarrier();
      f.books.beforePatch = barrier;
      final before = await f.raw('memory_book_rows');
      final pending = f.call('astoria_memory_settings', {
        'sessionId': SessionMemoryFixture.target,
        'enabled': true,
      });
      await barrier.waitForEntry(pending);
      final settle = f.container
          .read(chatSourceMutationRegistryProvider)
          .beginMutation(sessionId: SessionMemoryFixture.target);
      try {
        await f.chats.mutateMessage(
          sessionId: SessionMemoryFixture.target,
          messageId: 'msg-b',
          updatedAt: 12,
          mutate: (m) => m.copyWith(content: 'NEW_SYNTHETIC_OWNED_HEAD'),
        );
      } finally {
        settle();
      }
      barrier.release.complete();
      final result = await pending;
      expect(result.content['code'], 'stale');
      expect(result.content['effect'], 'none');
      expect(await f.raw('memory_book_rows'), before);
    },
  );

  sessionMemoryTest(
    'exact raw row CAS refuses a draft change during native confirmation',
    (f) async {
      await f.seedBooks();
      f.confirmation.beforeDecision = (_) async {
        await f.books.mutateDraft(
          sessionId: SessionMemoryFixture.target,
          draftId: 'draft-a',
          mutate: (d) => d.copyWith(content: 'NEW_PRIVATE_DRAFT'),
        );
      };
      final result = await f.call('astoria_memory_settings', {
        'sessionId': SessionMemoryFixture.target,
        'enabled': true,
      });
      expect(result.content['code'], 'conflict');
      expect(result.content['effect'], 'none');
      final book = (await f.books.getBySessionId(SessionMemoryFixture.target))!;
      expect(book.pendingDrafts.single.content, 'NEW_PRIVATE_DRAFT');
      expect(book.settings.enabled, false);
      expect(jsonEncode(result.content), isNot(contains('NEW_PRIVATE_DRAFT')));
    },
  );

  sessionMemoryTest(
    'a known persisted target effect survives Stop after native DB dispatch',
    (f) async {
      await f.seedBooks();
      f.books.afterPatch = () => f.cancel.cancel();
      final result = await f.call('astoria_memory_settings', {
        'sessionId': SessionMemoryFixture.target,
        'enabled': true,
      });
      expect(result.content['code'], 'cancelled');
      expect(result.content['effect'], 'persisted');
      expect(
        (await f.books.getBySessionId(
          SessionMemoryFixture.target,
        ))!.settings.enabled,
        true,
      );
      final after = await f.raw('memory_book_rows');
      expect(
        (await f.call('astoria_memory_settings', {
          'sessionId': SessionMemoryFixture.other,
          'enabled': true,
        })).content['code'],
        'cancelled',
      );
      expect(await f.raw('memory_book_rows'), after);
    },
  );

  sessionMemoryTest(
    'draft lease ownership and unknown stable draft ID refuse no-op substitutions',
    (f) async {
      await f.seedBooks();
      final lease = f.container
          .read(memoryActiveDraftsProvider.notifier)
          .acquire(SessionMemoryFixture.target);
      final before = await f.raw('memory_book_rows');
      try {
        expect(
          (await f.call('astoria_memory_draft_vector', {
            'sessionId': SessionMemoryFixture.target,
            'draftId': 'draft-a',
            'vectorSearch': true,
          })).content['code'],
          'unavailable',
        );
      } finally {
        lease.release();
      }
      expect(
        (await f.call('astoria_memory_draft_vector', {
          'sessionId': SessionMemoryFixture.target,
          'draftId': 'missing',
          'vectorSearch': true,
        })).content['code'],
        'unavailable',
      );
      expect(await f.raw('memory_book_rows'), before);
    },
  );

  sessionMemoryTest(
    'catalog lease cancellation cannot start paid work or publish source text',
    (f) async {
      await f.seedBooks();
      final before = await f.raw('memory_catalog_rows');
      f.source.beforeAcquire = () async {
        f.source.current = false;
      };
      final result = await f.call('astoria_memory_catalog_rebuild', {
        'sessionId': SessionMemoryFixture.target,
      }, original: f.context(sourceLease: true));
      expect(result.content['code'], 'stale');
      expect(result.content['effect'], 'none');
      expect(f.source.releases, 1);
      expect(await f.raw('memory_catalog_rows'), before);
    },
  );

  sessionMemoryTest(
    'source retirement after actual catalog writes rolls back the derived transaction',
    (f) async {
      await f.seedBooks();
      final before = await f.raw('memory_catalog_rows');
      final booksBefore = await f.raw('memory_book_rows');
      f.catalog.afterRebuild = () => f.source.current = false;
      final result = await f.call('astoria_memory_catalog_rebuild', {
        'sessionId': SessionMemoryFixture.target,
      }, original: f.context(sourceLease: true));
      expect(result.content['code'], 'stale');
      expect(result.content['effect'], 'none');
      expect(await f.raw('memory_catalog_rows'), before);
      expect(await f.raw('memory_book_rows'), booksBefore);
      expect(f.source.releases, 1);
    },
  );

  sessionMemoryTest(
    'corrupt book JSON is unavailable, not an empty replacement or repair',
    (f) async {
      await f.seedBooks();
      await (f.db.update(
        f.db.memoryBookRows,
      )..where((r) => r.sessionId.equals(SessionMemoryFixture.target))).write(
        const MemoryBookRowsCompanion(
          entriesJson: Value('INVALID_PRIVATE_BLOB'),
        ),
      );
      final before = await f.raw('memory_book_rows');
      expect(
        (await f.call('astoria_memory_settings', {
          'sessionId': SessionMemoryFixture.target,
          'enabled': true,
        })).content['code'],
        'unavailable',
      );
      expect(await f.raw('memory_book_rows'), before);
    },
  );
}
