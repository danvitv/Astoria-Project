import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:glaze_flutter/core/credentials/api_config_credential_adapter.dart';
import 'package:glaze_flutter/core/credentials/connection_revision_registry.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/state/connection_revision_provider.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_workspace_store.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_catalog_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_data_consent_admission.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/features/support_assistant/support_assistant_screen.dart';
import 'package:glaze_flutter/shared/shell/nav_height_provider.dart';
import 'package:glaze_flutter/shared/shell/shell_header_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_font_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';
import 'package:glaze_flutter/shared/widgets/glass_surface.dart';

import '../../credentials/fake_credential_storage.dart';
import '../../llm/transport/_private_text_fixture.dart';
import 'support_model_provider_fixture_http.dart';
import 'support_model_provider_fixture_isolation.dart';
import 'support_native_input_fixture.dart'
    show NativeInputCipher, NativeInputSql;

/// Actual screen + actual native/workspace/model providers in ONE flat scope.
/// Only low-level memory AEAD/SQL barriers and socket-free adapter are reused.
/// No fake send/native/run provider or production App/bootstrap/default database.
final class ModelScreenFixture {
  ModelScreenFixture({
    this.configured = true,
    this.confirm = true,
    this.topic,
    this.enterToSend = true,
    this.oldBody = excluded,
  }) {
    db = _ScreenDatabase(NativeDatabase.memory().interceptWith(sql));
    vault = CredentialVault(storage: storage, buildChannel: 'synthetic_screen');
    router = GoRouter(
      initialLocation: '/support',
      routes: [
        GoRoute(
          path: '/support',
          builder: (_, _) => SupportAssistantScreen(
            initialTopic: topic,
            welcomeAvatar: const Icon(Icons.support_agent_rounded),
          ),
        ),
        for (final path in ['/characters', '/tools/api', '/menu/themes'])
          GoRoute(
            path: path,
            builder: (_, _) => isolation.block('navigation $path'),
          ),
      ],
    );
  }
  static const session = 'screen-session', other = 'screen-other';
  static const secret = 'SYNTHETIC_SCREEN_PRIVATE_73489';
  static const key = 'SYNTHETIC_SCREEN_ROW_KEY_13847';
  static const excluded = 'SYNTHETIC_SCREEN_UNSELECTED_63194';
  final bool configured, confirm;
  final bool enterToSend;
  final String? topic;
  final String oldBody;
  final isolation = ModelProviderIsolation();
  final primitive = NativeInputCipher();
  final sql = NativeInputSql();
  final storage = FakeCredentialStorage();
  final redaction = SecretRedactionCoordinator();
  final revisions = ConnectionRevisionRegistry();
  final adapters = <ModelProviderHttpAdapter>[];
  late final Completer<ModelProviderHttpAdapter> adapterCreated;
  final bridges = <SupportModelUiBridge>{};
  final barriers = <ModelProviderBarrier>[];
  late final AppDatabase db;
  late final CredentialVault vault;
  late final SupportPayloadCipher cipher;
  late final SupportRepo repo;
  late final SupportWorkspaceStore store;
  late final ProviderContainer container;
  late final GoRouter router;
  bool _compositionStarted = false, _containerCreated = false;
  bool _actionScopeActive = false;
  bool quiet = false;
  int status = 200;
  String response = chatComplete('Safe actual screen answer');
  // Test-only observation at the existing final fake adapter factory. A null
  // hook preserves all existing defaults; it grants no admission or fake result.
  void Function(ModelProviderHttpAdapter adapter)? onFinalAdapter;
  final api = const ApiConfig(
    id: 'screen-api',
    name: 'Synthetic screen API',
    endpoint: 'https://screen.invalid/v1/chat/completions',
    apiKey: key,
    model: 'roleplay-default-must-not-win',
  );
  final settings = const SupportAssistantSettings(
    apiConfigId: 'screen-api',
    modelId: 'screen-selected-model',
    temperature: 0.25,
    maxTokens: 512,
  );
  SupportWorkspaceNotifier get workspace =>
      container.read(supportWorkspaceProvider.notifier);
  SupportWorkspaceState get state => container.read(supportWorkspaceProvider);
  SupportModelUiBridge get bridge {
    final bridge = container.read(supportModelUiBridgeProvider);
    bridges.add(bridge);
    return bridge;
  }

  ModelProviderBarrier barrier() {
    final barrier = ModelProviderBarrier();
    barriers.add(barrier);
    return barrier;
  }

