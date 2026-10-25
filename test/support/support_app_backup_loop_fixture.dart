import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/state/connection_revision_provider.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/core/state/character_folder_provider.dart';
import 'package:glaze_flutter/core/state/preset_folder_provider.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_text_context_repo.dart';
import 'package:glaze_flutter/core/llm/transport/native_tool_transport.dart';
import 'package:glaze_flutter/core/llm/transport/native_provider_transport.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_service.dart';
import 'package:glaze_flutter/features/chat/state/chat_native_owner_registry.dart';
import 'package:glaze_flutter/features/extensions/providers/extension_presets_provider.dart';
import 'package:glaze_flutter/features/memory/state/memory_active_drafts_provider.dart';
import 'package:glaze_flutter/features/memory/state/memory_book_revision_provider.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/features/support_assistant/support_assistant_screen.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_backup_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_content_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_session_memory_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_secondary_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_repair_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_native_domain_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_native_repair_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_dependencies.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_catalog_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/shared/shell/nav_height_provider.dart';
import 'package:glaze_flutter/shared/shell/shell_header_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_font_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';
import 'package:glaze_flutter/shared/widgets/glass_surface.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'app_control/app_control_fixture.dart' show AppControlSettingsNotifier;
import 'app_control/app_control_memory_theme.dart';
import 'helpers/support_model_provider_fixture_isolation.dart';
import 'support_app_backup_loop_native.dart';

export 'support_app_backup_loop_native.dart';
export 'package:glaze_flutter/features/support_assistant/state/support_app_control_backup_provider.dart';
export 'package:glaze_flutter/features/support_assistant/state/support_app_control_provider.dart';

void backupLoopTest(
  String name,
  Future<void> Function(WidgetTester, BackupLoopFixture) body, {
  bool memory = false,
  bool foreignSource = false,
}) {
  testWidgets(name, (tester) async {
    final io = BackupLoopIo();
    final f = BackupLoopFixture(io);
    final failure = BackupLoopFailure();
    final messenger = tester.binding.defaultBinaryMessenger;
    final previous = messenger.allMessagesHandler;
    SharedPreferences.setMockInitialValues({});
    await backupLoopReal(tester, EasyLocalization.ensureInitialized);
    // Only test input and finite framework UI metadata, never OS picker/vault.
    messenger.allMessagesHandler = (channel, handler, message) async {
      if (message == null) return io.block('empty native message');
      if (channel == SystemChannels.textInput.name &&
          tester.testTextInput.isRegistered &&
          handler != null)
        return handler(message);
      if (channel == SystemChannels.platform.name) {
        final call = const JSONMethodCodec().decodeMethodCall(message);
        final result = switch (call.method) {
          'HapticFeedback.vibrate' ||
          'SystemSound.play' ||
          'SystemChrome.setSystemUIOverlayStyle' ||
          'SystemChrome.setApplicationSwitcherDescription' => null,
          'LiveText.isLiveTextInputAvailable' => false,
          'Clipboard.hasStrings' => {'value': false},
          _ => io.block('platform metadata'),
        };
        return const JSONMethodCodec().encodeSuccessEnvelope(result);
      }
      if (channel == SystemChannels.processText.name) {
        final call = SystemChannels.processText.codec.decodeMethodCall(message);
        if (call.method == 'ProcessText.queryTextActions' &&
            call.arguments == null) {
          return SystemChannels.processText.codec.encodeSuccessEnvelope(
            <String, Object?>{},
          );
        }
        return io.block('process text');
      }
      if (channel == SystemChannels.accessibility.name) {
        final event = SystemChannels.accessibility.codec.decodeMessage(message);
        if (event case {
          'type': 'tap',
          'data': final Map<dynamic, dynamic> data,
          'nodeId': final int id,
        }) {
          if (data.isEmpty && id >= 0)
            return SystemChannels.accessibility.codec.encodeMessage(null);
        }
        return io.block('accessibility');
      }
      if (channel == SystemChannels.navigation.name) {
        final call = SystemChannels.navigation.codec.decodeMethodCall(message);
        final args = call.arguments;
        final valid = switch (call.method) {
          'selectMultiEntryHistory' ||
          'selectSingleEntryHistory' => args == null,
          'routeInformationUpdated' =>
            args is Map &&
                args.length == 3 &&
                const {'/', '/support', '/characters'}.contains(args['uri']) &&
                args.containsKey('state') &&
                args['replace'] is bool,
          _ => false,
        };
        if (valid)
          return SystemChannels.navigation.codec.encodeSuccessEnvelope(null);
        return io.block('navigation metadata');
      }
      return io.block('native channel');
    };
    try {
      await failure.run(
        () => HttpOverrides.runZoned(
          () => IOOverrides.runWithIOOverrides(() async {
            await failure.run(() async {
              await backupLoopReal(
                tester,
                () =>
                    f.initialize(memory: memory, foreignSource: foreignSource),
              );
              await tester.pumpWidget(f.widget());
              await backupLoopUntil(
                tester,
                () => find
                    .byKey(const ValueKey('support_composer_send_btn'))
                    .evaluate()
                    .isNotEmpty,
              );
              await body(tester, f);
            });
            await failure.run(() => f.drain(tester));
            await failure.run(() async {
              await tester.pumpWidget(const SizedBox.shrink());
              await tester.pump();
            });
            await failure.run(() => backupLoopReal(tester, f.close));
          }, io),
          createHttpClient: (_) => io.block('HTTP/socket'),
        ),
      );
      await failure.run(() async {
        await messenger.platformMessagesFinished;
        expect(io.attempts, isEmpty);
        expect(f.isolation.attempts, isEmpty);
        expect(tester.takeException(), isNull);
      });
    } finally {
      messenger.allMessagesHandler = previous;
    }
    failure.throwIfAny();
  }, skip: !Platform.isWindows);
}

