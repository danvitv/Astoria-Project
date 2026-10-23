import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_runtime.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_theme_evidence_codec.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_theme_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/features/support_assistant/support_assistant_screen.dart';
import 'package:glaze_flutter/shared/shell/nav_height_provider.dart';
import 'package:glaze_flutter/shared/shell/shell_header_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_font_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';
import 'package:glaze_flutter/shared/widgets/glass_surface.dart';

import '../credentials/fake_credential_storage.dart';
import '../theme_selection_test_store.dart';
import 'helpers/support_mutation_journal_fixture.dart';
import 'support_theme_provider_fixture.dart' show checkThemeProviderSql;
import 'support_theme_provider_theme.dart';
import 'support_theme_provider_vault.dart';
import 'support_theme_screen_isolation.dart';
import 'support_theme_screen_turns.dart';

export '../theme_selection_test_store.dart';
export 'helpers/support_mutation_journal_fixture.dart' show JournalBarrier;
export 'support_theme_screen_turns.dart' show ThemeScreenSignal;

/// Fixed, payload-free labels for the single opt-in deletion observation.
enum ThemeScreenCheckpoint {
  fixtureRun,
  platformScope,
  initialization,
  mount,
  body,
  gateRelease,
  unmount,
  unmountPump,
  custodyDrain,
  custodyDrainSignal,
  containerDispose,
  modelDrain,
  modelDrainSignal,
  routerDispose,
  themeDispose,
  themeDelayRelease,
  databaseClose,
  databaseCloseSignal,
  redactionDispose,
  finalPump,
  exceptionCheck,
  platformCleanup,
  decisionSignal,
  decisionGesture,
  decisionFinish,
  decisionResult,
  workspaceIdentityBeforeDecision,
  workspaceIdentityBeforeJoin,
  workspaceIdentityAfterJoin,
  workspaceRefreshSignal,
  workspaceRefreshFinish,
  workspaceRefreshResult,
  postDeleteSettle,
  postDeleteBaseline,
  deleteBlockedRendered,
}

enum ThemeScreenObservationPhase { before, after, done, error, value }

/// NEW actual screen/C/P/S/H/workspace graph, real ThemeNotifier over independent
/// backing, declared memory DB and SAME fake-vault AEAD. NO model/action facade.
final class ThemeScreenFixture {
  ThemeScreenFixture({
    this.permissions = true,
    this.configured = false,
    this.observeDeletion = false,
  });
  static const session = 'theme-screen-session', other = 'theme-screen-other';
  final bool permissions;
  final bool configured;
  final bool observeDeletion;
  final isolation = ThemeScreenIsolation();
  late final JournalMemoryDatabase db;
  late final ScreenThemeSql sql;
  late final JournalControlledCipher primitive;
  late final FakeCredentialStorage storage;
  late final CredentialVault vault;
  late final SupportPayloadCipher cipher;
  late final SupportRepo repo;
  late final SecretRedactionCoordinator redaction;
  late final ThemeSelectionBacking backing;
  late final ThemeProviderTheme theme;
  late final ProviderContainer container;
  late final GoRouter router;
  final barriers = <JournalBarrier>[];
  final gates = <ThemeSelectionGate>[];
  final custodies = <SupportThemeActionCustody>{};
  final bridges = <SupportModelUiBridge>{};
  bool _active = false, _dbCreated = false, _containerCreated = false;
  bool _routerCreated = false, disposed = false;
  bool _themeCreated = false, _dbClosed = false;
  bool _composed = false;
  late final turns = ThemeScreenTurns(
    guarded: isolation.guarded,
    active: () => _active,
  );
  SupportWorkspaceNotifier get workspace =>
      container.read(supportWorkspaceProvider.notifier);
  SupportWorkspaceState get state => container.read(supportWorkspaceProvider);
  SupportNativeRuntime get runtime =>
      container.read(supportNativeRuntimeProvider);
  SupportNativeConsentController get controller =>
      container.read(supportNativeConsentControllerProvider);
  SupportThemeUiBinding get binding =>
      container.read(supportThemeUiBindingProvider);

  /// Synchronous fixed-label output only; never formats a result or error.
  void observe(
    ThemeScreenCheckpoint checkpoint,
    ThemeScreenObservationPhase phase, {
    bool? value,
  }) {
    if (!observeDeletion) return;
    debugPrintSynchronously(
      'support_theme_screen_observation ${checkpoint.name} ${phase.name}'
      '${value == null ? '' : ' $value'}',
    );
  }