  /// Issue original callbacks/owners in the guarded real zone. Never pump here.
  /// Catch inside runAsync so binding report-and-null cannot hide the first error.
  Future<T> action<T>(WidgetTester tester, FutureOr<T> Function() issue) async {
    if (!_actionScopeActive) {
      throw StateError('Screen actions require the active isolation scope.');
    }
    late T value;
    Object? failure;
    StackTrace? stack;
    await tester.runAsync(() async {
      try {
        value = await issue();
      } catch (error, trace) {
        failure = error;
        stack = trace;
      }
    });
    if (failure != null) Error.throwWithStackTrace(failure!, stack!);
    return value;
  }

  /// Box an ORIGINAL Future before returning: runAsync must not flatten/await
  /// a phase/barrier that only the next actual action can complete.
  Future<ScreenSignal<T>> signal<T>(
    WidgetTester tester,
    Future<T> Function() observe, {
    required String label,
  }) => action(tester, () => ScreenSignal._(observe(), label));

  /// Join the original typed observation, including frame-created topic tails,
  /// route.popped listeners and disposal work. Zero-duration widget pumps remain
  /// outside runAsync; real event turns allow owned SQL/AEAD/transport to progress.
  /// This is a turn bound, not a sleep, fake completion or product timeout change.
  Future<T> finish<T>(WidgetTester tester, ScreenSignal<T> signal) async {
    for (var turn = 0; turn < 1024; turn++) {
      if (signal._done) return signal._result();
      await tester.pump();
      await action(tester, () => Future<void>.delayed(Duration.zero));
    }
    if (signal._done) return signal._result();
    throw StateError(
      'Original screen signal did not complete: ${signal.label} '
      '(1024 widget/real event turns).',
    );
  }

  HttpClientAdapter newAdapter() {
    final adapter = ModelProviderHttpAdapter(
      PrivateFixtureAdapter(
        response,
        quiet: quiet,
        status: status,
        oneByteChunks: true,
      ),
    );
    adapters.add(adapter);
    onFinalAdapter?.call(adapter);
    if (!adapterCreated.isCompleted) adapterCreated.complete(adapter);
    return adapter;
  }

  // Called only at the start of guarded real-async initialization. The cipher's
  // original key FIFO must not capture the constructor's widget-test fake zone.
  void _composeOnce() {
    if (_compositionStarted) {
      throw StateError('Screen fixture composition is one-shot.');
    }
    _compositionStarted = true;
    adapterCreated = Completer<ModelProviderHttpAdapter>();
    cipher = SupportPayloadCipher(vault: vault, cipher: primitive);
    repo = SupportRepo(db, cipher);
    store = SupportWorkspaceStore(repo, () => redaction.redactor);
    isolation.extraAllowed.addAll({
      appSettingsProvider,
      sharedPreferencesProvider,
      themeProvider,
      effectiveBgImageBytesProvider,
      uiFontFamilyProvider,
      chatFontFamilyProvider,
      navHeightProvider,
      shellHeaderProvider,
      supportConnectionsProvider,
      nativeProviderAdapterFactoryProvider,
      supportModelCatalogProvider,
      supportDataConsentAdmissionProvider,
    });
    container = ProviderContainer(
      observers: [isolation],
      overrides: [
        appDbProvider.overrideWithValue(db),
        credentialStorageProvider.overrideWithValue(storage),
        credentialVaultProvider.overrideWithValue(vault),
        supportPayloadCipherProvider.overrideWithValue(cipher),
        supportRepoProvider.overrideWithValue(repo),
        connectionRevisionRegistryProvider.overrideWithValue(revisions),
        secretRedactionCoordinatorProvider.overrideWithValue(redaction),
        supportSessionStoreProvider.overrideWithValue(store),
        supportModelPrivateAdapterFactoryProvider.overrideWithValue(newAdapter),
        // This is the explicit text/SSE fixture, not the native-tool graph.
        // Tool-loop fixtures separately exercise the actual native owner.
        nativeProviderRuntimeProvider.overrideWithValue(null),
        nativeProviderAdapterFactoryProvider.overrideWithValue(
          () => isolation.block('undeclared native provider wire adapter'),
        ),
        supportConnectionsProvider.overrideWithValue(const []),
        // This fixture exercises prompt transport, not provider catalog GETs.
        supportModelCatalogProvider.overrideWithValue(null),
        supportConnectionMetadataProvider.overrideWith(
          (_) => isolation.block('bulk model/metadata startup'),
        ),
        llmRequestCaptureInstallationProvider.overrideWith(
          (_) => isolation.block('capture installation'),
        ),
        imageStorageProvider.overrideWith(
          (_) => isolation.block('image storage'),
        ),
        migrationServiceProvider.overrideWith(
          (_) => isolation.block('production migration'),
        ),
        appSettingsProvider.overrideWith(
          () => _ScreenSettings(isolation.block, enterToSend),
        ),
        themeProvider.overrideWith((_) => _ScreenTheme(isolation.block)),
        sharedPreferencesProvider.overrideWith(
          (_) => isolation.block('visual preferences default'),
        ),
        effectiveBgImageBytesProvider.overrideWithValue(null),
        bgImageBytesProvider.overrideWith(
          (_) => isolation.block('background resource'),
        ),
        wallpaperBytesProvider.overrideWith(
          (_) => isolation.block('wallpaper resource'),
        ),
        uiFontFamilyProvider.overrideWith((_) async => null),
        chatFontFamilyProvider.overrideWith((_) async => null),
        navHeightProvider.overrideWith((_) => 0),
        shellHeaderProvider.overrideWith(ShellHeaderRegistry.new),
      ],
    );
    _containerCreated = true;
  }

