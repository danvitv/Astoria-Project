import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_runtime.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_theme_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';

import '../credentials/fake_credential_storage.dart';
import '../theme_selection_test_store.dart';
import 'helpers/support_mutation_journal_fixture.dart';
import 'support_theme_provider_isolation.dart';
import 'support_theme_provider_theme.dart';
import 'support_theme_provider_vault.dart';

export '../theme_selection_test_store.dart';
export 'helpers/support_mutation_journal_fixture.dart' show JournalBarrier;

void themeProviderTest(
  String name,
  Future<void> Function(ThemeProviderFixture) body,
) {
  test(name, () async {
    final isolation = ThemeProviderIsolation();
    await isolation.run(() async {
      // Construction AND declared schema initialization are inside every guard.
      final fixture = ThemeProviderFixture(isolation);
      Object? failure;
      StackTrace? trace;
      try {
        await fixture.initialize();
        await body(fixture);
      } catch (error, stack) {
        failure = error;
        trace = stack;
      } finally {
        try {
          await fixture.close();
        } catch (error, stack) {
          failure ??= error;
          trace ??= stack;
        }
      }
      if (failure != null) Error.throwWithStackTrace(failure, trace!);
    });
  });
}

/// Actual native/C/workspace/action providers and actual ThemeNotifier. Original
/// real AEAD/FakeVault, independently backed/cache-controlled theme store. No App,
/// provider fake action/runtime/Send or production preferences/API query allowed.
final class ThemeProviderFixture {
  ThemeProviderFixture(this.isolation) {
    sql.block = isolation.block;
    db = ThemeProviderDatabase(NativeDatabase.memory().interceptWith(sql));
    databases.add(db);
    final guardedStorage = ThemeProviderVaultStorage(storage, isolation.block);
    vault = CredentialVault(
      storage: guardedStorage,
      buildChannel: 'theme_provider_test',
    );
    cipher = SupportPayloadCipher(vault: vault, cipher: primitive);
    repo = SupportRepo(db, cipher);
    harness = ThemeProviderTheme(backing);
    themes.add(harness);
    isolation.controls.addAll([_database, _cipher, _theme]);
    container = ProviderContainer(
      observers: [isolation],
      overrides: [
        _database.overrideWith(() => _Choice(db)),
        _cipher.overrideWith(() => _Choice(cipher)),
        _theme.overrideWith(() => _Choice(harness)),
        appDbProvider.overrideWith((ref) => ref.watch(_database)),
        supportPayloadCipherProvider.overrideWith((ref) => ref.watch(_cipher)),
        themeProvider.overrideWith((ref) {
          final owner = ref.watch(_theme);
          ref.onDispose(() => owner.providerDisposed = true);
          return owner.notifier;
        }),
        credentialStorageProvider.overrideWithValue(guardedStorage),
        credentialVaultProvider.overrideWithValue(vault),
        secretRedactionCoordinatorProvider.overrideWithValue(redaction),
        apiConfigRepoProvider.overrideWith(
          (ref) => ApiConfigRepo(ref.watch(appDbProvider)),
        ),
        sharedPreferencesProvider.overrideWith(
          (_) => isolation.block('default preferences'),
        ),
        apiConfigCredentialAdapterProvider.overrideWith(
          (_) => isolation.block('API credentials'),
        ),
        supportConnectionMetadataProvider.overrideWith(
          (_) => isolation.block('bulk connection metadata'),
        ),
        supportModelUiBridgeProvider.overrideWith(
          (_) => isolation.block('model bridge'),
        ),
        supportModelPrivateAdapterFactoryProvider.overrideWith(
          (_) => isolation.block('model adapter'),
        ),
        llmRequestCaptureInstallationProvider.overrideWith(
          (_) => isolation.block('capture startup'),
        ),
        imageStorageProvider.overrideWith(
          (_) => isolation.block('image startup'),
        ),
        migrationServiceProvider.overrideWith(
          (_) => isolation.block('production migration'),
        ),
      ],
    );
  }

  static const session = 'theme-provider-session',
      other = 'theme-provider-other';
  final ThemeProviderIsolation isolation;
  final sql = _LocalSql();
  final primitive = JournalControlledCipher();
  final storage = FakeCredentialStorage();
  final redaction = SecretRedactionCoordinator();
  final backing = ThemeSelectionBacking();
  final databases = <AppDatabase>[];
  final themes = <ThemeProviderTheme>[];
  final barriers = <JournalBarrier>[];
  final gates = <ThemeSelectionGate>[];
  final custodies = <SupportThemeActionCustody>{};
  final jobs = <Future<SupportThemeActionResult>>[];
  late final ThemeProviderDatabase db;
  late final CredentialVault vault;
  late final SupportPayloadCipher cipher;
  late final SupportRepo repo;
  late final ProviderContainer container;
  late ThemeProviderTheme harness;
  bool disposed = false, uiCurrent = true;
  Object uiLifetime = Object();
  SupportWorkspaceNotifier get workspace =>
      container.read(supportWorkspaceProvider.notifier);
  SupportWorkspaceState get state => container.read(supportWorkspaceProvider);
  SupportNativeRuntime get runtime =>
      container.read(supportNativeRuntimeProvider);
  SupportNativeConsentController get controller =>
      container.read(supportNativeConsentControllerProvider);
  SupportThemeUiBinding get binding =>
      container.read(supportThemeUiBindingProvider);
  SupportThemeActionCustody get custody {
    final value = container.read(supportThemeActionCustodyProvider);
    custodies.add(value);
    return value;
  }

