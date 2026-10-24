import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/db/repositories/memory_book_repo.dart';
import 'package:glaze_flutter/core/db/repositories/memory_catalog_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/memory_settings_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_app_action.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/support_app_action_registry.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/support_app_metadata_policy.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_session_memory_provider.dart';
import 'package:glaze_flutter/core/llm/transport/native_tool_types.dart';

import '../../../credentials/fake_credential_storage.dart';
import 'session_memory_isolation.dart';

export 'package:glaze_flutter/features/support_assistant/models/support_app_action.dart';
export 'package:glaze_flutter/core/models/memory_book.dart';
export 'session_memory_isolation.dart';

void sessionMemoryTest(
  String name,
  Future<void> Function(SessionMemoryFixture) body,
) {
  test(name, () async {
    final isolation = SessionMemoryIsolation();
    await isolation.run(() async {
      final f = SessionMemoryFixture(isolation);
      Object? failure;
      StackTrace? failureTrace;
      try {
        await f.seed();
        await body(f);
        expect(
          f.storage.operations.length,
          f.vaultOperationsAfterSeed,
          reason: 'Adapters must never evaluate a credential route.',
        );
        expect(
          await f.container
              .read(supportRepoProvider)
              .getMessageById('protected-support'),
          f.protectedMessage,
        );
      } catch (error, trace) {
        failure = error;
        failureTrace = trace;
      } finally {
        try {
          await f.close();
        } catch (error, trace) {
          failure ??= error;
          failureTrace ??= trace;
        }
      }
      if (failure != null) Error.throwWithStackTrace(failure, failureTrace!);
    });
  });
}