  Future<void> initialize() async {
    _composeOnce();
    await db.customSelect('SELECT 1').getSingle();
    await db.customStatement('PRAGMA busy_timeout = 0');
    redaction.registerSecret(secret);
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
    await repo.putMessage(
      SupportMessage(
        id: 'old',
        sessionId: session,
        role: 'assistant',
        body: oldBody,
        createdAt: 2,
      ),
    );
    await container.read(apiConfigRepoProvider).put(api);
    await container
        .read(apiConfigRepoProvider)
        .put(
          api.copyWith(
            id: 'unselected',
            apiKey: excluded,
            endpoint: 'https://excluded.invalid/v1/chat/completions',
          ),
        );
    await vault.store(
      ApiConfigCredentialAdapter.llmSlot(api.id),
      'SYNTHETIC_STALE_VAULT_KEY_43281',
    );
    if (configured) await store.changeSettings(session, (_) => settings);
    await container.read(appSettingsProvider.future);
    workspace;
    await container.pump();
    if (configured) bridge;
    await workspace.refresh();
    workspace.selectSession(session);
    await workspace.refresh();
    if (configured && confirm) await confirmRecipient();
    await container.pump();
    expect(adapters, isEmpty);
  }

  Future<void> confirmRecipient() async {
    final controller = container.read(supportNativeConsentControllerProvider);
    final review = await controller.prepareReview();
    expect(review, isNotNull);
    expect(await controller.confirmRecipient(review!), isTrue);
  }

  void changeEnterToSendForTest(bool value) =>
      (container.read(appSettingsProvider.notifier) as _ScreenSettings)
          .changeEnterToSendForTest(value);