final class BackupLoopFixture {
  BackupLoopFixture(this.io);
  final BackupLoopIo io;
  final native = BackupLoopNative();
  final isolation = ModelProviderIsolation();
  final dialog = BackupLoopDialog();
  final wire = <Map<String, dynamic>>[];
  final requests = <RequestOptions>[];
  final replies = <Map<String, Object?>>[];
  final gates = <Completer<void>>[];
  late ProviderContainer container;
  late SupportModelUiBridge bridge;
  late GoRouter router;
  bool graph = false, bridgeReady = false, routerReady = false;
  bool publishedObserved = false;
  Future<void> Function(int)? onFetch;
  BackupLoopSignal<List<SupportMessage>>? settlement;
  sqlite.Database? foreignHandle;
  AppDatabase? foreignDb;

  Future<void> initialize({
    bool memory = false,
    bool foreignSource = false,
  }) async {
    await native.initialize(io, memory: memory);
    if (foreignSource) {
      final handle = foreignHandle = sqlite.sqlite3.open(
        p.join(native.directory.path, 'foreign.db'),
      );
      final db = foreignDb = AppDatabase.openedNative(
        handle,
        closeUnderlyingOnClose: false,
      );
      await db.customSelect('SELECT 1').get();
      expect(db.nativeDataSourceIdentity!.belongsTo(db), isTrue);
    }
    SharedPreferences.setMockInitialValues({
      'batterySaverMode': 'on',
      'enterToSend': true,
      'showOurPicks': false,
      'hapticFeedback': false,
      'messageVibration': false,
    });
    final prefs = await SharedPreferences.getInstance();
    final theme = ThemeNotifier(storage: AppControlMemoryTheme());
    isolation.extraAllowed.addAll({
      supportAppActionRegistryProvider,
      appSettingsProvider,
      sharedPreferencesProvider,
      supportAppBackupNativeFileHostProvider,
      themeProvider,
      effectiveBgImageBytesProvider,
      uiFontFamilyProvider,
      chatFontFamilyProvider,
      navHeightProvider,
      shellHeaderProvider,
      supportConnectionsProvider,
      supportModelCatalogProvider,
      supportAppNativeDomainAdaptersProvider,
      supportAppControlContentAdaptersProvider,
      supportAppControlContentMutationPortProvider,
      supportAppControlSessionMemoryProvider,
      supportAppControlSecondaryAdaptersProvider,
      supportAppControlRepairAdaptersProvider,
      supportAppRepairNativePortProvider,
      supportAppNativeRepairPortProvider,
      chatNativeOwnerRegistryProvider,
      characterRepoProvider,
      chatRepoProvider,
      personaRepoProvider,
      lorebookRepoProvider,
      presetRepoProvider,
      studioPresetRepoProvider,
      characterFolderRepoProvider,
      presetFolderRepoProvider,
      extensionPresetsRepoProvider,
      // The real secondary registry retains this original notifier. Its loader
      // reads the repository over our injected DB, not preferences or JS/runtime
      // startup. Match DomainLoopFixture's exact owner registration; no override.
      extensionPresetsProvider,
      memoryBookRepoProvider,
      memoryCatalogRepoProvider,
      memoryActiveDraftsProvider,
      memoryBookRevisionProvider,
      llmRequestCaptureRepoProvider,
      characterRevisionRepoProvider,
      characterSessionBaselineRepoProvider,
      characterKnowledgeFactRepoProvider,
      appliedCanonTransitionRepoProvider,
      canonTransitionFactRefRepoProvider,
      ledgerRawTrackerStateReaderProvider,
      trackerRepoProvider,
      trackerSnapshotRepoProvider,
      sessionCanonCheckpointRepoProvider,
      ledgerReconciliationCheckpointRepoProvider,
      ledgerReconciliationRunRepoProvider,
      cardEvolutionCollectorRunRepoProvider,
    });
    native.wireFactory = () => BackupLoopWire(this);
    container = ProviderContainer(
      observers: [isolation],
      overrides: [
        appDbProvider.overrideWithValue(native.db),
        apiConfigRepoProvider.overrideWithValue(native.apiRepo),
        nativeProviderRuntimeProvider.overrideWithValue(native.native),
        credentialVaultProvider.overrideWithValue(native.vault),
        supportPayloadCipherProvider.overrideWithValue(native.cipher),
        supportRepoProvider.overrideWithValue(native.repo),
        secretRedactionCoordinatorProvider.overrideWithValue(native.redaction),
        connectionRevisionRegistryProvider.overrideWithValue(native.revisions),
        supportNativeRuntimeProvider.overrideWithValue(native.runtime),
        supportSessionStoreProvider.overrideWithValue(native.workspace),
        appSettingsProvider.overrideWith(
          () => AppControlSettingsNotifier(prefs),
        ),
        sharedPreferencesProvider.overrideWith((ref) async => prefs),
        themeProvider.overrideWith((ref) => theme),
        supportModelPrivateAdapterFactoryProvider.overrideWithValue(
          () => BackupLoopWire(this),
        ),
        supportConnectionsProvider.overrideWithValue(const []),
        supportModelCatalogProvider.overrideWithValue(null),
        supportConnectionMetadataProvider.overrideWith(
          (ref) => isolation.block('bulk metadata'),
        ),
        imageStorageProvider.overrideWith(
          (ref) => isolation.block('image storage'),
        ),
        effectiveBgImageBytesProvider.overrideWithValue(null),
        bgImageBytesProvider.overrideWith(
          (ref) => isolation.block('background'),
        ),
        wallpaperBytesProvider.overrideWith(
          (ref) => isolation.block('wallpaper'),
        ),
        uiFontFamilyProvider.overrideWith((ref) async => null),
        chatFontFamilyProvider.overrideWith((ref) async => null),
        navHeightProvider.overrideWith((ref) => 0),
        shellHeaderProvider.overrideWith(ShellHeaderRegistry.new),
        if (foreignSource)
          supportModelUiBridgeProvider.overrideWith((ref) {
            // Denial-only DI: real model service, actual ORIGINAL ROOT/transport/UI.
            // The native backup adapter deliberately retains another opened FILE
            // identity; it must be rejected BEFORE the picker, not granted a ROOT.
            final custody = ref.watch(supportModelDatabaseCustodyProvider);
            bool current() =>
                ref.mounted &&
                custody.alive &&
                native.native.isCurrent &&
                identical(native.stableRedactor, native.redaction.redactor);
            late final SupportModelUiBridge originalBridge;
            final root = native.native;
            final service = SupportModelService(
              db: native.db,
              writeCipher: native.cipher,
              apiRepo: native.apiRepo,
              revisions: native.revisions,
              redaction: native.redaction,
              runtime: native.runtime,
              adapterFactory: () => BackupLoopWire(this),
              isOwnerCurrent: current,
              writes: custody,
              nativeSources: root.sources,
              nativeMetadata: root.credentialReader,
              admissionContract: SupportTextAdmissionContract
                  .auditedRootSingleConnectionNoBusyHandler,
              toolTransport: NativeToolTransport(
                credentials: root.credentials,
                authIssuer: root.auth,
                mutations: root.mutations,
                routes: root.routes,
                currentRedactor: () => native.redaction.redactor,
                adapterFactory: () => BackupLoopWire(this),
              ),
              nativeDispatcher: (inner) => NativeProviderPrivateTextDispatcher(
                credentials: root.credentials,
                authIssuer: root.auth,
                mutations: root.mutations,
                routes: root.routes,
                privateTextTransport: inner,
              ),
              appActionsWithBackupFactory: (backup) => ref
                  .read(supportAppActionRegistryProvider)
                  .withNativeBackup(
                    SupportDatabaseBackupAdapter(
                      native: backup.native,
                      originalSource: () => foreignDb!.nativeDataSourceIdentity,
                      isOriginalOwnerCurrent: current,
                    ),
                  ),
              onMessage: (message) => originalBridge.onMessage(message),
              onPhase: (phase) => originalBridge.onPhase(phase),
            );
            originalBridge = SupportModelUiBridge(
              service: service,
              runtime: native.runtime,
              workspace: ref.watch(supportModelWorkspaceBindingProvider),
              isOwnerCurrent: current,
            );
            custody.retain(service);
            ref.onDispose(() {
              originalBridge.dispose();
              unawaited(
                originalBridge.drained.then((_) => custody.release(service)),
              );
            });
            return originalBridge;
          }),
      ],
    );
    graph = true;
    // Prove the newly registered owner's backing source and the current prefs
    // are THIS fixture's stores. Leave notifier loading to the actual registry.
    expect(
      container.read(extensionPresetsRepoProvider).attachedDatabase,
      same(native.db),
    );
    expect(await container.read(sharedPreferencesProvider.future), same(prefs));
    await container.read(appSettingsProvider.future);
    container.read(themeProvider);
    await theme.flushPersistence();
    bridge = container.read(supportModelUiBridgeProvider);
    bridgeReady = true;
    final workspace = container.read(supportWorkspaceProvider.notifier);
    await workspace.refresh();
    workspace.selectSession(native.session);
    await workspace.refresh();
    await container.pump();
    expect(identical(native.stableRedactor, native.redaction.redactor), isTrue);
    router = GoRouter(
      initialLocation: '/support',
      routes: [
        GoRoute(
          path: '/support',
          builder: (_, _) => SupportAssistantScreen(
            welcomeAvatar: const Icon(Icons.support_agent_rounded),
            backupFileDialog: dialog,
          ),
        ),
        GoRoute(
          path: '/characters',
          builder: (_, _) => const Text(
            'Replacement view',
            key: ValueKey('backup_loop_replacement'),
          ),
        ),
      ],
    );
    routerReady = true;
  }

