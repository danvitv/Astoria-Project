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
  // Shared wait observation, not a claim that every native case has an app bug.
  bool observePhases = true,
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
    final probe = observePhases ? BackupNativePhaseProbe(f) : null;
    f.phaseProbe = probe;
    f.dialog.phaseProbe = probe;
    final failure = BackupFixtureFailure();
    try {
      await failure.run(
        () => HttpOverrides.runZoned(() async {
          await failure.run(() async {
            if (probe == null) {
              await backupReal(tester, f.initialize);
              await tester.pumpWidget(f.widget());
              await tester.pumpAndSettle();
            } else {
              await probe.real(
                tester,
                BackupNativePhase.initialize,
                f.initialize,
              );
              await probe.frame(
                tester,
                BackupNativePhase.mount,
                () => tester.pumpWidget(f.widget()),
              );
              await probe.wait(
                tester,
                BackupNativePhase.mount,
                () => !tester.binding.hasScheduledFrame,
              );
            }
            f.attach(noHost: noHost);
            await body(tester, f);
          });
          if (probe != null) {
            await probe.cleanup(tester, failure);
          } else {
            await failure.run(f.stopOriginalActions);
            await failure.run(() => f.drainOriginalActions(tester));
            await failure.run(() async {
              await tester.pumpWidget(const SizedBox.shrink());
              await tester.pump();
            });
            await failure.run(() => backupReal(tester, f.close));
          }
        }, createHttpClient: (_) => block('HTTP/network')),
      );
      await failure.run(() async {
        if (probe == null) {
          await messenger.platformMessagesFinished;
        } else {
          await probe.real(
            tester,
            BackupNativePhase.cleanup,
            () => messenger.platformMessagesFinished,
          );
        }
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
  final probe = f.phaseProbe;
  if (probe == null) {
    await backupPumpUntil(tester, () => f.dialog.choices == 1, action: action);
  } else {
    await probe.wait(
      tester,
      BackupNativePhase.picker,
      () => f.dialog.choices == 1,
      action: action,
    );
  }
  await backupReal(tester, () => f.dialog.choose(f.destinationPath));
  if (probe == null) {
    await backupModal(tester, action: action);
  } else {
    final button = find.byKey(
      const ValueKey('support_backup_confirmation_accept'),
    );
    await probe.wait(
      tester,
      BackupNativePhase.modal,
      () => button.evaluate().isNotEmpty,
      action: action,
    );
    final route = ModalRoute.of(tester.element(button))!;
    await probe.frame(tester, BackupNativePhase.modal, tester.pump);
    await probe.frame(
      tester,
      BackupNativePhase.modal,
      () => tester.pump(route.transitionDuration),
    );
    expect(button.hitTestable(), findsOneWidget);
  }
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
        await f.real(
          tester,
          BackupNativePhase.modal,
          () => File(f.destinationPath).exists(),
        ),
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
      final probe = f.phaseProbe!;
      final accept = find.byKey(
        const ValueKey('support_backup_confirmation_accept'),
      );
      final route = ModalRoute.of(tester.element(accept))!;
      await probe.real(
        tester,
        BackupNativePhase.modal,
        () => tester.tap(accept),
      );
      await probe.frame(tester, BackupNativePhase.modal, tester.pump);
      await probe.frame(
        tester,
        BackupNativePhase.modal,
        () => tester.pump(route.reverseTransitionDuration),
      );
      final result = await probe.join(tester, pending.future);
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
      await f.real(tester, BackupNativePhase.join, () async {
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
    observePhases: true,
  );

  backupWidgetTest(
    'unknown path SQL key network and restore arguments have no native effect',
    (tester, f) async {
      final probe = f.phaseProbe!;
      expect(f.original.sourceAccess, isNull);
      var invoked = 0;
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
        late Future<NativeToolResult> original;
        // Observe the ACTUAL registry future in its real-I/O zone. The finite
        // probe hands control back for frames; it never replaces completion.
        await probe.real(tester, BackupNativePhase.invoke, () {
          original = f.call({field: 'untrusted'});
          return original;
        });
        final result = await probe.join(tester, original);
        invoked++;
        expect(result.callId, 'backup-call');
        expect(result.name, SupportBackupNativeFileHost.action);
        expect(result.content, {
          'ok': false,
          'code': 'invalidArguments',
          'effect': 'none',
          'data': {'status': 'unavailable'},
        });
        expect(f.actionCount, invoked);
        expect(f.settledActionCount, invoked);
        expect(f.actionsSettled, isTrue);
        expect(f.dialog.choices, 0);
        expect(f.root.admissions, 0);
        expect(probe.started(BackupNativePhase.picker), isFalse);
        expect(probe.started(BackupNativePhase.modal), isFalse);
        expect(probe.started(BackupNativePhase.rootEffect), isFalse);
        expect(f.original.sourceAccess, isNull);
      }
      expect(invoked, 9);
      expect(
        find.byKey(const ValueKey('support_backup_confirmation_accept')),
        findsNothing,
      );
      await probe.real(tester, BackupNativePhase.join, f.expectSourceUnchanged);
      expect(
        await probe.real(
          tester,
          BackupNativePhase.join,
          () => File(f.destinationPath).exists(),
        ),
        isFalse,
      );
    },
    observePhases: true,
  );

  backupWidgetTest(
    'missing native file host is unavailable without opening another DB',
    (tester, f) async {
      final result = await f.real(tester, BackupNativePhase.invoke, f.call);
      expect(result.content['code'], 'unavailable');
      expect(result.content['effect'], 'none');
      expect(f.dialog.choices, 0);
      expect(f.root.admissions, 0);
      await f.real(tester, BackupNativePhase.join, f.expectSourceUnchanged);
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
        probe: f.phaseProbe,
        phase: BackupNativePhase.picker,
      );
      await backupReal(tester, () => f.dialog.choose(null));
      expect(
        (await backupJoin(
          tester,
          started.future,
          probe: f.phaseProbe,
        )).content['code'],
        'cancelled',
      );
      final second = await backupReal(tester, () => (future: f.call()));
      await backupPumpUntil(
        tester,
        () => f.dialog.choices == 2,
        action: f.actionFor(second.future),
        probe: f.phaseProbe,
        phase: BackupNativePhase.picker,
      );
      await backupReal(tester, () => f.dialog.choose(f.destinationPath));
      await backupModal(
        tester,
        action: f.actionFor(second.future),
        probe: f.phaseProbe,
      );
      await backupDecision(tester, 'cancel', probe: f.phaseProbe);
      final denied = await backupJoin(
        tester,
        second.future,
        probe: f.phaseProbe,
      );
      expect(denied.content['code'], 'denied');
      expect(denied.content['effect'], 'none');
      expect(f.root.admissions, 0);
      expect(
        await f.real(
          tester,
          BackupNativePhase.join,
          () => File(f.destinationPath).exists(),
        ),
        isFalse,
      );
      await f.real(tester, BackupNativePhase.join, f.expectSourceUnchanged);
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
        probe: f.phaseProbe,
        phase: BackupNativePhase.picker,
      );
      f.token.cancel();
      await backupReal(tester, () => f.dialog.choose(f.destinationPath));
      final result = await backupJoin(
        tester,
        started.future,
        probe: f.phaseProbe,
      );
      expect(result.content['code'], 'cancelled');
      expect(result.content['effect'], 'none');
      expect(
        find.byKey(const ValueKey('support_backup_confirmation_accept')),
        findsNothing,
      );
      expect(
        await f.real(
          tester,
          BackupNativePhase.join,
          () => File(f.destinationPath).exists(),
        ),
        isFalse,
      );
      await f.real(tester, BackupNativePhase.join, f.expectSourceUnchanged);
    },
  );

  backupWidgetTest(
    'A to B to A native UI replacement never revives original consent',
    (tester, f) async {
      final probe = f.phaseProbe!;
      final pending = await beginSave(tester, f);
      final page = ModalRoute.of(f.screenContext)!;
      final sheet = ModalRoute.of(
        tester.element(
          find.byKey(const ValueKey('support_backup_confirmation_accept')),
        ),
      )!;
      final pageTransitionDuration = page.transitionDuration;
      final sheetReverseTransitionDuration = sheet.reverseTransitionDuration;
      f.router.go('/replacement');
      await probe.frame(tester, BackupNativePhase.modal, tester.pump);
      await probe.frame(
        tester,
        BackupNativePhase.modal,
        () => tester.pump(
          pageTransitionDuration + sheetReverseTransitionDuration,
        ),
      );
      f.router.go('/backup');
      await probe.frame(tester, BackupNativePhase.modal, tester.pump);
      await probe.frame(
        tester,
        BackupNativePhase.modal,
        () => tester.pump(pageTransitionDuration),
      );
      final result = await backupJoin(tester, pending.future, probe: probe);
      expect(result.content['effect'], 'none');
      expect(result.content['code'], isNot('completed'));
      expect(f.ui.isCurrent, isFalse);
      expect(f.root.admissions, 0);
      expect(
        await f.real(
          tester,
          BackupNativePhase.join,
          () => File(f.destinationPath).exists(),
        ),
        isFalse,
      );
      await f.real(tester, BackupNativePhase.join, f.expectSourceUnchanged);
    },
  );

  backupWidgetTest(
    'preexisting exact native destination is preserved and never replaced',
    (tester, f) async {
      final originalBytes = List<int>.generate(4096, (i) => i % 251);
      await f.real(
        tester,
        BackupNativePhase.join,
        () => File(f.destinationPath).writeAsBytes(originalBytes),
      );
      final pending = await beginSave(tester, f);
      await backupDecision(tester, 'accept', probe: f.phaseProbe);
      final result = await backupJoin(
        tester,
        pending.future,
        probe: f.phaseProbe,
      );
      expect(result.content['code'], 'unavailable');
      expect(result.content['effect'], 'none');
      expect(
        await f.real(
          tester,
          BackupNativePhase.join,
          () => File(f.destinationPath).readAsBytes(),
        ),
        originalBytes,
      );
      await f.real(tester, BackupNativePhase.join, f.expectSourceUnchanged);
    },
  );

  backupWidgetTest(
    'foreign opened native DB cannot borrow the original ROOT source authority',
    (tester, f) async {
      final foreign = await f.real(
        tester,
        BackupNativePhase.initialize,
        () async {
          final writer = sqlite.sqlite3.open(
            p.join(f.directory.path, 'foreign.db'),
          );
          final releaseOwner = f.retainAuxiliaryOwner();
          final db = AppDatabase.openedNative(
            writer,
            closeUnderlyingOnClose: false,
          );
          await db.customSelect('SELECT 1').get();
          return (writer: writer, db: db, releaseOwner: releaseOwner);
        },
      );
      var databaseClosed = false;
      final failure = BackupFixtureFailure();
      await failure.run(() async {
        f.providerDb = foreign.db;
        f.container.invalidate(appDbProvider);
        f.rebuildRegistry();
        expect(foreign.db.nativeDataSourceIdentity!.belongsTo(f.db), isFalse);
        final result = await f.real(tester, BackupNativePhase.invoke, f.call);
        expect(result.content['code'], 'unavailable');
        expect(result.content['effect'], 'none');
        expect(f.dialog.choices, 0);
        expect(f.root.admissions, 0);
        expect(
          await f.real(
            tester,
            BackupNativePhase.join,
            () => File(f.destinationPath).exists(),
          ),
          isFalse,
        );
        await f.real(tester, BackupNativePhase.join, f.expectSourceUnchanged);
      });
      await failure.run(() async {
        f.requireSettledWorkBeforeClose();
        await f.real(tester, BackupNativePhase.cleanup, foreign.db.close);
        databaseClosed = true;
      });
      await failure.run(() {
        f.requireSettledWorkBeforeClose();
        return backupReal(tester, () {
          foreign.writer.close();
          if (databaseClosed) foreign.releaseOwner();
        });
      });
      failure.throwIfAny();
    },
  );

  backupWidgetTest('memory DB never pretends to be a native file source', (
    tester,
    f,
  ) async {
    final memory = AppDatabase.forTesting(NativeDatabase.memory());
    final releaseOwner = f.retainAuxiliaryOwner();
    final failure = BackupFixtureFailure();
    await failure.run(() async {
      f.providerDb = memory;
      f.container.invalidate(appDbProvider);
      f.rebuildRegistry();
      expect(memory.nativeDataSourceIdentity, isNull);
      final result = await f.real(tester, BackupNativePhase.invoke, f.call);
      expect(result.content['code'], 'unavailable');
      expect(result.content['effect'], 'none');
      expect(f.dialog.choices, 0);
      await f.real(tester, BackupNativePhase.join, f.expectSourceUnchanged);
    });
    await failure.run(() async {
      f.requireSettledWorkBeforeClose();
      await f.real(tester, BackupNativePhase.cleanup, memory.close);
      releaseOwner();
    });
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
      await backupDecision(tester, 'accept', probe: f.phaseProbe);
      await backupPumpUntil(
        tester,
        () => entered,
        action: f.actionFor(pending.future),
        probe: f.phaseProbe,
        phase: BackupNativePhase.rootEffect,
      );
      final memory = AppDatabase.forTesting(NativeDatabase.memory());
      final releaseOwner = f.retainAuxiliaryOwner();
      final failure = BackupFixtureFailure();
      await failure.run(() async {
        f.providerDb = memory;
        f.container.invalidate(appDbProvider);
        gate.complete();
        final result = await backupJoin(
          tester,
          pending.future,
          probe: f.phaseProbe,
        );
        expect(result.content['effect'], 'none');
        expect(result.content['code'], isNot('completed'));
        expect(
          await f.real(
            tester,
            BackupNativePhase.join,
            () => File(f.destinationPath).exists(),
          ),
          isFalse,
        );
        await f.real(tester, BackupNativePhase.join, f.expectSourceUnchanged);
      });
      await failure.run(f.stopOriginalActions);
      await failure.run(() => f.drainOriginalActions(tester));
      await failure.run(() async {
        f.requireSettledWorkBeforeClose();
        await f.real(tester, BackupNativePhase.cleanup, memory.close);
        releaseOwner();
      });
      failure.throwIfAny();
    },
  );

  backupWidgetTest(
    'stale original run and closed actual source cannot open a native picker',
    (tester, f) async {
      f.ownerCurrent = false;
      final stale = await f.real(tester, BackupNativePhase.invoke, f.call);
      expect(stale.content['code'], 'stale');
      expect(stale.content['effect'], 'none');
      expect(f.dialog.choices, 0);
      final identity = f.db.nativeDataSourceIdentity!;
      await f.real(tester, BackupNativePhase.join, f.closeDatabase);
      expect(identity.isCurrent, isFalse);
      expect(identity.belongsTo(f.db), isFalse);
      expect(f.db.nativeDataSourceIdentity, isNull);
      expect(
        await f.real(
          tester,
          BackupNativePhase.join,
          () => File(f.destinationPath).exists(),
        ),
        isFalse,
      );
      await f.real(tester, BackupNativePhase.join, f.expectSourceUnchanged);
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
        await backupDecision(tester, 'accept', probe: f.phaseProbe);
        await backupPumpUntil(
          tester,
          () => entered,
          action: f.actionFor(pending.future),
          probe: f.phaseProbe,
          phase: BackupNativePhase.rootEffect,
        );
        f.token.cancel();
        gate.complete();
        final result = await backupJoin(
          tester,
          pending.future,
          probe: f.phaseProbe,
        );
        expect(result.content['code'], 'cancelled');
        expect(result.content['effect'], 'none');
        expect(f.root.admissions, 0);
        expect(
          await f.real(
            tester,
            BackupNativePhase.join,
            () => File(f.destinationPath).exists(),
          ),
          isFalse,
        );
        await f.real(tester, BackupNativePhase.join, f.expectSourceUnchanged);
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
      await backupDecision(tester, 'accept', probe: f.phaseProbe);
      await backupPumpUntil(
        tester,
        () => File(f.destinationPath).existsSync(),
        action: f.actionFor(pending.future),
        probe: f.phaseProbe,
        phase: BackupNativePhase.join,
      );
      f.token.cancel();
      final result = await backupJoin(
        tester,
        pending.future,
        probe: f.phaseProbe,
      );
      expect(result.content['effect'], 'persisted');
      expect(result.content['code'], anyOf('completed', 'cancelled'));
      await f.real(tester, BackupNativePhase.join, () async {
        final published = await File(f.destinationPath).readAsBytes();
        f.container.invalidate(supportAppControlBackupAdaptersProvider);
        f.host.dispose();
        expect(await File(f.destinationPath).readAsBytes(), published);
        await f.expectSourceUnchanged();
      });
    },
  );
}
