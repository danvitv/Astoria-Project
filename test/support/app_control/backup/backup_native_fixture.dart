import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_text_context_repo.dart';
import 'package:glaze_flutter/core/llm/transport/native_tool_types.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/models/support_text_context.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_app_action.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/support_app_action_registry.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/support_app_metadata_policy.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_backup_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';
import 'package:glaze_flutter/shared/widgets/glass_surface.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../../../credentials/fake_credential_storage.dart';
import '../../helpers/support_text_context_fixture.dart'
    show TextContextControlledCipher;
import '../app_control_fixture.dart' show AppControlSettingsNotifier;
import '../app_control_memory_theme.dart';

export 'package:glaze_flutter/features/support_assistant/models/support_app_action.dart';
export 'package:glaze_flutter/features/support_assistant/state/support_app_control_backup_provider.dart';
export 'package:glaze_flutter/core/llm/transport/native_tool_types.dart';

/// Actual production provider, native SQLite source owner, native UI and snapshot
/// service. Only the OS dialog and vault storage are synthetic. NOT EXECUTED.
final class BackupNativeFixture {
  static const approvedRoot = r'C:\Users\Даниил\AppData\Local\Temp\opencode';
  static const private = 'SYNTHETIC_BACKUP_PRIVATE_CANARY';
  final redactor = SecretRedactor(knownSecrets: const [private]);
  final storage = FakeCredentialStorage();
  final dialog = BackupSyntheticFileDialog();
  final token = CancelToken();
  late Directory directory;
  late String sourcePath, destinationPath;
  late sqlite.Database writer;
  late AppDatabase db;
  late SupportRepo support;
  late BackupOriginalReadRoot root;
  late ProviderContainer container;
  late GoRouter router;
  late BuildContext screenContext;
  late SupportBackupNativeUi ui;
  late SupportBackupNativeFileHost host;
  late SupportAppActionRegistry registry;
  late SupportAppActionContext original;
  bool ownerCurrent = true, uiCurrent = true;
  bool hostAvailable = true;
  AppDatabase? providerDb;
  bool created = false, opened = false, graph = false, mountedUi = false;
  bool rootReady = false, routerReady = false;
  bool databaseReady = false, _closed = false;
  Future<void>? _databaseClose;
  final _actions = <BackupOriginalAction>[];
  final _rootGates = <Completer<void>>[];
  int _auxiliaryOwners = 0;
  BackupNativePhaseProbe? phaseProbe;
  int get actionCount => _actions.length;
  int get settledActionCount => _actions.where((action) => action.done).length;
  bool get actionsSettled => _actions.every((action) => action.done);
  bool get auxiliaryOwnersReleased => _auxiliaryOwners == 0;
  List<int> sourceBefore = [], walBefore = [];

