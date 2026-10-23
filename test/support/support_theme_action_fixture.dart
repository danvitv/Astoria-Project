import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_runtime.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_store.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_theme_action_service.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';

import '../credentials/fake_credential_storage.dart';
import '../theme_selection_test_store.dart';
import 'helpers/support_mutation_journal_fixture.dart';

export '../theme_selection_test_store.dart';
export 'helpers/support_mutation_journal_fixture.dart' show JournalBarrier;

SupportThemeApproval forgedThemeApproval(Object? value) =>
    value as SupportThemeApproval;
SupportThemeApplied forgedThemeApplied(Object? value) =>
    value as SupportThemeApplied;

/// Guards precede evaluation and persist through original job/queue/database
/// cleanup. Only owned declared-schema memory SQLite may load its native library.
void themeActionTest(
  String name,
  Future<void> Function(ThemeActionFixture) body,
) {
  test(name, () async {
    final attempts = <String>[];
    Never block(String name) {
      attempts.add(name);
      throw StateError('Outside synthetic theme action fixture.');
    }

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final previous = messenger.allMessagesHandler;
    messenger.allMessagesHandler = (channel, handler, message) =>
        block('native $channel');
    try {
      await HttpOverrides.runZoned(
        () => IOOverrides.runZoned(
          () async {
            final fixture = ThemeActionFixture(block);
            Object? failure;
            StackTrace? stack;
            try {
              await fixture.seed();
              await body(fixture);
            } catch (error, trace) {
              failure = error;
              stack = trace;
            }
            try {
              await fixture.close();
              await messenger.platformMessagesFinished;
              expect(
                attempts,
                isEmpty,
                reason: 'Even swallowed native/HTTP/filesystem attempts fail.',
              );
            } catch (error, trace) {
              failure ??= error;
              stack ??= trace;
            }
            if (failure != null) Error.throwWithStackTrace(failure, stack!);
          },
          createFile: (_) => block('file/default DB'),
          createDirectory: (_) => block('directory/default DB'),
          createLink: (_) => block('link'),
        ),
        createHttpClient: (_) => block('HTTP/model adapter'),
      );
    } finally {
      messenger.allMessagesHandler = previous;
    }
  });
}

final class ThemeActionFixture {
  ThemeActionFixture(this.block) {
    db = JournalMemoryDatabase(NativeDatabase.memory().interceptWith(sql));
    vault = CredentialVault(
      storage: storage,
      buildChannel: 'synthetic_theme_action',
    );
    cipher = SupportPayloadCipher(vault: vault, cipher: primitive);
    repo = SupportRepo(db, cipher);
    permissions = SupportPermissionStore(
      repo,
      newIdentity: () => 'synthetic-policy',
      now: () => 4,
    );
    runtime = makeRuntime();
    custody = SupportThemeActionCustody(
      repo: repo,
      hasOriginalDbCustody: () => dbCurrent,
    );
    harness = ThemeSelectionHarness(backing);
    service = makeService();
    primitive.event = event;
    sql.event = event;
    storage.beforeRead = () => event('vault-read');
    storage.beforeWrite = () => event('vault-write');
  }

  static const session = 'synthetic-theme-session';
  static const privateCanary = 'SYNTHETIC_PRIVATE_THEME_RESOURCE';
  static const labelCanary = 'SYNTHETIC_THEME_LABEL_CANARY';
  static const themeA = ThemePreset(
    id: 'a',
    name: 'Theme A',
    customFont: privateCanary,
    bgImage: privateCanary,
  );
  static const themeB = ThemePreset(
    id: 'b',
    name: 'Theme B',
    accentColor: '#112233',
    chatFont: privateCanary,
    chatBgImage: privateCanary,
  );
  static const themeC = ThemePreset(id: 'c', name: 'Theme C');
  final Never Function(String) block;
  final storage = FakeCredentialStorage();
  final primitive = JournalControlledCipher();
  final sql = JournalControlledSql();
  final redaction = SecretRedactionCoordinator();
  final backing = ThemeSelectionBacking(presets: [themeA, themeB, themeC]);
  late final JournalMemoryDatabase db;
  late final CredentialVault vault;
  late final SupportPayloadCipher cipher;
  late final SupportRepo repo;
  late final SupportPermissionStore permissions;
  late SupportNativeRuntime runtime;
  late final SupportThemeActionCustody custody;
  late ThemeSelectionHarness harness;
  late SupportThemeActionService service;
  final oldServices = <SupportThemeActionService>[];
  final oldRuntimes = <SupportNativeRuntime>[];
  final oldThemes = <ThemeSelectionHarness>[];
  final barriers = <JournalBarrier>[];
  final themeGates = <ThemeSelectionGate>[];
  final events = <String>[];
  Future<void> Function(String)? hook;
  bool dbCurrent = true, uiCurrent = true;
  Object controller = Object(), uiLifetime = Object();
  String? forcedId;
  String lastId = '';
  int counter = 0, configuration = 1;
  ThemeNotifier get theme => harness.notifier;
  ThemeSelectionTestStore get themeStore => harness.store;