  Widget widget() => UncontrolledProviderScope(
    container: container,
    child: EasyLocalization(
      supportedLocales: const [Locale('ru')],
      startLocale: const Locale('ru'),
      saveLocale: false,
      path: 'synthetic-no-assets',
      assetLoader: const _BackupLoopTranslations(),
      child: Builder(
        builder: (context) => MaterialApp.router(
          routerConfig: router,
          locale: context.locale,
          supportedLocales: context.supportedLocales,
          localizationsDelegates: context.localizationDelegates,
          theme: ThemeData(colorSchemeSeed: const Color(0xff506080)),
          builder: (context, child) => FlatBackdrop(
            color: Theme.of(context).colorScheme.surface,
            child: child!,
          ),
        ),
      ),
    ),
  );

  void script({
    Map<String, Object?> arguments = const {},
    String answer = 'Локальный снимок сохранён и проверен.',
  }) {
    replies.add({
      'choices': [
        {
          'index': 0,
          'finish_reason': 'tool_calls',
          'message': {
            'role': 'assistant',
            'content': null,
            'tool_calls': [
              {
                'type': 'function',
                'id': 'backup_loop_call',
                'function': {
                  'name': SupportBackupNativeFileHost.action,
                  'arguments': jsonEncode(arguments),
                },
              },
            ],
          },
        },
      ],
      'usage': {
        'prompt_tokens': 17,
        'completion_tokens': 4,
        'total_tokens': 21,
      },
    });
    replies.add({
      'choices': [
        {
          'index': 0,
          'finish_reason': 'stop',
          'message': {'role': 'assistant', 'content': answer},
        },
      ],
      'usage': {
        'prompt_tokens': 31,
        'completion_tokens': 7,
        'total_tokens': 38,
      },
    });
  }