  Widget host({double scale = 1}) => UncontrolledProviderScope(
    container: container,
    child: EasyLocalization(
      supportedLocales: const [Locale('ru')],
      startLocale: const Locale('ru'),
      saveLocale: false,
      path: 'synthetic-no-assets',
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
    StackTrace? failureStack;
    // Preserve the first failure while still attempting every cleanup step.
    // Capture runAsync callback errors here so it cannot report-and-return-null,
    // then let mounting an uninitialized late container obscure that error.
    Future<void> captureFailure(FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }

    await captureFailure(() async {
      SharedPreferences.setMockInitialValues({});
      await tester.runAsync(
        () => captureFailure(EasyLocalization.ensureInitialized),
      );
    });
    await captureFailure(
      () => isolation.run(() async {
        _actionScopeActive = true;
        final messenger = tester.binding.defaultBinaryMessenger;
        try {
          await captureFailure(() async {
            messenger.setMockMethodCallHandler(
              SystemChannels.platform,
              (call) async => switch (call.method) {
                'HapticFeedback.vibrate' ||
                'SystemSound.play' ||
                'SystemChrome.setSystemUIOverlayStyle' ||
                'SystemChrome.setApplicationSwitcherDescription' => null,
                'LiveText.isLiveTextInputAvailable' => false,
                // Metadata-only paste affordance; never read/write clipboard.
                'Clipboard.hasStrings' => <String, bool>{'value': false},
                // getData/setData and every other clipboard method still deny.
                _ => isolation.block('platform ${call.method}'),
              },
            );
            if (failure != null) return;
            await tester.runAsync(() => captureFailure(initialize));
            if (failure != null) return;
            await tester.pumpWidget(host());
            await tester.pumpAndSettle();
            expect(find.byType(BackdropFilter), findsNothing);
            expect(find.byType(Image), findsNothing);
            expect(find.byType(RawImage), findsNothing);
            await body();
          });
        } finally {
          primitive.beforeDecrypt = null;
          primitive.afterEncrypt = null;
          sql.afterSelect = null;
          sql.afterWrite = null;
          storage.beforeRead = null;
          storage.beforeWrite = null;
          onFinalAdapter = null;
          // Capture original drained bridge BEFORE disposal, never look up late.
          final originals = List.of(bridges);
          await captureFailure(
            () => action(tester, () {
              for (final barrier in barriers) {
                barrier.release();
              }
            }),
          );
          await captureFailure(
            () => tester.pumpWidget(const SizedBox.shrink()),
          );
          await captureFailure(tester.pump);
          await captureFailure(
            () => action(tester, () {
              if (_containerCreated) container.dispose();
            }),
          );
          await captureFailure(() => action(tester, router.dispose));
          await captureFailure(() async {
            for (final original in originals) {
              await captureFailure(() async {
                final drained = await signal(
                  tester,
                  () => original.drained,
                  label: 'original bridge teardown drain',
                );
                await finish(tester, drained);
              });
            }
            await captureFailure(() async {
              final closed = await signal(
                tester,
                db.close,
                label: 'own DB close',
              );
              await finish(tester, closed);
            });
          });
          await captureFailure(tester.pump);
          await captureFailure(revisions.dispose);
          await captureFailure(redaction.dispose);
          await captureFailure(() => expect(tester.takeException(), isNull));
          _actionScopeActive = false;
        }
      }),
    );
    final originalFailure = failure;
    if (originalFailure != null) {
      Error.throwWithStackTrace(originalFailure, failureStack!);
    }
  }
}

/// Observation only: stores the ORIGINAL result/error; never completes its source.
final class ScreenSignal<T> {
  ScreenSignal._(Future<T> original, this.label) {
    original.then(
      (value) {
        _value = value;
        _done = true;
      },
      onError: (Object error, StackTrace stack) {
        _error = error;
        _stack = stack;
        _done = true;
      },
    );
  }
  final String label;
  bool _done = false;
  late T _value;
  Object? _error;
  StackTrace? _stack;
  T _result() {
    if (_error != null) Error.throwWithStackTrace(_error!, _stack!);
    return _value;
  }
}

final class _ScreenDatabase extends AppDatabase {
  _ScreenDatabase(super.e) : super.forTesting();
  @override
  MigrationStrategy get migration =>
      MigrationStrategy(onCreate: (m) => m.createAll());
}

class _ScreenSettings extends AsyncNotifier<AppSettings>
    implements AppSettingsNotifier {
  _ScreenSettings(this.block, this.initialEnterToSend);
  final Never Function(String) block;
  final bool initialEnterToSend;
  @override
  Future<AppSettings> build() async => AppSettings(
    enterToSend: initialEnterToSend,
    batterySaver: true,
    batterySaverMode: BatterySaverMode.on,
    hapticFeedback: false,
    messageVibration: false,
    allowMessageScripts: false,
    showOurPicks: false,
  );
  void changeEnterToSendForTest(bool value) =>
      state = AsyncData(state.requireValue.copyWith(enterToSend: value));
  @override
  dynamic noSuchMethod(Invocation invocation) => block('settings command');
}

class _ScreenTheme extends StateNotifier<ThemeSettings>
    implements ThemeNotifier {
  _ScreenTheme(this.block)
    : super(
        const ThemeSettings(
          activePreset: ThemePreset(
            id: 'screen-flat',
            name: 'Synthetic flat',
            elementOpacity: 1,
            elementBlur: 0,
            noiseOpacity: 0,
            bgBlur: 0,
            bgDim: 0,
            bgNoiseOpacity: 0,
            uiFontMode: 'system',
            chatFontMode: 'system',
          ),
          presets: [],
          ignoreCustomFont: true,
        ),
      );
  final Never Function(String) block;
  @override
  dynamic noSuchMethod(Invocation invocation) => block('theme command');
}

class _MemoryTranslations extends AssetLoader {
  const _MemoryTranslations();
  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async => {};
}