  Future<void> initialize() async {
    await db.customSelect('SELECT 1').getSingle();
    for (final id in [session, other]) {
      await repo.createSession(
        SupportSession(id: id, title: 'Synthetic', createdAt: 1, updatedAt: 1),
      );
    }
    workspace;
    await container.pump();
    await workspace.refresh();
    workspace.selectSession(session);
    await workspace.refresh();
    await enableTheme();
    await harness.notifier.flushPersistence();
    custody;
    binding;
    container.listen(supportThemePresentationProvider, (_, next) {
      presentations.add(next);
    });
    sql.statements.clear();
  }

  final presentations = <int>[];
  Future<void> enableTheme() async {
    final review = (await controller.prepareReview(resolveRecipient: false))!;
    expect(await controller.selectTheme(review, true), isTrue);
    for (final right in [
      SupportPermission.readSafeSettings,
      SupportPermission.confirmedSettingsChanges,
    ]) {
      final fresh = (await controller.prepareReview(resolveRecipient: false))!;
      expect(await controller.setGrant(fresh, right, true), isTrue);
    }
  }

  SupportThemeUiIntent? emit() {
    final originalUi = uiLifetime;
    return binding.emit(
      displayedIntent: controller.view.displayedIntent!,
      uiLifetime: originalUi,
      isUiCurrent: () => uiCurrent && identical(originalUi, uiLifetime),
    );
  }

  Future<SupportThemeReview> review(
    SupportThemeUiIntent intent, [
    String id = 'b',
  ]) async {
    final observation = (await intent.observe())!;
    final choice = intent
        .installed(observation)!
        .choices
        .singleWhere((choice) => choice.value?.id == id);
    return (await intent.prepareApply(choice))!;
  }

  Future<SupportThemeActionResult> confirm(
    SupportThemeUiIntent intent,
    SupportThemeReview review,
  ) {
    final job = intent.confirm(review)!;
    jobs.add(job);
    return job;
  }

  Future<SupportThemeActionResult> apply() async {
    final intent = emit()!;
    return confirm(intent, await review(intent));
  }

  JournalBarrier barrier() {
    final barrier = JournalBarrier();
    barriers.add(barrier);
    return barrier;
  }

  ThemeSelectionGate gate() {
    final gate = ThemeSelectionGate();
    gates.add(gate);
    return gate;
  }

  Future<void> replaceCipher() async {
    container
        .read(_cipher.notifier)
        .replace(SupportPayloadCipher(vault: vault, cipher: primitive));
    await reconcile();
  }

  Future<void> replaceTheme() async {
    harness = ThemeProviderTheme(backing);
    themes.add(harness);
    await harness.notifier.flushPersistence();
    container.read(_theme.notifier).replace(harness);
    await reconcile();
  }

  Future<void> replaceDatabase() async {
    final replacement = ThemeProviderDatabase(
      NativeDatabase.memory().interceptWith(sql),
    );
    databases.add(replacement);
    await replacement.customSelect('SELECT 1').getSingle();
    container.read(_database.notifier).replace(replacement);
    await reconcile();
  }

  Future<void> reconcile() async {
    custody;
    binding;
    await container.pump();
    await workspace.refresh();
    if (state.sessions.any((row) => row.id == session)) {
      workspace.selectSession(session);
      await workspace.refresh();
      await runtime.refresh(resolve: false);
    }
  }

  Future<void> close() async {
    Object? failure;
    StackTrace? trace;
    Future<void> cleanup(Future<void> Function() work) async {
      try {
        await work();
      } catch (error, stack) {
        failure ??= error;
        trace ??= stack;
      }
    }

    primitive.event = null;
    sql.event = null;
    db.afterCommit = null;
    storage.readError = null;
    storage.writeError = null;
    for (final barrier in barriers) {
      if (!barrier.release.isCompleted) barrier.release.complete();
    }
    for (final gate in gates) {
      if (!gate.release.isCompleted) gate.release.complete();
    }
    for (final custody in custodies) {
      await cleanup(custody.drain);
    }
    await cleanup(() async => Future.wait(jobs));
    for (final theme in themes) {
      if (!theme.providerDisposed) {
        await cleanup(theme.notifier.flushPersistence);
      }
    }
    if (!disposed) {
      disposed = true;
      await cleanup(() async => container.dispose());
    }
    for (final theme in themes) {
      theme.releaseDelays();
    }
    await Future<void>.value();
    redaction.dispose();
    for (final database in databases) {
      await cleanup(database.close);
    }
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  }
}