  Future<void> initialize() async {
    directory = await Directory(approvedRoot).createTemp('backup-control-');
    created = true;
    sourcePath = p.join(directory.path, 'original.db');
    destinationPath = p.join(directory.path, 'local-backup.db');
    writer = sqlite.sqlite3.open(sourcePath);
    opened = true;
    writer.execute('PRAGMA journal_mode=WAL');
    writer.execute('PRAGMA wal_autocheckpoint=0');
    writer.execute('PRAGMA busy_timeout=0');
    db = AppDatabase.openedNative(writer, closeUnderlyingOnClose: false);
    databaseReady = true;
    expect(db.nativeDataSourceIdentity, isNull);
    await db.customSelect('SELECT 1').get();
    expect(
      db.allTables.length,
      64,
    ); // Schema 138 adds three local derived tables.
    expect(db.nativeDataSourceIdentity!.belongsTo(db), isTrue);
    final cipher = SupportPayloadCipher(
      vault: CredentialVault(
        storage: storage,
        buildChannel: 'synthetic_backup_control',
      ),
      cipher: TextContextControlledCipher(),
    );
    support = SupportRepo(db, cipher);
    await support.createSession(
      const SupportSession(
        id: 'backup-session',
        title: 'Synthetic local save',
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    await support.putMessage(
      const SupportMessage(
        id: 'native-input',
        sessionId: 'backup-session',
        role: 'user',
        body: 'Save the whole original database locally',
        createdAt: 2,
      ),
    );
    final reader = SupportTextContextRepo(
      db: db,
      cipher: cipher,
      currentRedactor: () => redactor,
      admissionContract:
          SupportTextAdmissionContract.auditedRootSingleConnectionNoBusyHandler,
    );
    root = BackupOriginalReadRoot(
      db,
      support,
      reader,
      await reader.loadCurrentInput(
        sessionId: 'backup-session',
        messageId: 'native-input',
      ),
    );
    root.phaseProbe = phaseProbe;
    rootReady = true;
    writer.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    writer.execute('BEGIN');
    writer.execute(
      'INSERT INTO characters (char_id,name,description) VALUES (?,?,?)',
      ['private-character', private, private],
    );
    writer.execute(
      'INSERT INTO character_folders (folder_id,name) VALUES (?,?)',
      ['private-folder', private],
    );
    writer.execute('INSERT INTO preset_folders (folder_id,name) VALUES (?,?)', [
      'private-preset-folder',
      private,
    ]);
    writer.execute(
      'INSERT INTO api_configs (config_id,name,api_key) VALUES (?,?,?)',
      ['private-api', private, 'synthetic-credential-$private'],
    );
    writer.execute(
      'INSERT INTO support_context_blocks '
      '(id,session_id,start_message_id,end_message_id,summary_ciphertext) VALUES (?,?,?,?,?)',
      [
        'private-context',
        'backup-session',
        'a',
        'b',
        'synthetic-ciphertext-$private',
      ],
    );
    writer.execute(
      'INSERT INTO support_mutation_journal '
      '(id,session_id,domain,target_id,before_ciphertext,after_ciphertext) VALUES (?,?,?,?,?,?)',
      [
        'private-journal',
        'backup-session',
        'synthetic',
        'target',
        'synthetic-before-$private',
        'synthetic-after-$private',
      ],
    );
    writer.execute(
      'CREATE TABLE backup_extra (id INTEGER PRIMARY KEY, body BLOB NOT NULL)',
    );
    writer.execute('INSERT INTO backup_extra VALUES (?,?)', [
      1,
      private.codeUnits,
    ]);
    writer.execute('CREATE INDEX backup_extra_index ON backup_extra(body)');
    writer.execute(
      'CREATE VIEW backup_extra_view AS SELECT id FROM backup_extra',
    );
    writer.execute(
      'CREATE TRIGGER backup_extra_trigger AFTER INSERT ON backup_extra BEGIN SELECT 1; END',
    );
    writer.execute('COMMIT');
    // Rebind the readpoint AFTER seed commits. No speculative stale acceptance.
    root.snapshot = await reader.loadCurrentInput(
      sessionId: 'backup-session',
      messageId: 'native-input',
    );
    sourceBefore = await File(sourcePath).readAsBytes();
    walBefore = await File('$sourcePath-wal').readAsBytes();
    expect(walBefore, isNotEmpty);
    SharedPreferences.setMockInitialValues({
      'batterySaverMode': 'on',
      'hapticFeedback': false,
      'messageVibration': false,
    });
    final prefs = await SharedPreferences.getInstance();
    final theme = ThemeNotifier(storage: AppControlMemoryTheme());
    container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWith((ref) => providerDb ?? db),
        supportAppBackupNativeFileHostProvider.overrideWith(
          (ref) => hostAvailable ? host : null,
        ),
        sharedPreferencesProvider.overrideWith((ref) async => prefs),
        appSettingsProvider.overrideWith(
          () => AppControlSettingsNotifier(prefs),
        ),
        themeProvider.overrideWith((ref) => theme),
        nativeProviderAdapterFactoryProvider.overrideWith(
          (ref) => throw StateError(
            'No native HTTP adapter in local backup fixture',
          ),
        ),
      ],
    );
    graph = true;
    await container.read(appSettingsProvider.future);
    container.read(themeProvider);
    await theme.flushPersistence();
    router = GoRouter(
      initialLocation: '/backup',
      routes: [
        GoRoute(
          path: '/backup',
          builder: (context, _) {
            screenContext = context;
            return const SizedBox.expand();
          },
        ),
        GoRoute(
          path: '/replacement',
          builder: (_, _) => const SizedBox.expand(),
        ),
      ],
    );
    routerReady = true;
  }