  Future<void> start(WidgetTester tester, {bool picker = true}) async {
    await backupLoopReal(tester, () {
      settlement = BackupLoopSignal(
        native.repo
            .watchMessagesForSession(native.session)
            .firstWhere(
              (rows) => rows.any(
                (m) =>
                    m.role == 'assistant' &&
                    m.runId != null &&
                    const {
                      'complete',
                      'stopped',
                      'error',
                      'limited',
                    }.contains(m.status),
              ),
            ),
      );
    });
    await tester.enterText(
      find.byType(TextField).first,
      'Сохрани всю исходную базу локально с нативным подтверждением.',
    );
    await backupLoopReal(
      tester,
      () => tester.tap(find.byKey(const ValueKey('support_composer_send_btn'))),
    );
    await backupLoopUntil(
      tester,
      () => picker ? dialog.choices == 1 : wire.isNotEmpty,
      signal: settlement,
    );
  }

  Future<BackupLoopSignal<SupportModelRunResult>> startWithoutHost(
    WidgetTester tester,
  ) => backupLoopReal(tester, () {
    expect(container.read(supportAppBackupNativeFileHostProvider), isNull);
    settlement = BackupLoopSignal(
      native.repo
          .watchMessagesForSession(native.session)
          .firstWhere(
            (rows) => rows.any(
              (m) =>
                  m.role == 'assistant' &&
                  m.runId != null &&
                  const {
                    'complete',
                    'stopped',
                    'error',
                    'limited',
                  }.contains(m.status),
            ),
          ),
    );
    final visible = container.read(supportWorkspaceProvider).activeMessages;
    final emitter = bridge.bindEmitter(
      controller: Object(),
      uiLifetime: Object(),
      isEmitterCurrent: () => true,
      visibleConversation: [
        for (final m in visible)
          if (const {'user', 'assistant'}.contains(m.role.name))
            SupportModelConversationMessage(
              id: m.id,
              role: m.role.name,
              text: m.body,
            ),
      ],
    );
    final original = emitter.send(
      text: 'Save locally if a native file host exists.',
      draftRevision: 1,
      isDraftCurrent: () => true,
    );
    return BackupLoopSignal(original.finished);
  });