/// Actual provider composition + registry + Drift repositories. Scheduling and
/// exact native gestures are synthetic; persistence never uses a callback mock.
final class SessionMemoryFixture {
  SessionMemoryFixture(this.isolation) {
    vault = CredentialVault(
      storage: storage,
      buildChannel: 'session_memory_test',
    );
    cipher = SupportPayloadCipher(vault: vault); // Real XChaCha AEAD.
    container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        credentialStorageProvider.overrideWithValue(storage),
        credentialVaultProvider.overrideWithValue(vault),
        supportPayloadCipherProvider.overrideWithValue(cipher),
        sharedPreferencesProvider.overrideWith(
          (_) => isolation.block('preferences'),
        ),
        apiConfigRepoProvider.overrideWith(
          (_) => isolation.block('API repository'),
        ),
        nativeProviderAdapterFactoryProvider.overrideWith(
          (_) => isolation.block('network adapter'),
        ),
        imageStorageProvider.overrideWith(
          (_) => isolation.block('image storage'),
        ),
        pipelineSettingsProvider.overrideWith(
          (_) => isolation.block('pipeline settings'),
        ),
        memoryGlobalSettingsProvider.overrideWith(
          (_) => isolation.block('global memory prefs'),
        ),
        memoryBookRepoProvider.overrideWith(
          (ref) => books = DelayedControlBookRepo(db, ref),
        ),
        memoryCatalogRepoProvider.overrideWith(
          (_) => catalog = DelayedControlCatalogRepo(db),
        ),
      ],
    );
    registry = SupportAppActionRegistry(
      adapters: container.read(supportAppControlSessionMemoryProvider),
      metadata: SupportAppRedactedMetadataPolicy(
        currentRedactor: () => redactor,
      ),
      isOriginalOwnerCurrent: () => ownerCurrent,
    );
  }
  static const target = 'roleplay-a', other = 'roleplay-b';
  static const bodyCanary = 'PRIVATE_SESSION_MESSAGE_MEMORY_TITLE_ERROR_CANARY';
  final SessionMemoryIsolation isolation;
  final db = _SessionMemoryDatabase(NativeDatabase.memory());
  final storage = FakeCredentialStorage();
  // Match the production retained immutable snapshot: identity must be stable
  // across the policy's before/after checks, not recreated by its accessor.
  final redactor = SecretRedactor(
    knownSecrets: const ['SYNTHETIC_SECRET_CANARY'],
  );
  final _pendingCalls = <Future<NativeToolResult>>{};
  late final CredentialVault vault;
  late final SupportPayloadCipher cipher;
  late final ProviderContainer container;
  late final SupportAppActionRegistry registry;
  late DelayedControlBookRepo books;
  late DelayedControlCatalogRepo catalog;
  final confirmation = SessionMemoryConfirmation();
  final source = SessionMemorySource();
  final cancel = CancelToken();
  bool ownerCurrent = true;
  int vaultOperationsAfterSeed = 0;
  SupportMessage? protectedMessage;

  ChatRepo get chats => container.read(chatRepoProvider);
  SupportAppActionContext context({
    bool confirm = true,
    bool sourceLease = false,
    SupportAppTerminalRootPort? terminal,
  }) => SupportAppActionContext(
    runId: 'native-synthetic-run',
    sessionId: 'support-synthetic',
    cancelToken: cancel,
    isCurrent: () => ownerCurrent,
    allowReversibleChanges: true,
    confirmation: confirm ? confirmation : null,
    sourceAccess: sourceLease ? source : null,
    terminalRoot: terminal,
  );

  Future<NativeToolResult> call(
    String name,
    Map<String, Object?> arguments, {
    SupportAppActionContext? original,
  }) {
    final operation = registry.execute(
      NativeToolCall(id: 'exact-call', name: name, arguments: arguments),
      original ?? context(),
    );
    _pendingCalls.add(operation);
    // Observe errors immediately while returning the ORIGINAL future to the
    // test. This bookkeeping never converts a failed action into a success.
    operation.then<void>(
      (_) {
        _pendingCalls.remove(operation);
      },
      onError: (Object _, StackTrace __) {
        _pendingCalls.remove(operation);
      },
    );
    return operation;
  }

  Future<void> close() async {
    // Teardown only: retire the original run before releasing held test work,
    // then let every original action settle before disposing Ref/closing SQL.
    cancel.cancel();
    final gate = books.beforePatch;
    if (gate != null && !gate.release.isCompleted) gate.release.complete();
    Object? failure;
    StackTrace? failureTrace;
    try {
      for (final operation in List<Future<NativeToolResult>>.of(
        _pendingCalls,
      )) {
        try {
          await operation;
        } catch (error, trace) {
          failure ??= error;
          failureTrace ??= trace;
        }
      }
    } finally {
      try {
        container.dispose();
      } catch (error, trace) {
        failure ??= error;
        failureTrace ??= trace;
      }
      try {
        await db.close();
      } catch (error, trace) {
        failure ??= error;
        failureTrace ??= trace;
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureTrace!);
  }

  Future<void> seed() async {
    final characters = container.read(characterRepoProvider);
    await characters.put(
      const Character(id: 'char-a', name: bodyCanary, description: bodyCanary),
    );
    await characters.put(const Character(id: 'char-b', name: bodyCanary));
    for (final id in [target, other]) {
      await chats.put(
        ChatSession(
          id: id,
          characterId: id == target ? 'char-a' : 'char-b',
          sessionIndex: 4,
          sessionVars: const {'sessionName': bodyCanary, 'private': bodyCanary},
          messages: const [
            ChatMessage(id: 'msg-a', role: 'user', content: bodyCanary),
            ChatMessage(
              id: 'msg-b',
              role: 'assistant',
              content: bodyCanary,
              swipeId: 1,
              swipes: [bodyCanary, bodyCanary],
              isHidden: true,
            ),
          ],
        ),
      );
    }
    final support = container.read(supportRepoProvider);
    await support.createSession(
      const SupportSession(
        id: 'support-synthetic',
        title: bodyCanary,
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    await support.appendMessage(
      const SupportMessage(
        id: 'protected-support',
        sessionId: 'support-synthetic',
        role: 'user',
        body: bodyCanary,
        createdAt: 2,
      ),
    );
    protectedMessage = await support.getMessageById('protected-support');
    vaultOperationsAfterSeed = storage.operations.length;
  }

  Future<void> seedBooks() async {
    for (final id in [target, other]) {
      await books.put(
        MemoryBook(
          id: 'memorybook_$id',
          sessionId: id,
          settings: const MemoryBookSettings(
            enabled: false,
            promptPreset: bodyCanary,
            autoGenerateEnabled: true,
          ),
          entries: const [
            MemoryEntry(
              id: 'entry-a',
              title: bodyCanary,
              content: bodyCanary,
              locked: true,
            ),
          ],
          pendingDrafts: const [
            MemoryDraft(
              id: 'draft-a',
              title: bodyCanary,
              content: bodyCanary,
              error: bodyCanary,
              status: 'pending_approval',
            ),
          ],
        ),
      );
    }
  }

  Future<String> raw(String table) async {
    const tables = {
      'chat_sessions',
      'memory_book_rows',
      'memory_catalog_rows',
      'embeddings',
      'memory_entity_rows',
      'character_revision_rows',
      'session_canon_checkpoint_rows',
      'tracker_snapshots',
      'llm_request_capture_rows',
    };
    if (!tables.contains(table))
      throw StateError('Unknown synthetic evidence table.');
    return jsonEncode(
      (await db.customSelect('SELECT * FROM $table').get())
          .map((r) => r.data)
          .toList(),
    );
  }
}

final class _SessionMemoryDatabase extends AppDatabase {
  _SessionMemoryDatabase(super.e) : super.forTesting();
  @override
  MigrationStrategy get migration =>
      MigrationStrategy(onCreate: (m) => m.createAll());
}

/// Deterministic scheduling seam, followed by the REAL conditional DB method.
final class DelayedControlBookRepo extends MemoryBookRepo {
  DelayedControlBookRepo(AppDatabase database, Ref ref) : super(database, ref);
  SessionMemoryBarrier? beforePatch;
  void Function()? afterPatch;
  @override
  Future<bool> patchSettingsForControl({
    required MemoryBookControlObservation expected,
    required Map<String, Object?> fields,
    required bool Function() isCurrent,
  }) async {
    await beforePatch?.wait();
    final changed = await super.patchSettingsForControl(
      expected: expected,
      fields: fields,
      isCurrent: isCurrent,
    );
    afterPatch?.call();
    return changed;
  }
}

/// The production catalog builder/DB replacement runs, then the original source
/// can retire before its enclosing Memory Book transaction commits.
final class DelayedControlCatalogRepo extends MemoryCatalogRepo {
  DelayedControlCatalogRepo(AppDatabase database) : super(database);
  void Function()? afterRebuild;
  @override
  Future<List<MemoryCatalogRow>> rebuildForMemoryBook(MemoryBook book) async {
    final rows = await super.rebuildForMemoryBook(book);
    afterRebuild?.call();
    return rows;
  }
}

final class SessionMemoryConfirmation implements SupportAppConfirmationPort {
  SupportAppConfirmationRequest? last;
  bool accept = true, uiCurrent = true;
  SupportAppConfirmationRequest? replacement;
  Future<void> Function(SupportAppConfirmationRequest)? beforeDecision;
  @override
  Future<SupportAppConfirmationLease?> confirm(
    SupportAppConfirmationRequest request,
  ) async {
    last = request;
    await beforeDecision?.call(request);
    return accept
        ? SupportAppConfirmationLease(
            request: replacement ?? request,
            isOriginalUiCurrent: () => uiCurrent,
          )
        : null;
  }
}

final class SessionMemorySource implements SupportAppSourceAccessPort {
  bool current = true, allowed = true;
  int releases = 0, acquisitions = 0;
  Object? observation;
  Future<void> Function()? beforeAcquire;
  @override
  Future<SupportAppSourceLease?> acquire({
    required String domain,
    required String sourceId,
    required Object observation,
    required SupportAppActionContext context,
  }) async {
    acquisitions++;
    this.observation = observation;
    expect(domain, 'memory_book');
    expect(sourceId, 'memorybook_${SessionMemoryFixture.target}');
    await beforeAcquire?.call();
    return allowed ? _SessionMemorySourceLease(this, context) : null;
  }
}

final class _SessionMemorySourceLease implements SupportAppSourceLease {
  _SessionMemorySourceLease(this.source, this.context);
  final SessionMemorySource source;
  final SupportAppActionContext context;
  bool released = false;
  @override
  bool get isCurrent => !released && source.current && context.current;
  @override
  void release() {
    if (!released) source.releases++;
    released = true;
  }
}

final class SessionMemoryTerminalRoot implements SupportAppTerminalRootPort {
  int admissions = 0;
  @override
  Future<void> admit(KeylessTerminalEffectDispatch dispatch) async {
    admissions++;
    throw StateError('A Memory Book must not forge a keyless terminal plan.');
  }
}
