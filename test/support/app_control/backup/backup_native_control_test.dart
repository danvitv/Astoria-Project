import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'backup_native_fixture.dart';

void backupWidgetTest(
  String name,
  Future<void> Function(WidgetTester, BackupNativeFixture) body, {
  bool noHost = false,
}) {
  testWidgets(name, (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    final previous = messenger.allMessagesHandler;
    final attempts = <String>[];
    Never block(String kind) {
      attempts.add(kind);
      throw StateError('Outside approved synthetic native backup fixture');
    }

    // Narrow framework UI metadata only, never OS picker/vault/prefs/data roots.
    messenger.allMessagesHandler = (channel, handler, message) async {
      if (channel == SystemChannels.platform.name && message != null) {
        final call = const JSONMethodCodec().decodeMethodCall(message);
        if (const {
          'HapticFeedback.vibrate',
          'SystemSound.play',
          'SystemChrome.setSystemUIOverlayStyle',
          'SystemChrome.setApplicationSwitcherDescription',
        }.contains(call.method)) {
          return const JSONMethodCodec().encodeSuccessEnvelope(null);
        }
      }
      if (channel == SystemChannels.navigation.name && message != null) {
        final call = SystemChannels.navigation.codec.decodeMethodCall(message);
        final args = call.arguments;
        if (const {
                  'selectMultiEntryHistory',
                  'selectSingleEntryHistory',
                }.contains(call.method) &&
                args == null ||
            call.method == 'routeInformationUpdated' &&
                args is Map &&
                const {'/', '/backup', '/replacement'}.contains(args['uri'])) {
          return SystemChannels.navigation.codec.encodeSuccessEnvelope(null);
        }
      }
      if (channel == SystemChannels.accessibility.name && message != null) {
        final event = SystemChannels.accessibility.codec.decodeMessage(message);
        if (event case {
          'type': 'tap',
          'data': final Map data,
          'nodeId': final int id,
        }) {
          if (data.isEmpty && id >= 0) {
            return SystemChannels.accessibility.codec.encodeMessage(null);
          }
        }
      }
      return block('unapproved framework channel');
    };
    final f = BackupNativeFixture();
    final failure = BackupFixtureFailure();
    try {
      await failure.run(
        () => HttpOverrides.runZoned(() async {
          await failure.run(() async {
            await backupReal(tester, f.initialize);
            await tester.pumpWidget(f.widget());
            await tester.pumpAndSettle();
            f.attach(noHost: noHost);
            await body(tester, f);
          });
          await failure.run(f.stopOriginalActions);
          await failure.run(() => f.drainOriginalActions(tester));
          await failure.run(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
          });
          await failure.run(() => backupReal(tester, f.close));
        }, createHttpClient: (_) => block('HTTP/network')),
      );
      await failure.run(() async {
        await messenger.platformMessagesFinished;
        expect(attempts, isEmpty);
        expect(tester.takeException(), isNull);
      });
    } finally {
      messenger.allMessagesHandler = previous;
    }
    failure.throwIfAny();
  }, skip: !Platform.isWindows);
}