  Widget widget() => UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      routerConfig: router,
      builder: (context, child) => FlatBackdrop(
        color: Theme.of(context).colorScheme.surface,
        child: child!,
      ),
    ),
  );

  void attach({bool noHost = false, AppDatabase? providerDatabase}) {
    ui = SupportBackupNativeUi(
      context: screenContext,
      isOriginalUiCurrent: () => uiCurrent,
      fileDialog: dialog,
    );
    mountedUi = true;
    final probe = phaseProbe;
    host = SupportBackupNativeFileHost(
      ui: probe == null ? ui : _BackupObservedNativeUi(ui, probe),
    );
    hostAvailable = !noHost;
    providerDb = providerDatabase;
    rebuildRegistry();
    original = SupportAppActionContext(
      runId: 'original-backup-run',
      sessionId: 'backup-session',
      cancelToken: token,
      isCurrent: () => ownerCurrent,
      allowReversibleChanges: false,
      confirmation: host,
      domainRoot: root,
    );
    root.original = original;
  }

  void rebuildRegistry() {
    registry = SupportAppActionRegistry(
      adapters: container.read(supportAppControlBackupAdaptersProvider),
      metadata: SupportAppRedactedMetadataPolicy(
        currentRedactor: () => redactor,
      ),
      isOriginalOwnerCurrent: () => ownerCurrent,
    );
  }

  Future<NativeToolResult> call([Map<String, Object?> args = const {}]) {
    final pending = registry.execute(
      NativeToolCall(
        id: 'backup-call',
        name: SupportBackupNativeFileHost.action,
        arguments: args,
      ),
      original,
    );
    // Observe this ORIGINAL future immediately, before picker/modal/ROOT waits.
    // Return the original future unchanged; errors retain their original stack.
    _actions.add(BackupOriginalAction(pending));
    return pending;
  }

  BackupOriginalAction actionFor(Future<NativeToolResult> originalAction) =>
      _actions.firstWhere((action) => identical(action.future, originalAction));

  Future<T> real<T>(
    WidgetTester tester,
    BackupNativePhase phase,
    Future<T> Function() action,
  ) => phaseProbe?.real(tester, phase, action) ?? backupReal(tester, action);

  String get phaseCounters =>
      'picker=${dialog.choices} admissions=${rootReady ? root.admissions : 0} '
      'actions=$actionCount settled=$settledActionCount';

  Completer<void> holdRootGate() {
    final gate = Completer<void>();
    _rootGates.add(gate);
    return gate;
  }

  Future<void> expectSourceUnchanged() async {
    expect(await File(sourcePath).readAsBytes(), sourceBefore);
    expect(await File('$sourcePath-wal').readAsBytes(), walBefore);
    expect(
      writer.select('SELECT description FROM characters').single.values.single,
      private,
    );
  }

  void stopOriginalActions() {
    ownerCurrent = false;
    uiCurrent = false;
    if (!token.isCancelled) token.cancel();
    dialog.finishPending();
    if (rootReady) root.retired = true;
    for (final gate in _rootGates) {
      if (!gate.isCompleted) gate.complete();
    }
  }

  Future<void> drainOriginalActions(WidgetTester tester) async {
    final probe = phaseProbe;
    if (probe == null) {
      await backupPumpUntil(tester, () => actionsSettled);
    } else {
      await probe.wait(
        tester,
        BackupNativePhase.cleanup,
        () => actionsSettled,
        checkSignals: false,
      );
    }
    for (final action in _actions) {
      if (probe == null) {
        await action.settled;
      } else {
        await probe.real(
          tester,
          BackupNativePhase.cleanup,
          () => action.settled,
        );
      }
    }
    for (final action in _actions) {
      action.throwIfFailed();
    }
  }

  Future<void> closeDatabase() => _databaseClose ??= db.close();

  VoidCallback retainAuxiliaryOwner() {
    // Register only after actual construction/open; release only after the
    // original owner close(s) succeed. A timed-out callback cannot erase it.
    _auxiliaryOwners++;
    var released = false;
    return () {
      if (released) return;
      released = true;
      _auxiliaryOwners--;
    };
  }

  void requireSettledWorkBeforeClose({bool includeAuxiliaryOwners = false}) {
    if (!actionsSettled ||
        phaseProbe?.hasPendingRealWork == true ||
        includeAuxiliaryOwners && _auxiliaryOwners != 0) {
      throw phaseProbe?.boundedFailure(BackupNativePhase.cleanup) ??
          TestFailure('Original backup cleanup has unsettled work.');
    }
  }

  Future<void> close({bool doNotWaitForActions = false}) async {
    if (_closed) return;
    if (doNotWaitForActions && !actionsSettled) {
      throw TestFailure('Original backup cleanup has unsettled actions.');
    }
    _closed = true;
    final failure = BackupFixtureFailure();
    await failure.run(stopOriginalActions);
    // Every held picker/ROOT gate was released before this actual join. The
    // test wrapper pumps native route dismissal before closing the database.
    if (!doNotWaitForActions) {
      for (final action in _actions) {
        await action.settled;
      }
    }
    for (final action in _actions) {
      await failure.run(action.throwIfFailed);
    }
    if (mountedUi) {
      await failure.run(host.dispose);
      await failure.run(ui.dispose);
    }
    if (graph) await failure.run(container.dispose);
    if (routerReady) await failure.run(router.dispose);
    if (databaseReady) await failure.run(closeDatabase);
    if (opened) await failure.run(writer.close);
    if (created) {
      await failure.run(() async {
        await for (final entry in directory.list(followLinks: false)) {
          expect(p.dirname(entry.path), directory.path);
          if (entry is File || entry is Link) {
            await entry.delete();
          } else {
            fail('Unexpected non-flat synthetic backup fixture');
          }
        }
        await directory.delete();
      });
    }
    failure.throwIfAny();
  }
}