  Future<void> select(WidgetTester tester, String? path) async {
    await backupLoopReal(tester, () => dialog.complete(path));
    if (path != null) await backupLoopModal(tester, settlement);
  }

  Future<SupportMessage> finish(WidgetTester tester) async {
    final original = settlement!;
    await backupLoopUntil(tester, () => original.done, signal: original);
    await backupLoopReal(tester, () => original.settled);
    await backupLoopUntil(
      tester,
      () => !container.read(supportModelWorkspaceBindingProvider).busy,
    );
    expect(identical(native.redaction.redactor, native.stableRedactor), isTrue);
    return original.value.singleWhere(
      (m) => m.role == 'assistant' && m.runId != null,
    );
  }

  Map<String, dynamic> result() {
    final messages = wire.last['messages'] as List;
    final tool = messages.cast<Map<dynamic, dynamic>>().singleWhere(
      (m) => m['role'] == 'tool',
    );
    expect(tool['tool_call_id'], 'backup_loop_call');
    return Map<String, dynamic>.from(
      jsonDecode(tool['content'] as String) as Map,
    );
  }

  void noEgress([String text = '']) {
    final outward = '${jsonEncode(wire)}$text';
    for (final value in [
      native.sourcePath,
      native.destinationPath,
      BackupLoopNative.private,
      BackupLoopNative.rowSecret,
      BackupLoopNative.key,
      'summary_ciphertext',
      'before_ciphertext',
      'backup_loop_extra',
    ]) {
      expect(outward, isNot(contains(value)));
    }
  }

  void observePublication(void Function() onPublished) {
    native.onCurrent = () {
      if (publishedObserved || !File(native.destinationPath).existsSync())
        return;
      publishedObserved = true;
      onPublished();
    };
  }

  Future<void> drain(WidgetTester tester) async {
    native.clearHooks();
    dialog.finishPending();
    for (final gate in gates) {
      if (!gate.isCompleted) gate.complete();
    }
    if (bridgeReady) {
      await backupLoopReal(tester, bridge.dispose);
      final drained = BackupLoopSignal(bridge.drained);
      await backupLoopUntil(tester, () => drained.done, signal: drained);
    }
  }