Future<({Future<NativeToolResult> future})> beginSave(
  WidgetTester tester,
  BackupNativeFixture f,
) async {
  final pending = await backupReal(tester, () => (future: f.call()));
  final action = f.actionFor(pending.future);
  await backupPumpUntil(tester, () => f.dialog.choices == 1, action: action);
  await backupReal(tester, () => f.dialog.choose(f.destinationPath));
  await backupModal(tester, action: action);
  return pending;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  backupWidgetTest(
    'production provider native whole DB local save and exact opaque verification',
    (tester, f) async {
      expect(f.original.sourceAccess, isNull);
      final definition = f.registry.definitions.single;
      expect(definition.name, SupportBackupNativeFileHost.action);
      expect(definition.parameters['additionalProperties'], isFalse);
      final pending = await beginSave(tester, f);
      expect(
        await backupReal(tester, () => File(f.destinationPath).exists()),
        isFalse,
      );
      final preview = find.byKey(
        const ValueKey('support_backup_confirmation_preview'),
      );
      final text = tester
          .widget<Text>(
            find.descendant(of: preview, matching: find.byType(Text)),
          )
          .data!;
      expect(text, contains(f.destinationPath));
      expect(text, contains(SupportBackupNativeFileHost.disclosure));
      expect(text, contains(f.original.runId));
      expect(text, isNot(contains(BackupNativeFixture.private)));
      await backupDecision(tester, 'accept');
      final result = await backupJoin(tester, pending.future);
      expect(result.content, {
        'ok': true,
        'code': 'completed',
        'effect': 'persisted',
        'data': {'status': 'verified'},
      });
      expect(f.root.admissions, 1);
      final serialized = result.content.toString();
      for (final forbidden in [
        f.sourcePath,
        f.destinationPath,
        BackupNativeFixture.private,
        'tableCount',
        'byteCount',
        'hash',
        'schema',
      ]) {
        expect(serialized, isNot(contains(forbidden)));
      }
      await backupReal(tester, () async {
        await f.expectSourceUnchanged();
        final copy = sqlite.sqlite3.open(
          f.destinationPath,
          mode: sqlite.OpenMode.readOnly,
        );
        try {
          final registered = f.db.allTables
              .map((t) => t.actualTableName)
              .toSet();
          final names = copy
              .select('SELECT name FROM sqlite_schema WHERE type=?', ['table'])
              .map((r) => r['name'])
              .toSet();
          expect(names.containsAll(registered), isTrue);
          expect(names, contains('backup_extra'));
          expect(
            copy
                .select('SELECT type FROM sqlite_schema WHERE name LIKE ?', [
                  'backup_extra_%',
                ])
                .map((r) => r['type'])
                .toSet(),
            {'index', 'view', 'trigger'},
          );
          expect(
            copy
                .select('SELECT description FROM characters')
                .single
                .values
                .single,
            BackupNativeFixture.private,
          );
          expect(
            copy.select('SELECT api_key FROM api_configs').single.values.single,
            'synthetic-credential-${BackupNativeFixture.private}',
          );
          expect(
            copy.select('SELECT body FROM backup_extra').single.values.single,
            BackupNativeFixture.private.codeUnits,
          );
          expect(
            copy
                .select('SELECT summary_ciphertext FROM support_context_blocks')
                .single
                .values
                .single,
            'synthetic-ciphertext-${BackupNativeFixture.private}',
          );
          expect(
            copy
                .select(
                  'SELECT before_ciphertext FROM support_mutation_journal',
                )
                .single
                .values
                .single,
            'synthetic-before-${BackupNativeFixture.private}',
          );
        } finally {
          copy.close();
        }
        final bytes = await File(f.destinationPath).readAsBytes();
        final retried = await f.call();
        expect(retried.content['code'], 'unavailable');
        expect(retried.content['effect'], 'none');
        expect(await File(f.destinationPath).readAsBytes(), bytes);
        expect(
          (await f.directory.list(followLinks: false).toList()).where(
            (e) => e.path.contains('.snapshot-'),
          ),
          isEmpty,
        );
      });
    },
  );

  backupWidgetTest(
    'unknown path SQL key network and restore arguments have no native effect',
    (tester, f) async {
      for (final field in [
        'path',
        'sourcePath',
        'destinationPath',
        'hash',
        'sql',
        'key',
        'network',
        'restore',
        'operation',
      ]) {
        final result = await backupReal(
          tester,
          () => f.call({field: 'untrusted'}),
        );
        expect(result.content['code'], 'invalidArguments');
        expect(result.content['effect'], 'none');
      }
      expect(f.dialog.choices, 0);
      expect(f.root.admissions, 0);
      await backupReal(tester, f.expectSourceUnchanged);
      expect(
        await backupReal(tester, () => File(f.destinationPath).exists()),
        isFalse,
      );
    },
  );

  backupWidgetTest(
    'missing native file host is unavailable without opening another DB',
    (tester, f) async {
      final result = await backupReal(tester, f.call);
      expect(result.content['code'], 'unavailable');
      expect(result.content['effect'], 'none');
      expect(f.dialog.choices, 0);
      expect(f.root.admissions, 0);
      await backupReal(tester, f.expectSourceUnchanged);
    },
    noHost: true,
  );

  backupWidgetTest(
    'native picker cancel and final exact native cancel create no file',
    (tester, f) async {
      final started = await backupReal(tester, () => (future: f.call()));
      await backupPumpUntil(
        tester,
        () => f.dialog.choices == 1,
        action: f.actionFor(started.future),
      );
      await backupReal(tester, () => f.dialog.choose(null));
      expect(
        (await backupJoin(tester, started.future)).content['code'],
        'cancelled',
      );
      final second = await backupReal(tester, () => (future: f.call()));
      await backupPumpUntil(
        tester,
        () => f.dialog.choices == 2,
        action: f.actionFor(second.future),
      );
      await backupReal(tester, () => f.dialog.choose(f.destinationPath));
      await backupModal(tester, action: f.actionFor(second.future));
      await backupDecision(tester, 'cancel');
      final denied = await backupJoin(tester, second.future);
      expect(denied.content['code'], 'denied');
      expect(denied.content['effect'], 'none');
      expect(f.root.admissions, 0);
      expect(
        await backupReal(tester, () => File(f.destinationPath).exists()),
        isFalse,
      );
      await backupReal(tester, f.expectSourceUnchanged);
    },
  );

  backupWidgetTest(
    'Stop while original picker awaits cannot retain a destination or publish',
    (tester, f) async {
      final started = await backupReal(tester, () => (future: f.call()));
      await backupPumpUntil(
        tester,
        () => f.dialog.choices == 1,
        action: f.actionFor(started.future),
      );
      f.token.cancel();
      await backupReal(tester, () => f.dialog.choose(f.destinationPath));
      final result = await backupJoin(tester, started.future);
      expect(result.content['code'], 'cancelled');
      expect(result.content['effect'], 'none');
      expect(
        find.byKey(const ValueKey('support_backup_confirmation_accept')),
        findsNothing,
      );
      expect(
        await backupReal(tester, () => File(f.destinationPath).exists()),
        isFalse,
      );
      await backupReal(tester, f.expectSourceUnchanged);
    },
  );

  backupWidgetTest(
    'A to B to A native UI replacement never revives original consent',
    (tester, f) async {
      final pending = await beginSave(tester, f);
      final page = ModalRoute.of(f.screenContext)!;
      final sheet = ModalRoute.of(
        tester.element(
          find.byKey(const ValueKey('support_backup_confirmation_accept')),
        ),
      )!;
      f.router.go('/replacement');
      await tester.pump();
      await tester.pump(
        page.transitionDuration + sheet.reverseTransitionDuration,
      );
      f.router.go('/backup');
      await tester.pump();
      await tester.pump(page.transitionDuration);
      final result = await backupJoin(tester, pending.future);
      expect(result.content['effect'], 'none');
      expect(result.content['code'], isNot('completed'));
      expect(f.ui.isCurrent, isFalse);
      expect(f.root.admissions, 0);
      expect(
        await backupReal(tester, () => File(f.destinationPath).exists()),
        isFalse,
      );
      await backupReal(tester, f.expectSourceUnchanged);
    },
  );

  backupWidgetTest(
    'preexisting exact native destination is preserved and never replaced',
    (tester, f) async {
      final originalBytes = List<int>.generate(4096, (i) => i % 251);
      await backupReal(
        tester,
        () => File(f.destinationPath).writeAsBytes(originalBytes),
      );
      final pending = await beginSave(tester, f);
      await backupDecision(tester, 'accept');
      final result = await backupJoin(tester, pending.future);
      expect(result.content['code'], 'unavailable');
      expect(result.content['effect'], 'none');
      expect(
        await backupReal(tester, () => File(f.destinationPath).readAsBytes()),
        originalBytes,
      );
      await backupReal(tester, f.expectSourceUnchanged);
    },
  );

  backupWidgetTest(
    'foreign opened native DB cannot borrow the original ROOT source authority',
    (tester, f) async {
      final foreign = await backupReal(tester, () async {
        final writer = sqlite.sqlite3.open(
          p.join(f.directory.path, 'foreign.db'),
        );
        final db = AppDatabase.openedNative(
          writer,
          closeUnderlyingOnClose: false,
        );
        await db.customSelect('SELECT 1').get();
        return (writer: writer, db: db);
      });
      final failure = BackupFixtureFailure();
      await failure.run(() async {
        f.providerDb = foreign.db;
        f.container.invalidate(appDbProvider);
        f.rebuildRegistry();
        expect(foreign.db.nativeDataSourceIdentity!.belongsTo(f.db), isFalse);
        final result = await backupReal(tester, f.call);
        expect(result.content['code'], 'unavailable');
        expect(result.content['effect'], 'none');
        expect(f.dialog.choices, 0);
        expect(f.root.admissions, 0);
        expect(
          await backupReal(tester, () => File(f.destinationPath).exists()),
          isFalse,
        );
        await backupReal(tester, f.expectSourceUnchanged);
      });
      await failure.run(() => backupReal(tester, foreign.db.close));
      await failure.run(() => backupReal(tester, foreign.writer.close));
      failure.throwIfAny();
    },
  );

  backupWidgetTest('memory DB never pretends to be a native file source', (
    tester,
    f,
  ) async {
    final memory = AppDatabase.forTesting(NativeDatabase.memory());
    final failure = BackupFixtureFailure();
    await failure.run(() async {
      f.providerDb = memory;
      f.container.invalidate(appDbProvider);
      f.rebuildRegistry();
      expect(memory.nativeDataSourceIdentity, isNull);
      final result = await backupReal(tester, f.call);
      expect(result.content['code'], 'unavailable');
      expect(result.content['effect'], 'none');
      expect(f.dialog.choices, 0);
      await backupReal(tester, f.expectSourceUnchanged);
    });
    await failure.run(() => backupReal(tester, memory.close));
    failure.throwIfAny();
  });

  backupWidgetTest(
    'source replacement after exact confirmation denies before native creation',
    (tester, f) async {
      final gate = f.holdRootGate();
      var entered = false;
      f.root.beforeAdmission = () async {
        entered = true;
        await gate.future;
      };
      final pending = await beginSave(tester, f);
      await backupDecision(tester, 'accept');
      await backupPumpUntil(
        tester,
        () => entered,
        action: f.actionFor(pending.future),
      );
      final memory = AppDatabase.forTesting(NativeDatabase.memory());
      final failure = BackupFixtureFailure();
      await failure.run(() async {
        f.providerDb = memory;
        f.container.invalidate(appDbProvider);
        gate.complete();
        final result = await backupJoin(tester, pending.future);
        expect(result.content['effect'], 'none');
        expect(result.content['code'], isNot('completed'));
        expect(
          await backupReal(tester, () => File(f.destinationPath).exists()),
          isFalse,
        );
        await backupReal(tester, f.expectSourceUnchanged);
      });
      await failure.run(f.stopOriginalActions);
      await failure.run(() => f.drainOriginalActions(tester));
      await failure.run(() => backupReal(tester, memory.close));
      failure.throwIfAny();
    },
  );

  backupWidgetTest(
    'stale original run and closed actual source cannot open a native picker',
    (tester, f) async {
      f.ownerCurrent = false;
      final stale = await backupReal(tester, f.call);
      expect(stale.content['code'], 'stale');
      expect(stale.content['effect'], 'none');
      expect(f.dialog.choices, 0);
      final identity = f.db.nativeDataSourceIdentity!;
      await backupReal(tester, f.closeDatabase);
      expect(identity.isCurrent, isFalse);
      expect(identity.belongsTo(f.db), isFalse);
      expect(f.db.nativeDataSourceIdentity, isNull);
      expect(
        await backupReal(tester, () => File(f.destinationPath).exists()),
        isFalse,
      );
      await backupReal(tester, f.expectSourceUnchanged);
    },
  );

  backupWidgetTest(
    'Stop after exact gesture while original ROOT awaits denies file creation',
    (tester, f) async {
      final gate = f.holdRootGate();
      var entered = false;
      f.root.beforeAdmission = () async {
        entered = true;
        await gate.future;
      };
      final pending = await beginSave(tester, f);
      final failure = BackupFixtureFailure();
      await failure.run(() async {
        await backupDecision(tester, 'accept');
        await backupPumpUntil(
          tester,
          () => entered,
          action: f.actionFor(pending.future),
        );
        f.token.cancel();
        gate.complete();
        final result = await backupJoin(tester, pending.future);
        expect(result.content['code'], 'cancelled');
        expect(result.content['effect'], 'none');
        expect(f.root.admissions, 0);
        expect(
          await backupReal(tester, () => File(f.destinationPath).exists()),
          isFalse,
        );
        await backupReal(tester, f.expectSourceUnchanged);
      });
      await failure.run(f.stopOriginalActions);
      await failure.run(() => f.drainOriginalActions(tester));
      failure.throwIfAny();
    },
  );

  backupWidgetTest(
    'published native file remains factual after Stop and provider disposal',
    (tester, f) async {
      final pending = await beginSave(tester, f);
      await backupDecision(tester, 'accept');
      await backupPumpUntil(
        tester,
        () => File(f.destinationPath).existsSync(),
        action: f.actionFor(pending.future),
      );
      f.token.cancel();
      final result = await backupJoin(tester, pending.future);
      expect(result.content['effect'], 'persisted');
      expect(result.content['code'], anyOf('completed', 'cancelled'));
      await backupReal(tester, () async {
        final published = await File(f.destinationPath).readAsBytes();
        f.container.invalidate(supportAppControlBackupAdaptersProvider);
        f.host.dispose();
        expect(await File(f.destinationPath).readAsBytes(), published);
        await f.expectSourceUnchanged();
      });
    },
  );
}