/// No permissive ROOT callback. Uses the ACTUAL original repo's audited ROOT
/// read transaction and exact retained input/readpoint, then releases the ROOT
/// before native file creation. This is a synthetic owning harness, not a model
/// service substitute or evidence for arbitrary executors.
final class BackupOriginalReadRoot
    implements SupportBackupOriginalDatabaseRoot {
  BackupOriginalReadRoot(this.db, this.support, this.reader, this.snapshot);
  final AppDatabase db;
  final SupportRepo support;
  final SupportTextContextRepo reader;
  SupportTextContextSnapshot snapshot;
  SupportAppActionContext? original;
  bool retired = false;
  int admissions = 0;
  Future<void> Function()? beforeAdmission;
  BackupNativePhaseProbe? phaseProbe;
  @override
  bool retainsBackupSource(
    NativeDataSourceIdentity source,
    SupportAppActionContext context,
  ) =>
      !retired &&
      identical(context, original) &&
      context.current &&
      source.belongsTo(db);
  @override
  Future<void> admitDomain(SupportAppDomainDispatch dispatch) async {
    throw StateError('Backup never consumes a source-mutation terminal permit');
  }

  @override
  Future<SupportBackupRootLease?> admitBackupFile(
    SupportBackupFileSelection selection,
    SupportAppActionContext context,
  ) {
    final probe = phaseProbe;
    return probe == null
        ? _admitBackupFile(selection, context)
        : probe
              ._start(
                BackupNativePhase.rootEffect,
                () => _admitBackupFile(selection, context),
              )
              .original;
  }

  Future<SupportBackupRootLease?> _admitBackupFile(
    SupportBackupFileSelection selection,
    SupportAppActionContext context,
  ) async {
    await beforeAdmission?.call();
    if (retired ||
        !identical(context, original) ||
        !context.current ||
        !selection.belongsToOriginalDatabase(db)) {
      return null;
    }
    SupportBackupRootLease? lease;
    final admitted = await reader.admitDispatch(
      snapshots: [snapshot],
      isCurrent: () =>
          !retired &&
          context.current &&
          selection.isCurrent &&
          db.nativeDataSourceIdentity?.belongsTo(db) == true,
      checkReadOnly: (checkpoint) async {
        final session = await support.getSessionById('backup-session');
        checkpoint();
        return session?.id == context.sessionId && session?.isLocked == false;
      },
      dispatch: () {
        lease = selection.admitOriginalSource(db);
      },
    );
    if (admitted) admissions++;
    return admitted && context.current && lease?.isCurrent == true
        ? lease
        : null;
  }
}

/// Exact synthetic framework SaveFile gesture. No default success/destination.
final class BackupSyntheticFileDialog implements SupportBackupFileDialog {
  Completer<String?>? _pending;
  int choices = 0;
  Future<void> Function()? onChoose;
  BackupNativePhaseProbe? phaseProbe;
  @override
  Future<String?> saveLocalDatabase() {
    final probe = phaseProbe;
    return probe == null
        ? _saveLocalDatabase()
        : probe._start(BackupNativePhase.picker, _saveLocalDatabase).original;
  }