  /// All asynchronous owners and FIFOs are created ONLY in guarded REAL init.
  Future<void> initialize() async {
    if (_composed) throw StateError('Owned screen composition is one-shot.');
    _composed = true;
    sql = ScreenThemeSql(isolation.block);
    primitive = JournalControlledCipher();
    storage = FakeCredentialStorage();
    redaction = SecretRedactionCoordinator();
    db = JournalMemoryDatabase(NativeDatabase.memory().interceptWith(sql));
    _dbCreated = true;
    final guardedStorage = ThemeProviderVaultStorage(storage, isolation.block);
    vault = CredentialVault(
      storage: guardedStorage,
      buildChannel: 'theme_provider_test',
    );
    cipher = SupportPayloadCipher(vault: vault, cipher: primitive);
    repo = SupportRepo(db, cipher);
    backing = ThemeSelectionBacking(
      presets: const [
        ThemePreset(
          id: 'a',
          name: 'A full installed label',
          themeMode: 'dark',
          accentColor: '#102030',
          uiFontMode: 'system',
          chatFontMode: 'system',
          noiseOpacity: 0,
        ),
        ThemePreset(
          id: 'b',
          name: 'B distinguishing installed label',
          themeMode: 'light',
          accentColor: '#112233',
          uiFontMode: 'system',
          chatFontMode: 'system',
          noiseOpacity: 0,
        ),
        ThemePreset(
          id: 'c',
          name: 'C full installed label',
          accentColor: '#445566',
          uiFontMode: 'system',
          chatFontMode: 'system',
          noiseOpacity: 0,
        ),
      ],
    );
    theme = ThemeProviderTheme(backing);
    _themeCreated = true;
    isolation.controls.addAll([_cipherOwner]);
    container = ProviderContainer(
      observers: [isolation],
      overrides: [
        appDbProvider.overrideWithValue(db),
        _cipherOwner.overrideWith(() => _CipherOwner(cipher)),
        supportPayloadCipherProvider.overrideWith(
          (ref) => ref.watch(_cipherOwner),
        ),
        credentialStorageProvider.overrideWithValue(guardedStorage),
        credentialVaultProvider.overrideWithValue(vault),
        secretRedactionCoordinatorProvider.overrideWithValue(redaction),
        apiConfigRepoProvider.overrideWith(
          (ref) => ApiConfigRepo(ref.watch(appDbProvider)),
        ),
        themeProvider.overrideWith((ref) {
          ref.onDispose(() => theme.providerDisposed = true);
          return theme.notifier;
        }),
        // Concrete pre-evaluation default/private/startup denials.
        sharedPreferencesProvider.overrideWith(
          (_) => isolation.block('default preferences'),
        ),
        apiConfigCredentialAdapterProvider.overrideWith(
          (_) => isolation.block('API credentials'),
        ),
        supportConnectionMetadataProvider.overrideWith(
          (_) => isolation.block('connection metadata'),
        ),
        // Empty chooser presentation only: actual API repo SQL stays denied.
        supportConnectionsProvider.overrideWithValue(const []),
        if (!configured)
          supportModelUiBridgeProvider.overrideWith(
            (_) => isolation.block('model bridge'),
          ),
        supportModelPrivateAdapterFactoryProvider.overrideWithValue(
          () => isolation.block('model adapter creation'),
        ),
        llmRequestCaptureInstallationProvider.overrideWith(
          (_) => isolation.block('capture startup'),
        ),
        imageStorageProvider.overrideWith(
          (_) => isolation.block('image startup'),
        ),
        migrationServiceProvider.overrideWith(
          (_) => isolation.block('default migration'),
        ),
        appSettingsProvider.overrideWith(
          () => _VisualSettings(isolation.block),
        ),
        effectiveBgImageBytesProvider.overrideWithValue(null),
        bgImageBytesProvider.overrideWith(
          (_) => isolation.block('background resources'),
        ),
        wallpaperBytesProvider.overrideWith(
          (_) => isolation.block('wallpaper resources'),
        ),
        uiFontFamilyProvider.overrideWith((_) async => null),
        chatFontFamilyProvider.overrideWith((_) async => null),
        navHeightProvider.overrideWith((_) => 0),
        shellHeaderProvider.overrideWith(ShellHeaderRegistry.new),
      ],
    );
    _containerCreated = true;
    router = GoRouter(
      initialLocation: '/support',
      routes: [
        GoRoute(
          path: '/support',
          builder: (_, _) => const SupportAssistantScreen(
            welcomeAvatar: Icon(Icons.support_agent),
          ),
        ),
        GoRoute(path: '/characters', builder: (_, _) => const SizedBox()),
        GoRoute(
          path: '/menu/themes',
          builder: (_, _) => const Text('ordinary-theme-escape'),
        ),
        GoRoute(
          path: '/tools/api',
          builder: (_, _) => isolation.block('API navigation'),
        ),
      ],
    );
    _routerCreated = true;
    await db.customSelect('SELECT 1').getSingle();
    for (final id in [session, other]) {
      await repo.createSession(
        SupportSession(
          id: id,
          title: 'Synthetic $id',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
    }
    if (configured) {
      await container
          .read(supportSessionStoreProvider)
          .changeSettings(
            session,
            (_) => const SupportAssistantSettings(
              apiConfigId: 'unresolved-synthetic-api',
              modelId: 'unconfirmed-synthetic-model',
            ),
          );
    }
    await theme.notifier.flushPersistence();
    await container.read(appSettingsProvider.future);
    workspace;
    await container.pump();
    await workspace.refresh();
    workspace.selectSession(session);
    await workspace.refresh();
    // Workspace creates missing permission rows with default OFF. Never seed
    // grants through a fake provider: use actual local C only when requested.
    await runtime.refresh(resolve: false);
    if (permissions) await enableTheme();
    custodies.add(container.read(supportThemeActionCustodyProvider));
    binding;
    if (configured) {
      // Real inert model owner, eagerly composed in the REAL guarded init. The
      // adapter factory is a tripwire; no model recipient/API lookup is allowed.
      bridges.add(container.read(supportModelUiBridgeProvider));
      container.read(supportModelRunViewProvider);
    }
  }

  Future<void> enableTheme() async {
    final scope = (await controller.prepareReview(resolveRecipient: false))!;
    expect(await controller.selectTheme(scope, true), isTrue);
    for (final right in [
      SupportPermission.readSafeSettings,
      SupportPermission.confirmedSettingsChanges,
    ]) {
      final review = (await controller.prepareReview(resolveRecipient: false))!;
      expect(await controller.setGrant(review, right, true), isTrue);
    }
  }

  Future<void> replaceCipher() async {
    container
        .read(_cipherOwner.notifier)
        .replace(SupportPayloadCipher(vault: vault, cipher: primitive));
    custodies.add(container.read(supportThemeActionCustodyProvider));
    binding;
    await container.pump();
    await workspace.refresh();
    workspace.selectSession(session);
    await workspace.refresh();
    await runtime.refresh(resolve: false);
  }

  JournalBarrier barrier() {
    final value = JournalBarrier();
    barriers.add(value);
    return value;
  }

  ThemeSelectionGate gate() {
    final value = ThemeSelectionGate();
    gates.add(value);
    return value;
  }

  Future<void> seedHistory({
    int count = 1,
    String status = 'applied',
    bool unknown = false,
  }) async {
    const codec = SupportThemeEvidenceCodec();
    for (var i = 0; i < count; i++) {
      String evidence(String id, String name) => unknown
          ? SupportMutationEvidence.encode('{"v":99}')
          : codec.encode(
              sessionId: session,
              value: SupportThemeValue(
                id: id,
                name: name,
                mode: 'dark',
                accent: '#112233',
                active: true,
              ),
              policy: redaction.redactor,
            )!;
      await repo.putMutation(
        SupportMutationRecord(
          id: 'restored-${i.toString().padLeft(3, '0')}',
          sessionId: session,
          domain: SupportThemeEvidenceCodec.domain,
          targetId: SupportThemeEvidenceCodec.target,
          status: status,
          createdAt: 5,
          beforeJson: evidence('a', 'Restored A'),
          afterJson: evidence('b', 'Restored B'),
        ),
      );
    }
  }

  Future<String> baseline() async {
    final tables = <String, Object>{};
    for (final table in [
      'support_sessions',
      'support_messages',
      'support_context_blocks',
      'support_mutation_journal',
      'support_reports',
    ]) {
      tables[table] =
          (await db.customSelect('SELECT * FROM $table ORDER BY rowid').get())
              .map((r) => r.data)
              .toList();
    }
    return jsonEncode({
      'tables': tables,
      'theme': backing.presets.map((p) => p.toJson()).toList(),
      'active': backing.activeId,
      'vault': storage.values,
    });
  }

  Future<void> closeDatabase() async {
    if (_dbClosed) return;
    _dbClosed = true;
    await db.close();
  }

  Future<T> action<T>(WidgetTester tester, FutureOr<T> Function() issue) =>
      turns.action(tester, issue);

  Future<void> gesture(WidgetTester tester, Future<void> Function() issue) =>
      turns.gesture(tester, issue);

  Future<ThemeScreenSignal<T>> signal<T>(
    WidgetTester tester,
    Future<T> Function() issue, {
    required String label,
    ThemeScreenCheckpoint? observation,
  }) => turns.signal(
    tester,
    issue,
    label: label,
    beforeIssue: observation == null
        ? null
        : () => observe(observation, ThemeScreenObservationPhase.before),
    afterIssue: observation == null
        ? null
        : () => observe(observation, ThemeScreenObservationPhase.after),
    onObserved: observation == null || !observeDeletion
        ? null
        : (failed) => observe(
            observation,
            failed
                ? ThemeScreenObservationPhase.error
                : ThemeScreenObservationPhase.done,
          ),
  );

  Future<T> finish<T>(WidgetTester tester, ThemeScreenSignal<T> signal) =>
      turns.finish(tester, signal);

  Widget host({double scale = 1}) => UncontrolledProviderScope(
    container: container,
    child: EasyLocalization(
      supportedLocales: const [Locale('en')],
      startLocale: const Locale('en'),
      saveLocale: false,
      path: 'owned-memory-translations',
      assetLoader: const _MemoryTranslations(),
      child: Builder(
        builder: (context) => MaterialApp.router(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xff506080),
            ),
          ),
          routerConfig: router,
          locale: context.locale,
          supportedLocales: context.supportedLocales,
          localizationsDelegates: context.localizationDelegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: FlatBackdrop(
              color: Theme.of(context).colorScheme.surface,
              child: child!,
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> run(WidgetTester tester, Future<void> Function() body) async {
    Object? failure;
    StackTrace? trace;
    Future<void> capture(
      FutureOr<void> Function() work, {
      ThemeScreenCheckpoint? checkpoint,
    }) async {
      if (checkpoint != null) {
        observe(checkpoint, ThemeScreenObservationPhase.before);
      }
      try {
        await work();
        if (checkpoint != null) {
          observe(checkpoint, ThemeScreenObservationPhase.after);
        }
      } catch (error, stack) {
        failure ??= error;
        trace ??= stack;
        if (checkpoint != null) {
          observe(checkpoint, ThemeScreenObservationPhase.error);
        }
      }
    }

    observe(
      ThemeScreenCheckpoint.fixtureRun,
      ThemeScreenObservationPhase.before,
    );
    await capture(
      () => isolation.run(() async {
        _active = true;
        try {
          // Library locale bookkeeping uses a synthetic in-memory mock only;
          // application prefs provider and ALL native prefs channels stay denied.
          await capture(
            () => turns.initialize(tester, () async {
              SharedPreferences.setMockInitialValues({});
              await EasyLocalization.ensureInitialized();
              await initialize();
            }),
            checkpoint: ThemeScreenCheckpoint.initialization,
          );
          if (failure == null) {
            observe(
              ThemeScreenCheckpoint.mount,
              ThemeScreenObservationPhase.before,
            );
            await tester.pumpWidget(host());
            await tester.pumpAndSettle();
            expect(find.byType(Image), findsNothing);
            expect(find.byType(RawImage), findsNothing);
            expect(find.byType(BackdropFilter), findsNothing);
            observe(
              ThemeScreenCheckpoint.mount,
              ThemeScreenObservationPhase.after,
            );
            await capture(body, checkpoint: ThemeScreenCheckpoint.body);
          }
        } finally {
          if (_dbCreated) {
            primitive.event = null;
            sql.event = null;
            db.afterCommit = null;
            storage.readError = null;
            storage.writeError = null;
            final originals = List.of(
              custodies,
            ); // BEFORE dispose, no late lookup.
            final modelOriginals = List.of(bridges);
            await capture(
              () => action(tester, () {
                for (final b in barriers) {
                  if (!b.release.isCompleted) b.release.complete();
                }
                for (final g in gates) {
                  if (!g.release.isCompleted) g.release.complete();
                }
              }),
              checkpoint: ThemeScreenCheckpoint.gateRelease,
            );
            await capture(
              () => tester.pumpWidget(const SizedBox.shrink()),
              checkpoint: ThemeScreenCheckpoint.unmount,
            );
            await capture(
              tester.pump,
              checkpoint: ThemeScreenCheckpoint.unmountPump,
            );
            for (final original in originals) {
              await capture(() async {
                final drained = await signal(
                  tester,
                  original.drain,
                  label: 'original action custody drain',
                  observation: ThemeScreenCheckpoint.custodyDrainSignal,
                );
                await finish(tester, drained);
              }, checkpoint: ThemeScreenCheckpoint.custodyDrain);
            }
            if (_containerCreated && !disposed) {
              await capture(
                () => action(tester, () {
                  container.dispose();
                  disposed = true;
                }),
                checkpoint: ThemeScreenCheckpoint.containerDispose,
              );
            }
            for (final original in modelOriginals) {
              await capture(() async {
                final drained = await signal(
                  tester,
                  () => original.drained,
                  label: 'original inert model owner drain',
                  observation: ThemeScreenCheckpoint.modelDrainSignal,
                );
                await finish(tester, drained);
              }, checkpoint: ThemeScreenCheckpoint.modelDrain);
            }
            if (_routerCreated) {
              await capture(
                () => action(tester, router.dispose),
                checkpoint: ThemeScreenCheckpoint.routerDispose,
              );
            }
            if (_themeCreated && !theme.providerDisposed) {
              await capture(
                () => action(tester, () {
                  theme.notifier.dispose();
                  theme.providerDisposed = true;
                }),
                checkpoint: ThemeScreenCheckpoint.themeDispose,
              );
            }
            if (_themeCreated) {
              await capture(
                () => action(tester, theme.releaseDelays),
                checkpoint: ThemeScreenCheckpoint.themeDelayRelease,
              );
            }
            await capture(() async {
              final closed = await signal(
                tester,
                closeDatabase,
                label: 'owned memory DB close',
                observation: ThemeScreenCheckpoint.databaseCloseSignal,
              );
              await finish(tester, closed);
            }, checkpoint: ThemeScreenCheckpoint.databaseClose);
            await capture(
              () => action(tester, redaction.dispose),
              checkpoint: ThemeScreenCheckpoint.redactionDispose,
            );
          }
          await capture(
            tester.pump,
            checkpoint: ThemeScreenCheckpoint.finalPump,
          );
          await capture(
            () => expect(tester.takeException(), isNull),
            checkpoint: ThemeScreenCheckpoint.exceptionCheck,
          );
          _active = false;
          // Handoff back to the existing isolation owner, not its internals.
          observe(
            ThemeScreenCheckpoint.platformCleanup,
            ThemeScreenObservationPhase.before,
          );
        }
      }),
      checkpoint: ThemeScreenCheckpoint.platformScope,
    );
    observe(
      ThemeScreenCheckpoint.platformCleanup,
      ThemeScreenObservationPhase.after,
    );
    observe(
      ThemeScreenCheckpoint.fixtureRun,
      ThemeScreenObservationPhase.after,
      value: failure != null,
    );
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  }
}

final _cipherOwner = NotifierProvider<_CipherOwner, SupportPayloadCipher>(
  () => throw StateError('Inject original synthetic cipher owner.'),
);

final class _CipherOwner extends Notifier<SupportPayloadCipher> {
  _CipherOwner(this.initial);
  final SupportPayloadCipher initial;
  @override
  SupportPayloadCipher build() => initial;
  void replace(SupportPayloadCipher value) => state = value;
}

class _VisualSettings extends AsyncNotifier<AppSettings>
    implements AppSettingsNotifier {
  _VisualSettings(this.block);
  final Never Function(String) block;
  @override
  Future<AppSettings> build() async => const AppSettings(
    batterySaver: true,
    batterySaverMode: BatterySaverMode.on,
    hapticFeedback: false,
    messageVibration: false,
    allowMessageScripts: false,
    showOurPicks: false,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      block('visual settings command');
}

class _MemoryTranslations extends AssetLoader {
  const _MemoryTranslations();
  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async => {
    'support_theme_name': 'Name: {}',
    'support_theme_id': 'ID: {}',
    'support_theme_mode': 'Preset mode: {}',
    'support_theme_mode_dark': 'dark',
    'support_theme_mode_light': 'light',
    'support_theme_mode_system': 'system',
    'support_theme_accent': 'Accent: {}',
    'support_theme_operation': 'Operation: {}',
    'support_theme_status': 'Read-time status: {}',
  };
}

final class ScreenThemeSql extends QueryInterceptor {
  ScreenThemeSql(this.block);
  final Never Function(String) block;
  final statements = <String>[];
  Future<void> Function(String)? event;
  void check(String statement) {
    statements.add(statement);
    checkThemeProviderSql(statement, block);
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    check(statement);
    final value = await super.runSelect(executor, statement, args);
    await event?.call('select:$statement');
    return value;
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    check(statement);
    return super.runInsert(executor, statement, args);
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    check(statement);
    final value = await super.runUpdate(executor, statement, args);
    await event?.call('update:$statement');
    return value;
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    check(statement);
    return super.runDelete(executor, statement, args);
  }

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    check(statement);
    return super.runCustom(executor, statement, args);
  }

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) => block('unexpected SQL batch');
}
