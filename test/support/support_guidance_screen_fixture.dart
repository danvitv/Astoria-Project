import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:glaze_flutter/core/credentials/api_connection_metadata.dart';
import 'package:glaze_flutter/core/credentials/credential_metadata.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/support_models.dart' as db;
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_runtime.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/features/support_assistant/support_assistant_screen.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_card_view.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_guidance_sheet.dart';
import 'package:glaze_flutter/shared/shell/nav_height_provider.dart';
import 'package:glaze_flutter/shared/shell/shell_header_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_font_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';
import 'package:glaze_flutter/shared/widgets/glass_surface.dart';
import 'package:glaze_flutter/shared/widgets/sheet_view.dart';

import '../credentials/fake_credential_storage.dart';
import '../theme_selection_test_store.dart';
import 'helpers/support_mutation_journal_fixture.dart'
    show JournalControlledCipher;
import 'support_guidance_screen_isolation.dart';
import 'support_guidance_screen_turns.dart';
import 'support_session_scope_widget_sql.dart';
import 'support_session_scope_widget_database.dart';
import 'support_theme_provider_theme.dart';
import 'support_theme_provider_vault.dart';

export 'support_guidance_screen_turns.dart';

/// Actual provider graph over ONE memory SQLite/FakeVault/real AEAD. All async
/// resources are created in guarded tester.runAsync, never a fake-zone field.
final class GuidanceScreenFixture {
  GuidanceScreenFixture({this.screen = true});
  static const session = 'guidance-own-current', other = 'guidance-own-other';
  static const newest = 'guidance-game-newest', older = 'guidance-game-older';
  static const bodyCanary = 'SYNTHETIC_UNREAD_HISTORY_8d21';
  final bool screen;
  final isolation = GuidanceScreenIsolation();
  late final turns = GuidanceScreenTurns(isolation.guarded);
  late final GuidanceMemoryDatabase database;
  late final SessionScopeWidgetSql sql;
  late final JournalControlledCipher primitive;
  late final SupportRepo repo;
  late final FakeCredentialStorage storage;
  late final SecretRedactionCoordinator redaction;
  late final ThemeProviderTheme theme;
  late final ProviderContainer container;
  late final GoRouter router;
  late final GuidanceDeniedApi api;
  final crypto = <String>[];
  int _lastCardIndex = 0;
  bool _databaseCreated = false, _containerCreated = false;
  bool _routerCreated = false, _themeCreated = false;

  SupportWorkspaceNotifier get workspace =>
      container.read(supportWorkspaceProvider.notifier);
  SupportWorkspaceState get state => container.read(supportWorkspaceProvider);
  SupportNativeConsentController get controller =>
      container.read(supportNativeConsentControllerProvider);
  SupportNativeRuntime get runtime =>
      container.read(supportNativeRuntimeProvider);