final _database = NotifierProvider<_Choice<AppDatabase>, AppDatabase>(
  () => throw StateError('Must inject owned declared DB.'),
);
final _cipher =
    NotifierProvider<_Choice<SupportPayloadCipher>, SupportPayloadCipher>(
      () => throw StateError('Must inject fake-vault real AEAD.'),
    );
final _theme =
    NotifierProvider<_Choice<ThemeProviderTheme>, ThemeProviderTheme>(
      () => throw StateError('Must inject independent actual theme store.'),
    );

final class _Choice<T> extends Notifier<T> {
  _Choice(this.initial);
  final T initial;
  @override
  T build() => initial;
  void replace(T next) => state = next;
}

/// OWN declared-memory schema, no inherited migration/seeding/bootstrap hooks.
final class ThemeProviderDatabase extends AppDatabase {
  ThemeProviderDatabase(super.e) : super.forTesting();
  @override
  MigrationStrategy get migration =>
      MigrationStrategy(onCreate: (m) => m.createAll());
  Future<void> Function()? afterCommit;
  @override
  Future<T> transaction<T>(
    Future<T> Function() action, {
    bool requireNew = false,
  }) async {
    final durable = await super.transaction(action, requireNew: requireNew);
    // A delivered transaction checkpoint, NOT physical COMMIT/power-loss proof.
    await afterCommit?.call();
    return durable;
  }
}

/// Pure classification boundary; calling it never constructs a DB or provider.
void checkThemeProviderSql(String statement, Never Function(String) block) {
  // Existing declared-schema allowance, not permission for production bootstrap.
  if (RegExp(
    r'^\s*(CREATE|PRAGMA)\b',
    caseSensitive: false,
  ).hasMatch(statement)) {
    return;
  }
  final sql = statement.trim().replaceFirst(RegExp(r';$'), '');
  if (sql.contains(';') || sql.contains('--') || sql.contains('/*')) {
    block('unsupported SQL shape');
  }
  final operation = RegExp(
    r'^(SELECT|INSERT|UPDATE|DELETE)\b',
    caseSensitive: false,
  ).firstMatch(sql);
  if (operation == null) block('unsupported SQL shape');

  // UPDATE has a target only at statement start. UPSERT's DO UPDATE SET does
  // not introduce a table; its INSERT INTO and any nested FROM/JOIN still do.
  final sources = RegExp(
    r'\b(?:from|join|into)\b|^update\b',
    caseSensitive: false,
  ).allMatches(sql).toList();
  if (sources.isEmpty &&
      !RegExp(r'^SELECT\s+1$', caseSensitive: false).hasMatch(sql)) {
    block('unsupported SQL shape');
  }
  for (final source in sources) {
    final tail = sql.substring(source.end);
    final target = RegExp(
      r'^\s+(?:"([a-z_]+)"|`([a-z_]+)`|([a-z_]+))(?=\s|[();]|$)',
      caseSensitive: false,
    ).firstMatch(tail);
    if (target == null) block('unsupported SQL shape');
    final remainder = tail.substring(target.end);
    if (remainder.trimLeft().startsWith('.')) {
      block('unsupported SQL shape');
    }
    final table = (target[1] ?? target[2] ?? target[3])!.toLowerCase();
    if (!const {
      'sqlite_master',
      'sqlite_schema',
      'support_sessions',
      'support_messages',
      'support_context_blocks',
      'support_mutation_journal',
      'support_reports',
    }.contains(table)) {
      block('API/body/world SQL');
    }
    if (const {'from', 'join'}.contains(source[0]!.toLowerCase()) &&
        !RegExp(
          r'^\s*(?:$|\)|(?:where|join|inner|left|right|full|cross|on|using|group|order|limit|union|intersect|except)\b)',
          caseSensitive: false,
        ).hasMatch(remainder)) {
      // Do not partially accept comma joins, aliases, or table-function targets.
      block('unsupported SQL shape');
    }
  }
}

final class _LocalSql extends QueryInterceptor {
  late Never Function(String) block;
  final statements = <String>[];
  Future<void> Function(String)? event;
  void _check(String statement) {
    statements.add(statement);
    checkThemeProviderSql(statement, block);
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    _check(statement);
    final result = await super.runSelect(executor, statement, args);
    await event?.call('select:$statement');
    return result;
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    _check(statement);
    final result = await super.runUpdate(executor, statement, args);
    await event?.call('update:$statement');
    return result;
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _check(statement);
    return super.runInsert(executor, statement, args);
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _check(statement);
    return super.runDelete(executor, statement, args);
  }

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _check(statement);
    return super.runCustom(executor, statement, args);
  }

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) => block('unexpected SQL batch');
}