  Future<void> close() async {
    final failure = BackupLoopFailure();
    if (graph) await failure.run(container.dispose);
    if (routerReady) await failure.run(router.dispose);
    if (foreignDb != null) await failure.run(foreignDb!.close);
    if (foreignHandle != null) await failure.run(foreignHandle!.close);
    await failure.run(native.close);
    failure.throwIfAny();
  }
}

final class BackupLoopDialog implements SupportBackupFileDialog {
  Completer<String?>? pending;
  int choices = 0;
  @override
  Future<String?> saveLocalDatabase() {
    choices++;
    pending = Completer<String?>();
    return pending!.future;
  }

  void complete(String? path) => pending!.complete(path);
  void failLate() =>
      pending!.completeError(StateError('SYNTHETIC_LATE_PICKER_ERROR'));
  void finishPending() {
    if (pending != null && !pending!.isCompleted) pending!.complete(null);
  }
}

final class BackupLoopWire implements HttpClientAdapter {
  BackupLoopWire(this.fixture);
  final BackupLoopFixture fixture;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final part in requestStream) {
        bytes.addAll(part);
      }
    }
    fixture.requests.add(options);
    fixture.wire.add(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
    final round = fixture.wire.length;
    if (round > fixture.replies.length)
      throw StateError('Undeclared extra POST');
    await fixture.onFetch?.call(round);
    return ResponseBody.fromString(
      jsonEncode(fixture.replies[round - 1]),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<T> backupLoopReal<T>(
  WidgetTester tester,
  FutureOr<T> Function() action,
) async {
  late T value;
  Object? failure;
  StackTrace? stack;
  await tester.runAsync(() async {
    try {
      value = await action();
    } catch (error, trace) {
      failure = error;
      stack = trace;
    }
  });
  if (failure != null) Error.throwWithStackTrace(failure!, stack!);
  return value;
}

Future<void> backupLoopUntil(
  WidgetTester tester,
  bool Function() ready, {
  BackupLoopSignal<dynamic>? signal,
}) async {
  for (var frame = 0; frame < 1024; frame++) {
    signal?.throwIfFailed();
    if (ready()) return;
    await tester.pump();
    await backupLoopReal(tester, () => Future<void>.delayed(Duration.zero));
  }
  signal?.throwIfFailed();
  throw TestFailure(
    'Original backup model signal exceeded finite frame budget',
  );
}

Future<void> backupLoopModal(
  WidgetTester tester,
  BackupLoopSignal<dynamic>? signal,
) async {
  final accept = find.byKey(
    const ValueKey('support_backup_confirmation_accept'),
  );
  await backupLoopUntil(
    tester,
    () => accept.evaluate().isNotEmpty,
    signal: signal,
  );
  final route = ModalRoute.of<void>(tester.element(accept))!;
  await tester.pump();
  await tester.pump(route.transitionDuration);
  await tester.pump(const Duration(microseconds: 1));
  expect(route.isCurrent, isTrue);
  expect(route.animation!.status, AnimationStatus.completed);
  final viewport =
      Offset.zero & (tester.view.physicalSize / tester.view.devicePixelRatio);
  for (final name in ['accept', 'cancel']) {
    final button = find.byKey(ValueKey('support_backup_confirmation_$name'));
    expect(button.hitTestable(), findsOneWidget);
    final rect = tester.getRect(button);
    expect(viewport.contains(rect.topLeft), isTrue);
    expect(viewport.contains(rect.bottomRight), isTrue);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('support_backup_confirmation_preview')),
        matching: button,
      ),
      findsNothing,
    );
  }
}

Future<void> backupLoopDecision(WidgetTester tester, String decision) async {
  final button = find.byKey(ValueKey('support_backup_confirmation_$decision'));
  expect(button.hitTestable(), findsOneWidget);
  final route = ModalRoute.of<void>(tester.element(button))!;
  await backupLoopReal(tester, () => tester.tap(button));
  await tester.pump();
  await tester.pump(route.reverseTransitionDuration);
  await tester.pump(const Duration(microseconds: 1));
}

final class _BackupLoopTranslations extends AssetLoader {
  const _BackupLoopTranslations();
  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async =>
      const {};
}