  Future<void> initialize() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    sql = SessionScopeWidgetSql(isolation.block);
    primitive = JournalControlledCipher();
    database = GuidanceMemoryDatabase(
      NativeDatabase.memory().interceptWith(sql),
    );
    _databaseCreated = true;
    storage = FakeCredentialStorage();
    redaction = SecretRedactionCoordinator();
    final guardedStorage = ThemeProviderVaultStorage(storage, isolation.block);
    final vault = CredentialVault(
      storage: guardedStorage,
      buildChannel: 'theme_provider_test',
    );
    final cipher = SupportPayloadCipher(vault: vault, cipher: primitive);
    repo = SupportRepo(database, cipher);
    api = GuidanceDeniedApi(database, isolation.block);
    theme = ThemeProviderTheme(
      ThemeSelectionBacking(
        presets: const [
          ThemePreset(
            id: 'a',
            name: 'Synthetic theme',
            noiseOpacity: 0,
            uiFontMode: 'system',
            chatFontMode: 'system',
          ),
        ],
      ),
    );
    _themeCreated = true;
    container = ProviderContainer(
      observers: [isolation],
      overrides: [
        appDbProvider.overrideWithValue(database),
        supportRepoProvider.overrideWithValue(repo),
        supportPayloadCipherProvider.overrideWithValue(cipher),
        credentialStorageProvider.overrideWithValue(guardedStorage),
        credentialVaultProvider.overrideWithValue(vault),
        secretRedactionCoordinatorProvider.overrideWithValue(redaction),
        apiConfigRepoProvider.overrideWithValue(api),
        // Explicit pre-graph denials, including native's separately owned factory.
        nativeProviderAdapterFactoryProvider.overrideWithValue(
          () => isolation.block('native adapter construction'),
        ),
        supportModelPrivateAdapterFactoryProvider.overrideWithValue(
          () => isolation.block('private model adapter construction'),
        ),
        supportModelUiBridgeProvider.overrideWith(
          (_) => isolation.block('model bridge during local guidance'),
        ),
        sharedPreferencesProvider.overrideWith(
          (_) => isolation.block('application preferences'),
        ),
        apiConfigCredentialAdapterProvider.overrideWith(
          (_) => isolation.block('API credential adapter'),
        ),
        supportConnectionMetadataProvider.overrideWith(
          (_) => isolation.block('selected/API metadata resolver'),
        ),
        // A declared synthetic chooser projection, NOT workspace/policy overrides.
        supportConnectionsProvider.overrideWithValue(const [guidanceProfile]),
        imageStorageProvider.overrideWith(
          (_) => isolation.block('image startup'),
        ),
        migrationServiceProvider.overrideWith(
          (_) => isolation.block('migration startup'),
        ),
        llmRequestCaptureInstallationProvider.overrideWith(
          (_) => isolation.block('capture startup'),
        ),
        appSettingsProvider.overrideWith(() => _GuidanceVisualSettings()),
        themeProvider.overrideWith((ref) {
          ref.onDispose(() => theme.providerDisposed = true);
          return theme.notifier;
        }),
        effectiveBgImageBytesProvider.overrideWithValue(null),
        bgImageBytesProvider.overrideWith(
          (_) => isolation.block('background file'),
        ),
        wallpaperBytesProvider.overrideWith(
          (_) => isolation.block('wallpaper file'),
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
          builder: (_, _) => screen
              ? const SupportAssistantScreen(
                  welcomeAvatar: Icon(Icons.support_agent),
                )
              : const GuidanceCardHost(),
        ),
        GoRoute(path: '/characters', builder: (_, _) => const SizedBox()),
      ],
    );
    _routerCreated = true;
    await database.customSelect('SELECT 1').getSingle();
    for (final id in [session, other]) {
      await repo.createSession(
        db.SupportSession(
          id: id,
          title: 'Synthetic $id',
          createdAt: 1,
          updatedAt: 2,
        ),
      );
    }
    await database
        .into(database.characters)
        .insert(
          CharactersCompanion.insert(
            charId: 'guidance-parent',
            name: 'Synthetic metadata parent',
            variantName: const Value('Native variant'),
            variantGroupId: const Value('guidance-parent-group'),
            variantOrder: const Value(1),
            description: const Value(bodyCanary),
            avatarPath: const Value('not-a-file'),
          ),
        );
    for (final value in [(newest, 20, 1), (older, 10, 0)]) {
      await database
          .into(database.chatSessions)
          .insert(
            ChatSessionsCompanion.insert(
              sessionId: value.$1,
              characterId: 'guidance-parent',
              sessionIndex: value.$3,
              updatedAt: Value(value.$2),
              messagesJson: jsonEncode([
                {
                  'id': 'synthetic-unread-message',
                  'role': 'user',
                  'content': bodyCanary,
                  'timestamp': 1,
                },
              ]),
              draft: const Value(bodyCanary),
              sessionVarsJson: const Value('{"private":"$bodyCanary"}'),
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
    await runtime.refresh(resolve: false);
    expect(runtime.snapshot.isAvailable, isTrue);
    expect(runtime.snapshot.preferences!.grants, isEmpty);
    expect(state.activeMessages, isEmpty);
  }

  Widget host() => UncontrolledProviderScope(
    container: container,
    child: EasyLocalization(
      supportedLocales: const [Locale('en')],
      startLocale: const Locale('en'),
      saveLocale: false,
      path: 'finite-memory-guidance',
      assetLoader: const GuidanceMemoryLocale(),
      child: Builder(
        builder: (context) => MaterialApp.router(
          routerConfig: router,
          locale: context.locale,
          supportedLocales: context.supportedLocales,
          localizationsDelegates: context.localizationDelegates,
          builder: (context, child) => FlatBackdrop(
            color: Theme.of(context).colorScheme.surface,
            child: child!,
          ),
        ),
      ),
    ),
  );

  Future<void> run(
    WidgetTester tester,
    Future<void> Function() body,
  ) => isolation.run(tester, () async {
    Object? failure;
    StackTrace? trace;
    Future<void> capture(Future<void> Function() work) async {
      try {
        await work();
      } catch (error, stack) {
        failure ??= error;
        trace ??= stack;
      }
    }

    await capture(() => turns.real(tester, initialize));
    if (failure == null) {
      await capture(() async {
        await tester.pumpWidget(host());
        await tester.pump();
        await tester.pump();
        await idle(tester);
        observe();
        await body();
      });
    }
    // Never close SQLite underneath an original held selector/workspace job.
    if (_databaseCreated) {
      await capture(
        () => turns.real(tester, () async {
          sql.release();
        }),
      );
      await capture(() => tester.pumpWidget(const SizedBox()));
      await capture(tester.pump);
      if (_containerCreated) {
        await capture(() => idle(tester));
        await capture(
          () => turns.real(tester, () async {
            container.dispose();
          }),
        );
      }
      await capture(
        () => turns.until(
          tester,
          () => sql.outstanding == 0 && database.activeTransactions == 0,
          label: 'original metadata SELECT and full transaction drain',
        ),
      );
      // Publish continuations of those ORIGINAL jobs after unmount. Neither
      // this observation nor a frame completes a held job on its behalf.
      await capture(() async {
        for (var turn = 0; turn < 2; turn++) {
          await tester.pump();
          await turns.real(tester, () => Future<void>.delayed(Duration.zero));
        }
        expect(sql.outstanding, 0);
        expect(database.activeTransactions, 0);
      });
      if (_routerCreated) router.dispose();
      if (_themeCreated) {
        if (!theme.providerDisposed) theme.notifier.dispose();
        theme.releaseDelays();
      }
      await capture(() => turns.join(tester, database.close));
      redaction.dispose();
    }
    await capture(tester.pump);
    await capture(() async {
      expect(tester.takeException(), isNull);
      expect(isolation.attempts, isEmpty);
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    if (messenger.pendingMessageCount != 0) {
      await capture(
        () => turns.join(tester, () => messenger.platformMessagesFinished),
      );
    }
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  });

  void observe() {
    sql.observe();
    crypto.clear();
    primitive.event = (event) async {
      crypto.add(event);
    };
  }

  Future<void> idle(WidgetTester tester) => turns.until(
    tester,
    () =>
        !state.isBusy &&
        !state.isLoading &&
        runtime.pending == 0 &&
        runtime.settingsPending == 0 &&
        sql.outstanding == 0 &&
        database.activeTransactions == 0,
    label: 'original workspace/native jobs',
  );

  Future<T> action<T>(WidgetTester tester, Future<T> Function() work) =>
      turns.join(tester, work);

  Future<void> reveal(WidgetTester tester, Finder control) async {
    expect(control, findsOneWidget);
    // Metadata can finish before the NEW nested route's entrance animation.
    // Its laid-out controls are then translated below the physical viewport;
    // scrolling cannot finish a route animation whose fake clock is stationary.
    final route = ModalRoute.of(tester.element(control));
    if (route?.animation?.status == AnimationStatus.forward) {
      await tester.pump(const Duration(milliseconds: 350));
    }
    final scrollable = Scrollable.maybeOf(tester.element(control));
    if (scrollable != null) {
      await Scrollable.ensureVisible(tester.element(control), alignment: 0.5);
      await tester.pump();
      await tester.pump();
      final viewport = find.byElementPredicate(
        (element) => identical(element, scrollable.context),
      );
      expect(viewport, findsOneWidget);
      var visible = tester
          .getRect(viewport)
          .intersect(
            Offset.zero &
                (tester.view.physicalSize / tester.view.devicePixelRatio),
          );
      final sheets = find.ancestor(
        of: control,
        matching: find.byType(SheetView),
      );
      if (sheets.evaluate().isNotEmpty) {
        final sheet = sheets.last;
        final title = tester.widget<SheetView>(sheet).title;
        final titleFinder = find.descendant(
          of: sheet,
          matching: find.text(title!),
        );
        final header = find
            .ancestor(
              of: titleFinder,
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Positioned &&
                    widget.top == 0 &&
                    widget.left == 0 &&
                    widget.right == 0 &&
                    widget.bottom == null,
              ),
            )
            .last;
        final bottom = tester.getRect(header).bottom;
        visible = Rect.fromLTRB(
          visible.left,
          bottom > visible.top ? bottom : visible.top,
          visible.right,
          visible.bottom,
        );
      }
      final bounds = tester.getRect(control);
      expect(bounds.top, greaterThanOrEqualTo(visible.top));
      expect(bounds.bottom, lessThanOrEqualTo(visible.bottom));
      expect(bounds.left, greaterThanOrEqualTo(visible.left));
      expect(bounds.right, lessThanOrEqualTo(visible.right));
    }
    expect(control.hitTestable(), findsOneWidget);
  }

  Future<void> tap(WidgetTester tester, Finder control) async {
    await reveal(tester, control);
    await turns.real(tester, () => tester.tap(control));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final control = find.byKey(ValueKey(key));
    if (!screen &&
        key.startsWith('support_guidance_') &&
        find.byType(GuidanceCardHost).evaluate().isNotEmpty) {
      final target = SupportGuidanceTarget.values.byName(
        key.substring('support_guidance_'.length),
      );
      if (control.evaluate().isEmpty) {
        await tester.scrollUntilVisible(
          control,
          target.index >= _lastCardIndex ? 250 : -250,
          scrollable: find
              .descendant(
                of: find.byType(GuidanceCardHost),
                matching: find.byType(Scrollable),
              )
              .first,
          maxScrolls: 50,
        );
      }
      _lastCardIndex = target.index;
    }
    await tap(tester, control);
  }

  Future<void> closeTop(WidgetTester tester) async {
    final sheet = find.byType(SheetView).last;
    final callback = tester.widget<SheetView>(sheet).onBack!;
    await turns.real(tester, () async {
      callback();
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    await idle(tester);
  }

  Future<SupportPermissionPreferences> saved(
    WidgetTester tester, [
    String id = session,
  ]) => action(
    tester,
    () async =>
        (await container.read(supportPermissionStoreProvider).readForNative(id))
            .preferences!,
  );

  Future<int> messageCount(WidgetTester tester) => action(
    tester,
    () async =>
        (await database
                .customSelect('SELECT COUNT(*) AS n FROM support_messages')
                .getSingle())
            .read<int>('n'),
  );

  void noReadersOrWire() {
    expect(api.reads, 0);
    expect(isolation.attempts, isEmpty);
    expect(sql.reads.where((r) => r.supportMessageBody), isEmpty);
    expect(
      crypto.where((event) => event.contains('support_messages')),
      isEmpty,
    );
    expect(find.text(bodyCanary), findsNothing);
  }

  void noRecipientResolver() {
    expect(
      sql.reads.where(
        (read) => read.args.any(
          (arg) => arg is String && arg.startsWith('workspace-settings-v1:'),
        ),
      ),
      isEmpty,
      reason: 'Local scope/right review must use resolveRecipient:false.',
    );
    noReadersOrWire();
  }
}

const guidanceProfile = ApiConnectionMetadata(
  connectionId: 'guidance-profile',
  displayName: 'Synthetic chooser profile',
  providerId: 'openai',
  protocol: 'openai',
  mode: 'chat',
  endpoint: 'https://synthetic.invalid/v1/chat/completions',
  model: 'synthetic-model',
  llmCredential: CredentialMetadata.absent,
  embeddingCredential: CredentialMetadata.absent,
  embeddingUseSame: false,
  embeddingEnabled: false,
  embeddingEndpoint: '',
  embeddingModel: '',
  embeddingLlmPresetId: '',
);

final class GuidanceDeniedApi extends ApiConfigRepo {
  GuidanceDeniedApi(super.database, this.block);
  final Never Function(String) block;
  int reads = 0;
  @override
  Future<ApiConfig?> getById(String id) {
    reads++;
    return block('selected API resolver');
  }

  @override
  Future<List<ApiConfig>> getAll() {
    reads++;
    return block('API catalog reader');
  }
}

class _GuidanceVisualSettings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings(
    batterySaver: true,
    batterySaverMode: BatterySaverMode.on,
    hapticFeedback: false,
    messageVibration: false,
    allowMessageScripts: false,
    showOurPicks: false,
  );
}

/// Finite memory locale; never calls SharedPreferences/path_provider/assets.
class GuidanceMemoryLocale extends AssetLoader {
  const GuidanceMemoryLocale();
  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async => {
    for (final key in [
      'title',
      'scope_title',
      'intro',
      'saved_counts',
      'game_picker',
      'support_picker',
      'connections_scope',
      'chooser_not_consent',
      'loaders_unavailable',
      'recipient_title',
      'needs_confirmation',
      'confirmed',
      'recipient_unavailable',
      'right_unavailable',
      'prerequisite',
      'failure',
      'policy_locked',
      'policy_corrupt',
      'policy_unavailable',
      'section_local',
      'section_local_notice',
      'section_model',
      'section_model_notice',
      'section_changes',
      'section_changes_notice',
      'section_network',
      'section_network_notice',
      'section_report',
      'section_report_notice',
    ])
      'support_privacy_$key': key.replaceAll('_', ' '),
    for (final right in SupportPermission.values)
      'support_privacy_right_${right.name}': right.name,
    'support_theme_title': 'Installed theme',
    'support_theme_permissions':
        'Explicit theme scope and local right required',
    'support_theme_scope': 'Theme scope',
    'support_theme_scope_notice': 'Safe theme projection only',
    for (final key in [
      'title',
      'permissions',
      'scope_notice',
      'offline',
      'unavailable',
      'close',
    ])
      'support_provider_$key': key,
  };
}

/// A real CardView -> real focused GuidanceSheet lane, without the screen's model
/// binding (manual chooser tests may save a profile and model with no send).
class GuidanceCardHost extends StatelessWidget {
  const GuidanceCardHost({super.key});
  @override
  Widget build(BuildContext context) => Material(
    child: ListView(
      children: [
        for (final target in SupportGuidanceTarget.values)
          SupportCardView(
            card: SupportGuidanceCard(target: target),
            onGuidance: (value) {
              showModalBottomSheet<void>(
                context: context,
                useRootNavigator: true,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (_) => SupportGuidanceSheet(target: value),
              );
            },
          ),
      ],
    ),
  );
}

void guidanceScreenTest(
  String name,
  Future<void> Function(WidgetTester tester, GuidanceScreenFixture f) body, {
  bool screen = true,
}) {
  testWidgets(name, (tester) async {
    tester.view.physicalSize = const Size(550, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = GuidanceScreenFixture(screen: screen);
    await fixture.run(tester, () => body(tester, fixture));
  });
}
