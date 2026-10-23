import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';

import 'support_theme_history_helpers.dart';
import 'support_history_sql_probe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  historyTest('core empty is readable; absent parent is unavailable', (
    f,
  ) async {
    await readOnlyHistory(f, () async {
      final page = (await coreHistory(f))!;
      expect(page.entries, isEmpty);
      expect(page.nextCursor, isNull);
      expect(await coreHistory(f, session: 'absent-parent'), isNull);
    });
  });

  historyTest(
    'core actual SQLite arguments enforce 33/1 bounds and DB cursor ownership',
    (f) async {
      await seedHistory(f, count: 33);
      final original = (await coreHistory(f))!;
      final probe = historyProbe(f);
      await probe.repo.createSession(
        const SupportSession(
          id: historySession,
          title: 'Probe',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      for (var i = 0; i < 33; i++) {
        await probe.repo.putMutation(
          (await f.repo.getMutationById(historyId(i)))!,
        );
      }
      final raw =
          (await probe.db
                  .customSelect(
                    'SELECT * FROM support_mutation_journal ORDER BY id',
                  )
                  .get())
              .map((r) => r.data)
              .toList();
      probe.sql.writes.clear();
      await readOnlyHistory(f, () async {
        expect(
          await coreHistory(f, repo: probe.repo, cursor: original.nextCursor),
          isNull,
        );
        final first = (await coreHistory(f, repo: probe.repo))!;
        expect(
          (await coreHistory(
            f,
            repo: probe.repo,
            cursor: first.nextCursor,
          ))!.entries.single.id,
          historyId(0),
        );
        expect(probe.sql.metadata, isNotEmpty);
        for (final query in probe.sql.metadata) {
          expect(query.args.take(3), [
            historySession,
            'theme.selection',
            'installed-active-selection',
          ]);
          expect(query.args.last, isIn([1, 33]));
          expect(query.rows, lessThanOrEqualTo(query.args.last as int));
          expect(query.sql, isNot(contains('ciphertext')));
        }
        expect(
          (await probe.db
                  .customSelect(
                    'SELECT * FROM support_mutation_journal ORDER BY id',
                  )
                  .get())
              .map((r) => r.data)
              .toList(),
          raw,
        );
        expect(probe.sql.writes, isEmpty);
      });
    },
  );

  historyTest('core 65 tied rows use native keysets of 32 + one lookahead', (
    f,
  ) async {
    await seedHistory(f, count: 65);
    final queries = <String>[];
    f.sql.event = (e) async {
      if (e.contains('SELECT id, session_id')) queries.add(e);
    };
    await readOnlyHistory(f, () async {
      final first = (await coreHistory(f))!;
      final second = (await coreHistory(f, cursor: first.nextCursor))!;
      final third = (await coreHistory(f, cursor: second.nextCursor))!;
      expect(
        [first.entries.length, second.entries.length, third.entries.length],
        [32, 32, 1],
      );
      final ids = [
        ...first.entries,
        ...second.entries,
        ...third.entries,
      ].map((r) => r.id).toList();
      expect(ids, List.generate(65, (i) => historyId(64 - i)));
      expect(ids.toSet().length, 65);
      expect(third.nextCursor, isNull);
      expect(
        queries.every(
          (q) =>
              q.contains(
                'WHERE session_id = ? AND domain = ? AND target_id = ?',
              ) &&
              q.contains('ORDER BY created_at DESC, id DESC LIMIT ?'),
        ),
        isTrue,
      );
      expect(
        queries.any(
          (q) => q.contains('created_at < ? OR (created_at = ? AND id < ?)'),
        ),
        isTrue,
      );
    });
  });

  historyTest('core primitive discovery never decrypts any journal evidence', (
    f,
  ) async {
    await seedHistory(f, count: 33);
    await seedHistory(f, session: ThemeProviderFixture.other);
    await seedHistory(f, domain: 'foreign.domain');
    await seedHistory(f, target: 'foreign-target');
    final decrypts = <String>[];
    f.primitive.event = (e) async {
      if (e.startsWith('decrypt-before:')) decrypts.add(e);
    };
    await readOnlyHistory(f, () async {
      final page = (await coreHistory(f))!;
      expect(page.entries.length, 32);
      expect(decrypts.every((e) => e.contains('|support_sessions|')), isTrue);
      expect(decrypts, isNotEmpty);
    });
  });

  historyTest(
    'core mixed timestamps sort before tied IDs and retain native bounds',
    (f) async {
      await seedHistory(f, count: 3);
      await changeHistory(f, historyId(0), 'created_at', 9007199254740991);
      await changeHistory(f, historyId(2), 'created_at', 0);
      await readOnlyHistory(f, () async {
        expect((await coreHistory(f))!.entries.map((r) => r.id), [
          historyId(0),
          historyId(1),
          historyId(2),
        ]);
      });
    },
  );

  historyTest(
    'core malformed lookahead is unavailable rather than hidden behind first 32',
    (f) async {
      await seedHistory(f, count: 33);
      await changeHistory(f, historyId(0), 'created_at', -1);
      await readOnlyHistory(f, () async {
        expect(await coreHistory(f), isNull);
      });
    },
  );

  for (final malformed in <String, Object>{
    'id': 'bad id',
    'created_at': -1,
    'created_at-real': 5.5,
    'created_at-text': 'not-a-time',
    'created_at-large': 9007199254740992,
    'status-blob': Uint8List.fromList([1, 2]),
  }.entries) {
    historyTest('core malformed ${malformed.key} is unavailable, not skipped', (
      f,
    ) async {
      await seedHistory(f);
      await changeHistory(
        f,
        historyId(0),
        malformed.key.split('-').first,
        malformed.value,
      );
      await readOnlyHistory(f, () async {
        expect(await coreHistory(f), isNull);
      });
    });
  }

  for (final change in [
    'rename',
    'delete-parent',
    'boundary-delete',
    'boundary-time',
    'boundary-status',
    'newest',
    'owner',
    'filter',
    'session',
  ]) {
    historyTest('core rejects continuation after $change', (f) async {
      await seedHistory(f, count: 33);
      final page = (await coreHistory(f))!;
      final cursor = page.nextCursor!;
      var repo = f.repo,
          session = historySession,
          target = 'installed-active-selection';
      switch (change) {
        case 'rename':
          await f.repo.renameSession(
            sessionId: historySession,
            title: 'Renamed',
          );
        case 'delete-parent':
          await f.repo.deleteSession(historySession);
          await f.repo.createSession(
            const SupportSession(
              id: historySession,
              title: 'Recreated',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
        case 'boundary-delete':
          await removeHistory(f, page.entries.last.id);
        case 'boundary-time':
          await changeHistory(f, page.entries.last.id, 'created_at', 6);
        case 'boundary-status':
          await changeHistory(f, page.entries.last.id, 'status', 'undone');
        case 'newest':
          await f.repo.putMutation(
            (await f.repo.getMutationById(
              historyId(32),
            ))!.copyWith(id: 'newest-row', createdAt: 9),
          );
        case 'owner':
          repo = SupportRepo(f.db, f.cipher);
        case 'filter':
          target = 'foreign-target';
        case 'session':
          session = ThemeProviderFixture.other;
      }
      await readOnlyHistory(f, () async {
        expect(
          await coreHistory(
            f,
            cursor: cursor,
            repo: repo,
            session: session,
            target: target,
          ),
          isNull,
        );
      });
    });
  }

  for (final checkpoint in [
    'SELECT id, session_id',
    'decrypt-before:',
    'decrypt-after:',
  ]) {
    historyTest(
      'core retirement at actual $checkpoint checkpoint denies return',
      (f) async {
        await seedHistory(f);
        var current = true, reached = false;
        Future<void> retire(String e) async {
          if (e.contains(checkpoint)) {
            current = false;
            reached = true;
          }
        }

        f.sql.event = retire;
        f.primitive.event = retire;
        await readOnlyHistory(f, () async {
          expect(await coreHistory(f, current: () => current), isNull);
          expect(reached, isTrue);
        });
      },
    );
  }

  for (final state in [
    'corrupt-title',
    'locked-key',
    'retired-after-transaction',
  ]) {
    historyTest('core $state is explicit unavailable including outer await', (
      f,
    ) async {
      await seedHistory(f);
      var current = true;
      if (state == 'corrupt-title') {
        await f.db.customStatement(
          'UPDATE support_sessions SET title_ciphertext = ? WHERE id = ?',
          ['corrupt', historySession],
        );
      } else if (state == 'locked-key') {
        f.storage.readError = StateError('SYNTHETIC_LOCKED');
      } else {
        f.db.afterCommit = () async {
          current = false;
        };
      }
      await readOnlyHistory(f, () async {
        expect(await coreHistory(f, current: () => current), isNull);
      });
    });
  }
}