  Future<String?> _saveLocalDatabase() async {
    choices++;
    _pending = Completer<String?>();
    await onChoose?.call();
    return _pending!.future;
  }

  void choose(String? syntheticPath) {
    final pending = _pending;
    if (pending == null || pending.isCompleted) {
      throw StateError('No original picker');
    }
    pending.complete(syntheticPath);
  }

  void finishPending() {
    final pending = _pending;
    if (pending != null && !pending.isCompleted) pending.complete(null);
  }
}

Future<T> backupReal<T>(
  WidgetTester tester,
  FutureOr<T> Function() action,
) async {
  late T result;
  Object? failure;
  StackTrace? stack;
  await tester.runAsync(() async {
    try {
      result = await action();
    } catch (error, trace) {
      failure = error;
      stack = trace;
    }
  });
  if (failure != null) Error.throwWithStackTrace(failure!, stack!);
  return result;
}

Future<void> backupPumpUntil(
  WidgetTester tester,
  bool Function() ready, {
  BackupOriginalAction? action,
  BackupNativePhaseProbe? probe,
  BackupNativePhase phase = BackupNativePhase.join,
}) async {
  if (probe != null) {
    return probe.wait(tester, phase, ready, action: action);
  }
  for (var i = 0; i < 512; i++) {
    action?.throwIfFailed();
    if (ready()) return;
    if (action?.done == true) {
      throw TestFailure(
        'Original native action completed before its expected signal.',
      );
    }
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  action?.throwIfFailed();
  expect(
    ready(),
    isTrue,
    reason: 'Original synthetic native signal did not complete',
  );
}

Future<void> backupModal(
  WidgetTester tester, {
  BackupOriginalAction? action,
  BackupNativePhaseProbe? probe,
}) async {
  final button = find.byKey(
    const ValueKey('support_backup_confirmation_accept'),
  );
  await backupPumpUntil(
    tester,
    () => button.evaluate().isNotEmpty,
    action: action,
    probe: probe,
    phase: BackupNativePhase.modal,
  );
  final route = ModalRoute.of(tester.element(button))!;
  if (probe == null) {
    await tester.pump();
    await tester.pump(route.transitionDuration);
  } else {
    await probe.frame(tester, BackupNativePhase.modal, tester.pump);
    await probe.frame(
      tester,
      BackupNativePhase.modal,
      () => tester.pump(route.transitionDuration),
    );
  }
  expect(button.hitTestable(), findsOneWidget);
}

Future<void> backupDecision(
  WidgetTester tester,
  String decision, {
  BackupNativePhaseProbe? probe,
}) async {
  final button = find.byKey(ValueKey('support_backup_confirmation_$decision'));
  final route = ModalRoute.of(tester.element(button))!;
  if (probe == null) {
    await backupReal(tester, () => tester.tap(button));
    await tester.pump();
    await tester.pump(route.reverseTransitionDuration);
  } else {
    await probe.real(tester, BackupNativePhase.modal, () => tester.tap(button));
    await probe.frame(tester, BackupNativePhase.modal, tester.pump);
    await probe.frame(
      tester,
      BackupNativePhase.modal,
      () => tester.pump(route.reverseTransitionDuration),
    );
  }
}

Future<NativeToolResult> backupJoin(
  WidgetTester tester,
  Future<NativeToolResult> pending, {
  BackupNativePhaseProbe? probe,
}) async {
  if (probe != null) return probe.join(tester, pending);
  final action = BackupOriginalAction(pending);
  await backupPumpUntil(tester, () => action.done, action: action);
  await action.settled;
  return action.result;
}

/// Test-only observation, never a replacement native action or success future.
final class BackupOriginalAction {
  BackupOriginalAction(this.future) {
    settled = future.then<void>(
      (value) {
        _result = value;
        done = true;
      },
      onError: (Object error, StackTrace stack) {
        _failure = error;
        _stack = stack;
        done = true;
      },
    );
  }
  final Future<NativeToolResult> future;
  late final Future<void> settled;
  NativeToolResult? _result;
  Object? _failure;
  StackTrace? _stack;
  bool done = false;
  void throwIfFailed() {
    if (_failure != null) Error.throwWithStackTrace(_failure!, _stack!);
  }

  NativeToolResult get result {
    throwIfFailed();
    if (!done) throw StateError('Original native action is not settled.');
    return _result!;
  }
}

/// Finish exact fixture cleanup, then rethrow the FIRST original failure/stack.
final class BackupFixtureFailure {
  Object? _error;
  StackTrace? _stack;
  Future<void> run(FutureOr<void> Function() action) async {
    try {
      await action();
    } catch (error, stack) {
      if (_error == null) {
        _error = error;
        _stack = stack;
      }
    }
  }

  void throwIfAny() {
    if (_error != null) Error.throwWithStackTrace(_error!, _stack!);
  }
}

enum BackupNativePhase {
  initialize,
  mount,
  invoke,
  picker,
  modal,
  rootEffect,
  join,
  cleanup,
}

/// Observation-only forwarding: the ACTUAL native UI still creates the modal,
/// checks currentness and returns its original lease/future without alteration.
final class _BackupObservedNativeUi implements SupportBackupFileUi {
  _BackupObservedNativeUi(this.original, this.probe);
  final SupportBackupNativeUi original;
  final BackupNativePhaseProbe probe;
  @override
  bool get isCurrent => original.isCurrent;
  @override
  Future<String?> chooseLocalFile(SupportAppActionContext context) =>
      original.chooseLocalFile(context);
  @override
  Future<SupportAppConfirmationLease?> confirmLocalFile(
    SupportAppConfirmationRequest request,
    String destination,
    String disclosure,
  ) => probe
      ._start(
        BackupNativePhase.modal,
        () => original.confirmLocalFile(request, destination, disclosure),
      )
      .original;
}

typedef _BackupPhaseObservation<T> = ({
  Future<T> original,
  bool Function() done,
  T Function() value,
  void Function() check,
});

/// Opt-in diagnostic only. Originals keep their identity and original error
/// stacks; runAsync returns a record, never awaits work that needs widget frames.
/// Fixed labels/counters are the only diagnostic output. ROOT-effect observes
/// the exposed original admission, NOT an invented internal snapshot checkpoint.
final class BackupNativePhaseProbe {
  BackupNativePhaseProbe(this.fixture);
  final BackupNativeFixture fixture;
  final _signals =
      <BackupNativePhase, ({bool Function() done, void Function() check})>{};
  // All real-work observations, including later calls in the same phase. A
  // pending file/auxiliary-DB future must prevent deletion beneath its owner.
  final _realWork = <bool Function()>[];
  bool get hasPendingRealWork => _realWork.any((done) => !done());

  void _emit(BackupNativePhase phase, String state) {
    final label = phase == BackupNativePhase.rootEffect
        ? 'ROOT-effect'
        : phase.name;
    debugPrintSynchronously(
      'backup-native phase=$label state=$state ${fixture.phaseCounters}',
    );
  }

  _BackupPhaseObservation<T> _start<T>(
    BackupNativePhase phase,
    Future<T> Function() createOriginal, {
    bool retain = true,
  }) {
    _emit(phase, 'entered');
    final original = createOriginal();
    var done = false;
    T? value;
    Object? error;
    StackTrace? stack;
    void check() {
      if (error != null) Error.throwWithStackTrace(error!, stack!);
    }

    original.then<void>(
      (result) {
        value = result;
        done = true;
        _emit(phase, 'settled-value');
      },
      onError: (Object failure, StackTrace trace) {
        error = failure;
        stack = trace;
        done = true;
        _emit(phase, 'settled-error');
      },
    );
    // Auxiliary frame/I/O observations must not overwrite the actual original
    // native modal/picker/ROOT phase while it is pending (or hide its error).
    if (retain) {
      _signals.putIfAbsent(phase, () => (done: () => done, check: check));
    }
    return (
      original: original,
      done: () => done,
      value: () {
        check();
        if (!done) throw boundedFailure(phase);
        return value as T;
      },
      check: check,
    );
  }

  bool started(BackupNativePhase phase) => _signals.containsKey(phase);

  bool settled(BackupNativePhase phase) => _signals[phase]?.done() == true;

  TestFailure boundedFailure(BackupNativePhase phase) {
    _emit(phase, 'bounded-unsettled');
    return TestFailure(
      'Original backup phase=${phase.name} exceeded finite frame budget; '
      '${fixture.phaseCounters}',
    );
  }

  Future<T> real<T>(
    WidgetTester tester,
    BackupNativePhase phase,
    Future<T> Function() createOriginal,
  ) async {
    Object? synchronousError;
    StackTrace? synchronousStack;
    final record = await tester.runAsync(() async {
      _BackupPhaseObservation<T>? observation;
      try {
        observation = _start(phase, createOriginal);
        _realWork.add(observation.done);
      } catch (error, stack) {
        synchronousError = error;
        synchronousStack = stack;
        _emit(phase, 'settled-error');
      }
      return (observation: observation);
    });
    if (synchronousError != null) {
      Error.throwWithStackTrace(synchronousError!, synchronousStack!);
    }
    final observation = record?.observation;
    if (observation == null) throw boundedFailure(phase);
    return _settle(tester, phase, observation);
  }

  // Framework futures start in the widget test's own fake-async zone. Capture
  // them immediately, then hand the observer back through the same record path.
  Future<T> frame<T>(
    WidgetTester tester,
    BackupNativePhase phase,
    Future<T> Function() createOriginal,
  ) async {
    final observation = _start(phase, createOriginal, retain: false);
    final record = await tester.runAsync(
      () async => (observation: observation),
    );
    if (record == null) throw boundedFailure(phase);
    return _settle(tester, phase, record.observation);
  }

  Future<T> _settle<T>(
    WidgetTester tester,
    BackupNativePhase phase,
    _BackupPhaseObservation<T> observation,
  ) async {
    for (var frame = 0; frame < 512; frame++) {
      observation.check();
      if (observation.done()) return observation.value();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      observation.check();
      if (observation.done()) return observation.value();
      await tester.pump(const Duration(milliseconds: 16));
    }
    observation.check();
    if (observation.done()) return observation.value();
    throw boundedFailure(phase);
  }

  Future<void> wait(
    WidgetTester tester,
    BackupNativePhase phase,
    bool Function() ready, {
    BackupOriginalAction? action,
    bool checkSignals = true,
  }) async {
    _emit(phase, 'entered');
    void check() {
      if (!checkSignals) return;
      action?.throwIfFailed();
      for (final signal in _signals.values) {
        signal.check();
      }
    }

    for (var frame = 0; frame < 512; frame++) {
      check();
      if (ready()) {
        _emit(phase, 'observed');
        return;
      }
      if (action?.done == true) {
        throw TestFailure(
          'Original backup phase=${phase.name} missed its signal; ${fixture.phaseCounters}',
        );
      }
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    check();
    if (ready()) {
      _emit(phase, 'observed');
      return;
    }
    throw boundedFailure(phase);
  }

  Future<NativeToolResult> join(
    WidgetTester tester,
    Future<NativeToolResult> original,
  ) async {
    // Reuse the immediate ORIGINAL registry observer rather than a new action
    // or synthetic completion. ROOT admission and action settlement stay distinct.
    final action = fixture.actionFor(original);
    await wait(
      tester,
      BackupNativePhase.join,
      () => action.done,
      action: action,
    );
    return action.result;
  }

  Future<void> cleanup(
    WidgetTester tester,
    BackupFixtureFailure failure,
  ) async {
    await failure.run(fixture.stopOriginalActions);
    await failure.run(
      () => wait(
        tester,
        BackupNativePhase.cleanup,
        () =>
            fixture.actionsSettled &&
            !hasPendingRealWork &&
            fixture.auxiliaryOwnersReleased,
        checkSignals: false,
      ),
    );
    if (fixture.actionsSettled) {
      for (final action in fixture._actions) {
        await failure.run(action.throwIfFailed);
      }
    }
    await failure.run(
      () => frame(
        tester,
        BackupNativePhase.cleanup,
        () => tester.pumpWidget(const SizedBox.shrink()),
      ),
    );
    await failure.run(
      () => frame(tester, BackupNativePhase.cleanup, tester.pump),
    );
    await failure.run(() async {
      // Do not close/delete beneath a still-running initializer or action, and
      // never join that broken work unboundedly inside runAsync. Retention here
      // is an honest bounded failure, not proof of ROOT deadlock or safe cleanup.
      if (!settled(BackupNativePhase.initialize) || !fixture.actionsSettled) {
        throw boundedFailure(BackupNativePhase.cleanup);
      }
      fixture.requireSettledWorkBeforeClose(includeAuxiliaryOwners: true);
      await real(
        tester,
        BackupNativePhase.cleanup,
        () => fixture.close(doNotWaitForActions: true),
      );
    });
  }
}
