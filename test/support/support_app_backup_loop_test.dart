import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_message_list.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_plain_markdown.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:sqlite3/unstable/ffi_bindings.dart' as nsql;

import 'support_app_backup_loop_fixture.dart';

Future<void> stopBackupLoop(WidgetTester tester) async {
  final button = find.byKey(const ValueKey('support_composer_stop_btn'));
  expect(button.hitTestable(), findsOneWidget);
  await backupLoopReal(tester, () => tester.tap(button));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  backupLoopTest(
    'actual model snapshot saves WAL whole DB and returns only correlated status',
    (tester, f) async {
      f.script();
      await f.start(tester);
      final tools = (f.wire.single['tools'] as List)
          .cast<Map<dynamic, dynamic>>();
      expect(
        tools.length,
        45,
      ); // Original actions plus two consent-bound sources.
      final definition =
          tools.singleWhere(
                (t) =>
                    (t['function'] as Map)['name'] ==
                    SupportBackupNativeFileHost.action,
              )['function']
              as Map;
      expect((definition['parameters'] as Map)['properties'], isEmpty);
      expect(
        (definition['parameters'] as Map)['additionalProperties'],
        isFalse,
      );
      expect(
        find.byKey(const ValueKey('support_tool_confirmation_accept')),
        findsNothing,
      );
      await f.select(tester, f.native.destinationPath);
      final preview = find.byKey(
        const ValueKey('support_backup_confirmation_preview'),
      );
      final text = tester
          .widget<Text>(
            find.descendant(of: preview, matching: find.byType(Text)),
          )
          .data!;
      expect(text, contains(f.native.destinationPath));
      expect(text, contains(SupportBackupNativeFileHost.disclosure));
      expect(text, contains('backup_loop_call'));
      final before = await backupLoopReal(tester, () {
        final counts = <String, int>{};
        for (final t in f.native.db.allTables) {
          counts[t.actualTableName] =
              f.native.handle
                      .select('SELECT COUNT(*) FROM "${t.actualTableName}"')
                      .single
                      .values
                      .single
                  as int;
        }
        final ciphertext = f.native.handle
            .select('SELECT body_ciphertext FROM support_messages WHERE id=?', [
              'excluded-backup-message',
            ])
            .single
            .values
            .single;
        expect(ciphertext, isNot(BackupLoopNative.private));
        expect(File(f.native.destinationPath).existsSync(), isFalse);
        return (counts: counts, ciphertext: ciphertext);
      });
      await backupLoopDecision(tester, 'accept');
      final reply = await f.finish(tester);
      expect(reply.status, 'complete');
      expect(reply.body, 'Локальный снимок сохранён и проверен.');
      expect(
        f.wire.length,
        2,
      ); // Backup did NOT consume/retire the source token.
      expect(f.result(), {
        'ok': true,
        'code': 'completed',
        'effect': 'persisted',
        'data': {'status': 'verified'},
      });
      expect(f.requests[0].uri, f.requests[1].uri);
      expect(f.requests[0].method, 'POST');
      expect(f.requests[1].method, 'POST');
      expect(
        identical(f.requests[0].cancelToken, f.requests[1].cancelToken),
        isTrue,
      );
      for (final post in f.wire) {
        expect(post['model'], f.native.api.model);
      }
      await backupLoopReal(tester, () {
        final copy = sqlite.sqlite3.open(
          f.native.destinationPath,
          mode: sqlite.OpenMode.readOnly,
        );
        try {
          for (final entry in before.counts.entries) {
            expect(
              copy
                  .select('SELECT COUNT(*) FROM "${entry.key}"')
                  .single
                  .values
                  .single,
              entry.value,
            );
          }
          expect(
            copy
                .select('SELECT description FROM characters WHERE char_id=?', [
                  'private-backup-card',
                ])
                .single
                .values
                .single,
            BackupLoopNative.private,
          );
          expect(
            copy
                .select('SELECT api_key FROM api_configs WHERE config_id=?', [
                  'private-backup-api',
                ])
                .single
                .values
                .single,
            BackupLoopNative.rowSecret,
          );
          expect(
            copy
                .select(
                  'SELECT body_ciphertext FROM support_messages WHERE id=?',
                  ['excluded-backup-message'],
                )
                .single
                .values
                .single,
            before.ciphertext,
          );
          expect(
            copy
                .select('SELECT body FROM backup_loop_extra')
                .single
                .values
                .single,
            BackupLoopNative.private.codeUnits,
          );
          expect(
            copy
                .select('SELECT type FROM sqlite_schema WHERE name LIKE ?', [
                  'backup_loop_extra_%',
                ])
                .map((r) => r['type'])
                .toSet(),
            {'index', 'view', 'trigger'},
          );
          expect(copy.select('PRAGMA quick_check').single.values.single, 'ok');
          expect(
            copy.select('PRAGMA journal_mode').single.values.single,
            'delete',
          );
          expect(
            f.native.handle
                .select('SELECT description FROM characters WHERE char_id=?', [
                  'private-backup-card',
                ])
                .single
                .values
                .single,
            BackupLoopNative.private,
          );
          expect(File('${f.native.destinationPath}-wal').existsSync(), isFalse);
        } finally {
          copy.close();
        }
      });
      final visible = f.container
          .read(supportWorkspaceProvider)
          .activeMessages
          .singleWhere((m) => m.id == reply.id);
      expect(visible.body, reply.body);
      final feed = find.byType(SupportMessageList);
      final markdown = find.descendant(
        of: feed,
        matching: find.byWidgetPredicate(
          (w) => w is SupportPlainMarkdown && w.text == reply.body,
        ),
      );
      await tester.scrollUntilVisible(
        markdown,
        200,
        scrollable: find
            .descendant(of: feed, matching: find.byType(Scrollable))
            .first,
        maxScrolls: 12,
      );
      await tester.pump();
      final selectable = find.descendant(
        of: markdown,
        matching: find.byType(SelectableText),
      );
      expect(selectable.hitTestable(), findsOneWidget);
      expect(
        tester.widget<SelectableText>(selectable).textSpan!.toPlainText(),
        reply.body,
      );
      f.noEgress(reply.body);
    },
  );

  for (final decision in ['picker', 'footer']) {
    backupLoopTest(
      'actual native $decision Cancel never copies or authorizes success',
      (tester, f) async {
        f.script(answer: 'This malicious answer claims success.');
        await f.start(tester);
        if (decision == 'picker') {
          await f.select(tester, null);
        } else {
          await f.select(tester, f.native.destinationPath);
          await backupLoopDecision(tester, 'cancel');
        }
        final reply = await f.finish(tester);
        expect(reply.status, 'error');
        expect(reply.body, isNot(contains('malicious')));
        expect(f.result()['ok'], isFalse);
        expect(f.result()['effect'], 'none');
        expect((f.result()['data'] as Map).keys, ['status']);
        expect(
          await backupLoopReal(
            tester,
            () => File(f.native.destinationPath).exists(),
          ),
          isFalse,
        );
        f.noEgress(reply.body);
      },
    );
  }

  for (final late in ['selection', 'error']) {
    backupLoopTest(
      'Stop completes ORIGINAL model before pending picker late $late',
      (tester, f) async {
        f.script();
        await f.start(tester);
        await stopBackupLoop(tester);
        final reply = await f.finish(tester);
        expect(reply.status, 'stopped');
        expect(
          f.dialog.pending!.isCompleted,
          isFalse,
        ); // OS dialog need not close.
        expect(f.wire.length, 1);
        final savedBody = reply.body;
        f.router.go('/characters');
        await tester.pump();
        await backupLoopReal(tester, () {
          if (late == 'error') {
            f.dialog.failLate();
          } else {
            f.dialog.complete(f.native.destinationPath);
          }
        });
        for (var i = 0; i < 4; i++) {
          await tester.pump();
          await backupLoopReal(
            tester,
            () => Future<void>.delayed(Duration.zero),
          );
        }
        expect(f.wire.length, 1);
        expect(
          find.byKey(const ValueKey('support_backup_confirmation_accept')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('backup_loop_replacement')),
          findsOneWidget,
        );
        expect(
          await backupLoopReal(
            tester,
            () => File(f.native.destinationPath).exists(),
          ),
          isFalse,
        );
        expect(
          (await backupLoopReal(
            tester,
            () => f.native.repo.getMessageById(reply.id),
          ))!.body,
          savedBody,
        );
        f.noEgress(savedBody);
      },
    );
  }

  backupLoopTest(
    'Stop inside the actual read ROOT refuses original file custody',
    (tester, f) async {
      f.script();
      await f.start(tester);
      await f.select(tester, f.native.destinationPath);
      final entered = Completer<void>(), release = Completer<void>();
      f.gates.add(release);
      var held = false;
      f.native.primitive.beforeDecrypt = (_) async {
        // Read-only native pointer observation of THIS opened handle: this is
        // an actual ROOT transaction, not a synthetic root/Boolean callback.
        if (held ||
            nsql.sqlite3_get_autocommit(f.native.handle.handle.cast()) != 0)
          return;
        held = true;
        entered.complete();
        await release.future;
      };
      final root = BackupLoopSignal(entered.future);
      await backupLoopDecision(tester, 'accept');
      await backupLoopUntil(tester, () => root.done, signal: f.settlement);
      expect(
        await backupLoopReal(
          tester,
          () => File(f.native.destinationPath).exists(),
        ),
        isFalse,
      );
      await stopBackupLoop(tester);
      await backupLoopReal(tester, release.complete);
      final reply = await f.finish(tester);
      expect(reply.status, 'stopped');
      expect(f.wire.length, 1);
      expect(
        await backupLoopReal(
          tester,
          () => File(f.native.destinationPath).exists(),
        ),
        isFalse,
      );
      f.noEgress(reply.body);
    },
  );

  backupLoopTest(
    'preexisting selected file stays unchanged and model cannot invent success',
    (tester, f) async {
      await backupLoopReal(
        tester,
        () => File(
          f.native.destinationPath,
        ).writeAsString('EXISTING_SYNTHETIC_FILE'),
      );
      f.script(answer: 'Overwritten successfully.');
      await f.start(tester);
      await f.select(tester, f.native.destinationPath);
      await backupLoopDecision(tester, 'accept');
      final reply = await f.finish(tester);
      expect(reply.status, 'error');
      expect(f.result(), {
        'ok': false,
        'code': 'unavailable',
        'effect': 'none',
        'data': {'status': 'unavailable'},
      });
      expect(
        await backupLoopReal(
          tester,
          () => File(f.native.destinationPath).readAsString(),
        ),
        'EXISTING_SYNTHETIC_FILE',
      );
      f.noEgress(reply.body);
    },
  );

  backupLoopTest(
    'published late native fact joins settlement without POST or replacement paint',
    (tester, f) async {
      f.script();
      await f.start(tester);
      await f.select(tester, f.native.destinationPath);
      final entered = Completer<void>(), release = Completer<void>();
      f.gates.add(release);
      f.native.primitive.afterEncrypt = (_) async {
        if (entered.isCompleted) return;
        entered.complete();
        await release.future;
      };
      f.observePublication(() => f.router.go('/characters'));
      await backupLoopDecision(tester, 'accept');
      final factualSettlement = BackupLoopSignal(entered.future);
      await backupLoopUntil(
        tester,
        () => factualSettlement.done,
        signal: f.settlement,
      );
      expect(f.publishedObserved, isTrue);
      final bytes = await backupLoopReal(
        tester,
        () => File(f.native.destinationPath).readAsBytes(),
      );
      expect(bytes, isNotEmpty);
      expect(
        f.settlement!.done,
        isFalse,
      ); // Started durable settlement is joined.
      await tester.pump();
      expect(
        find.byKey(const ValueKey('backup_loop_replacement')),
        findsOneWidget,
      );
      await backupLoopReal(tester, release.complete);
      final reply = await f.finish(tester);
      expect(reply.status, 'stopped');
      expect(reply.body, contains('локальный файл сохранён'));
      expect(reply.body, contains('проверка снимка не подтверждена'));
      expect(f.wire.length, 1);
      expect(
        await backupLoopReal(
          tester,
          () => File(f.native.destinationPath).readAsBytes(),
        ),
        bytes,
      );
      expect(find.text(reply.body), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) => w is SelectableText && w.textSpan?.toPlainText() == reply.body,
        ),
        findsNothing,
      );
      f.noEgress(reply.body);
    },
  );

  for (final retirement in ['routeABA', 'sourceABA']) {
    backupLoopTest('$retirement cannot renew a pending ORIGINAL selection', (
      tester,
      f,
    ) async {
      f.script();
      await f.start(tester);
      await backupLoopReal(tester, () {
        if (retirement == 'routeABA') {
          f.router.go('/characters');
          f.router.go('/support');
        } else {
          final finish = f.native.revisions.beginMutation();
          finish();
        }
      });
      final reply = await f.finish(tester);
      await backupLoopReal(
        tester,
        () => f.dialog.complete(f.native.destinationPath),
      );
      await tester.pump();
      expect(reply.status, 'stopped');
      expect(f.wire.length, 1);
      expect(
        await backupLoopReal(
          tester,
          () => File(f.native.destinationPath).exists(),
        ),
        isFalse,
      );
      expect(
        find.byKey(const ValueKey('support_backup_confirmation_accept')),
        findsNothing,
      );
      f.noEgress(reply.body);
    });
  }

  backupLoopTest(
    'same actual model over memory SQLite has NO native file authority',
    (tester, f) async {
      f.script();
      await f.start(tester, picker: false);
      final reply = await f.finish(tester);
      expect(f.dialog.choices, 0);
      expect(f.result()['code'], 'unavailable');
      expect(f.result()['effect'], 'none');
      f.noEgress(reply.body);
    },
    memory: true,
  );

  backupLoopTest(
    'actual original model without native UI port keeps default backup unavailable',
    (tester, f) async {
      f.script();
      final finished = await f.startWithoutHost(tester);
      final reply = await f.finish(tester);
      await backupLoopUntil(tester, () => finished.done, signal: finished);
      expect(finished.value.saved, isTrue);
      expect(reply.status, 'error');
      expect(f.dialog.choices, 0);
      expect(f.result(), {
        'ok': false,
        'code': 'unavailable',
        'effect': 'none',
        'data': {'status': 'unavailable'},
      });
      expect(
        await backupLoopReal(
          tester,
          () => File(f.native.destinationPath).exists(),
        ),
        isFalse,
      );
      f.noEgress(reply.body);
    },
  );

  backupLoopTest(
    'two typed calls retain only one original selection and published file',
    (tester, f) async {
      f.script();
      final calls =
          (((f.replies.first['choices'] as List).single as Map)['message']
                  as Map)['tool_calls']
              as List;
      calls.add({
        'type': 'function',
        'id': 'backup_loop_duplicate',
        'function': {
          'name': SupportBackupNativeFileHost.action,
          'arguments': '{}',
        },
      });
      await f.start(tester);
      await f.select(tester, f.native.destinationPath);
      await backupLoopDecision(tester, 'accept');
      final reply = await f.finish(tester);
      expect(f.dialog.choices, 1);
      expect(f.wire.length, 2);
      final results = (f.wire.last['messages'] as List)
          .cast<Map<dynamic, dynamic>>()
          .where((m) => m['role'] == 'tool')
          .toList();
      expect(results.map((m) => m['tool_call_id']).toList(), [
        'backup_loop_call',
        'backup_loop_duplicate',
      ]);
      expect((jsonDecode(results[0]['content'] as String) as Map)['data'], {
        'status': 'verified',
      });
      expect(jsonDecode(results[1]['content'] as String), {
        'ok': false,
        'code': 'denied',
        'effect': 'none',
        'data': {'status': 'unavailable'},
      });
      expect(
        await backupLoopReal(
          tester,
          () => File(f.native.destinationPath).exists(),
        ),
        isTrue,
      );
      expect(reply.body, contains('локальный файл сохранён'));
      f.noEgress(reply.body);
    },
  );

  backupLoopTest(
    'actual model ROOT rejects foreign opened FILE source before picker',
    (tester, f) async {
      f.script();
      await f.start(tester, picker: false);
      final reply = await f.finish(tester);
      expect(f.dialog.choices, 0);
      expect(f.result()['code'], 'unavailable');
      expect(f.result()['effect'], 'none');
      expect(
        await backupLoopReal(
          tester,
          () => File(f.native.destinationPath).exists(),
        ),
        isFalse,
      );
      f.noEgress(reply.body);
    },
    foreignSource: true,
  );

  for (final argument in ['path', 'hash', 'key', 'sql', 'restore', 'body']) {
    backupLoopTest(
      'typed snapshot rejects model $argument field before native picker',
      (tester, f) async {
        f.script(arguments: {argument: 'untrusted'});
        await f.start(tester, picker: false);
        final reply = await f.finish(tester);
        expect(f.dialog.choices, 0);
        expect(reply.status, 'error');
        // The transport may reject the typed schema before a native result;
        // neither parser refusal nor registry refusal grants native effects.
        if (f.wire.length == 2) expect(f.result()['code'], 'invalidArguments');
        expect(
          await backupLoopReal(
            tester,
            () => File(f.native.destinationPath).exists(),
          ),
          isFalse,
        );
        f.noEgress(reply.body);
      },
    );
  }
}