  SupportNativeRuntime makeRuntime() => SupportNativeRuntime(
    permissions: permissions,
    resolveRecipient: (_) => block('recipient/API resolver'),
    loadSelectedConnection: (_, _) => block('connection/resource loader'),
    configurationRevision: () => configuration,
    configurationStable: () => true,
  );
  SupportThemeActionService makeService() {
    final original = theme;
    return SupportThemeActionService(
      runtime: runtime,
      theme: original,
      custody: custody,
      redaction: redaction,
      isOriginalThemeOwner: () => identical(theme, original),
      newOperationId: () => lastId =
          forcedId ??
          '11111111-1111-4111-8111-${(++counter).toString().padLeft(12, '0')}',
      now: () => 5,
    );
  }

  Future<void> event(String e) async {
    events.add(e);
    await hook?.call(e);
  }

  JournalBarrier barrier() {
    final b = JournalBarrier();
    barriers.add(b);
    return b;
  }

  ThemeSelectionGate themeGate() {
    final b = ThemeSelectionGate();
    themeGates.add(b);
    return b;
  }

  Future<void> seed() async {
    await repo.createSession(
      const SupportSession(
        id: session,
        title: 'Synthetic theme action',
        createdAt: 1,
        updatedAt: 2,
      ),
    );
    await permissions.selectScopeFromNative(
      session,
      SupportPermissionScope(
        selectionRevision: 1,
        safeCategories: [SupportSafeCategory.theme],
      ),
      isCurrent: () => true,
    );
    await permissions.setGrantFromNative(
      session,
      SupportPermission.readSafeSettings,
      true,
      isCurrent: () => true,
    );
    await permissions.setGrantFromNative(
      session,
      SupportPermission.confirmedSettingsChanges,
      true,
      isCurrent: () => true,
    );
    runtime.selectSession(session);
    await runtime.refresh();
    await theme.flushPersistence();
    events.clear();
  }

  SupportThemeIntent intent() {
    final originalController = controller, originalUi = uiLifetime;
    return service.emit(
      controller: originalController,
      uiLifetime: originalUi,
      isCurrent: () =>
          uiCurrent &&
          identical(controller, originalController) &&
          identical(uiLifetime, originalUi),
    )!;
  }

  Future<SupportThemeReview> review([String id = 'b']) async {
    final observed = (await service.observe(intent()))!;
    final choices = service.projectInstalled(observed)!.choices;
    return (await service.prepareApply(
      choices.singleWhere((c) => c.value?.id == id),
    ))!;
  }

  Future<SupportThemeApproval> approval([String id = 'b']) async =>
      service.approve(await review(id))!;
  Future<SupportThemeActionResult> apply([String id = 'b']) async =>
      service.execute(await approval(id));
  Future<SupportThemeActionResult> undo(SupportThemeApplied applied) async =>
      service.execute(
        service.approve((await service.prepareUndo(intent(), applied))!)!,
      );
  Future<SupportMutationRecord?> record([String? id]) =>
      repo.getMutationById(id ?? lastId);
  Future<void> grant(SupportPermission right, bool enabled) async {
    runtime
        .invalidateLease(); // Native admission revocation before awaited write.
    await permissions.setGrantFromNative(
      session,
      right,
      enabled,
      isCurrent: () => true,
    );
    await runtime.refresh();
  }

  Future<void> replaceRuntime() async {
    oldServices.add(service);
    service.dispose();
    oldRuntimes.add(runtime);
    runtime.dispose();
    runtime = makeRuntime();
    runtime.selectSession(session);
    await runtime.refresh();
    controller = Object();
    uiLifetime = Object();
    uiCurrent = true;
    service = makeService();
  }

  Future<void> replaceTheme() async {
    oldThemes.add(harness);
    harness = ThemeSelectionHarness(backing);
    await theme.flushPersistence();
    await replaceRuntime();
  }

  String publicValue(SupportThemeValue? v) => v == null
      ? 'unavailable'
      : jsonEncode({
          'id': v.id,
          'name': v.name,
          'mode': v.mode,
          'accent': v.accent,
          'active': v.active,
        });
  Future<void> close() async {
    hook = null;
    db.afterCommit = null;
    storage.readError = null;
    storage.writeError = null;
    for (final b in barriers) {
      if (!b.release.isCompleted) b.release.complete();
    }
    for (final b in themeGates) {
      if (!b.release.isCompleted) b.release.complete();
    }
    await custody.drain();
    service.dispose();
    runtime.dispose();
    for (final s in oldServices) {
      s.dispose();
    }
    for (final r in oldRuntimes) {
      r.dispose();
    }
    // Flush/dispose the original independent queues while tripwires remain live.
    await theme.flushPersistence();
    harness.dispose();
    for (final t in oldThemes) {
      await t.notifier.flushPersistence();
      t.dispose();
    }
    redaction.dispose();
    await db.close();
  }
}
