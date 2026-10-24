import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/connection_revision_registry.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/native_provider_credentials.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/state/native_provider_runtime.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_recipient_resolution.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_connection_metadata_service.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_runtime.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_store.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_recipient_resolver.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_workspace_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../core/native_provider_fixture.dart' show NativeProviderFakeStorage;
import '../core/native_provider_transport_fixture.dart' show nativeTransportRow;
import 'helpers/support_native_input_fixture.dart' show NativeInputCipher;

/// Fresh synthetic FILE source, exact supplied SQLite handle owned by the real
/// AppDatabase.openedNative executor. No memory fixture can confer file authority.
final class BackupLoopNative {
  static const approvedRoot = r'C:\Users\Даниил\AppData\Local\Temp\opencode';
  static const key = 'SYNTHETIC_BACKUP_LOOP_NATIVE_🔐_кириллица';
  static const private = 'SYNTHETIC_BACKUP_LOOP_PRIVATE_BODY';
  static const rowSecret = 'SYNTHETIC_BACKUP_LOOP_ROW_CREDENTIAL';
  final storage = NativeProviderFakeStorage();
  final primitive = NativeInputCipher();
  final revisions = ConnectionRevisionRegistry();
  final redaction = SecretRedactionCoordinator();
  late final SecretRedactor stableRedactor;
  late Directory directory;
  late String sourcePath, destinationPath;
  late sqlite.Database handle;
  late AppDatabase db;
  late CredentialVault vault;
  late SupportPayloadCipher cipher;
  late SupportRepo repo;
  late ApiConfigRepo apiRepo;
  late NativeProviderRuntime native;
  late SupportWorkspaceStore workspace;
  late SupportPermissionStore permissions;
  late SupportNativeRuntime runtime;
  late SupportRecipientResolver resolver;
  late ApiConfig api;
  late String session;
  void Function()? unlisten;
  HttpClientAdapter Function()? wireFactory;
  void Function()? onCurrent;
  bool rootCurrent = true;
  bool created = false, opened = false, databaseReady = false;
  bool nativeReady = false, runtimeReady = false;
  bool _closed = false;

  Future<void> initialize(BackupLoopIo io, {bool memory = false}) async {
    directory = await Directory(approvedRoot).createTemp('model-backup-loop-');
    created = true;
    io.originalDirectory = directory.path;
    sourcePath = p.join(directory.path, 'original.db');
    destinationPath = p.join(directory.path, 'local-backup.db');
    handle = memory
        ? sqlite.sqlite3.openInMemory()
        : sqlite.sqlite3.open(sourcePath);
    opened = true;
    handle.execute('PRAGMA journal_mode=WAL');
    handle.execute('PRAGMA wal_autocheckpoint=0');
    handle.execute('PRAGMA busy_timeout=0');
    db = AppDatabase.openedNative(handle, closeUnderlyingOnClose: false);
    databaseReady = true;
    expect(db.nativeDataSourceIdentity, isNull);
    await db.customSelect('SELECT 1').get();
    expect(db.allTables.length, 61);
    expect(
      db.nativeDataSourceIdentity?.belongsTo(db),
      memory ? isNull : isTrue,
    );
    vault = CredentialVault(storage: storage, buildChannel: 'dev');
    cipher = SupportPayloadCipher(vault: vault, cipher: primitive);
    repo = SupportRepo(db, cipher);
    native = NativeProviderRuntime(
      vault: vault,
      redaction: redaction,
      revisions: revisions,
      readSavedConnection: (id) => apiRepo.getById(id),
      adapterFactory: () =>
          wireFactory?.call() ??
          (throw StateError('No undeclared native adapter')),
      isOriginalRoot: () {
        onCurrent?.call();
        return rootCurrent;
      },
    );
    nativeReady = true;
    apiRepo = ApiConfigRepo(
      db,
      onMutationStarted: native.onApiMutationStarted,
      onConfigObserved: (row) {
        redaction.registerSecret(row.apiKey);
        redaction.registerSecret(row.embeddingApiKey);
      },
      keylessMutations: native.keylessMutations,
      ordinaryMutations: native.ordinaryMutations,
    );
    workspace = SupportWorkspaceStore(repo, () => redaction.redactor);
    permissions = SupportPermissionStore(
      repo,
      newIdentity: () => 'backup-loop-policy',
    );
    runtime = SupportNativeRuntime(
      permissions: permissions,
      resolveRecipient: (id) => resolver.resolve(id),
      loadSelectedConnection: (id, current) =>
          SupportConnectionMetadataService(
            apiRepo,
            () => redaction.redactor,
            nativeMetadata: native.credentialReader,
            nativeMetadataIsCurrent: () => native.isCurrent,
          ).loadSelected(
            id,
            resolver,
            workspace.readableSettingsFor,
            isCurrent: current,
          ),
      configurationRevision: () => revisions.revision,
      configurationStable: () => revisions.isStable,
    );
    runtimeReady = true;
    resolver = SupportRecipientResolver(
      apiRepo: apiRepo,
      readSettings: workspace.readableSettingsFor,
      currentContext: () => runtime.recipientContext,
      revisions: revisions,
      redactor: () => redaction.redactor,
    );
    unlisten = revisions.subscribe(runtime.invalidateConfiguration);
    api = nativeTransportRow(
      'openai',
    ).copyWith(name: 'Synthetic backup connection');
    await apiRepo.put(api);
    api = (await apiRepo.getById(api.id))!;
    final reference = native.auth.referenceFor(
      api,
      NativeProviderPurpose.astoria,
    )!;
    final review = await native.secretEntry.review(
      connection: reference,
      purposes: const {NativeProviderPurpose.astoria},
      lifetime: NativeProviderViewLifetime(isCurrent: () => rootCurrent),
    );
    await native.credentials.storeFromNativeEntry(
      permit: native.secretEntry.confirmNativeEntry(review),
      secret: key,
    );
    session = await workspace.create('Synthetic model backup');
    await workspace.changeSettings(
      session,
      (_) => SupportAssistantSettings(
        apiConfigId: api.id,
        modelId: api.model,
        maxTokens: 512,
        temperature: 0.25,
        reasoningEffort: SupportReasoningEffort.off,
      ),
    );
    runtime.selectSession(session);
    await reconfirm();
    // Seed only declared synthetic data, before graph and outside every ROOT.
    redaction.registerSecret(private);
    redaction.registerSecret(rowSecret);
    await repo.createSession(
      const SupportSession(
        id: 'excluded-backup-session',
        title: 'Excluded',
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    await repo.putMessage(
      const SupportMessage(
        id: 'excluded-backup-message',
        sessionId: 'excluded-backup-session',
        role: 'user',
        body: private,
        createdAt: 1,
      ),
    );
    handle.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    handle.execute('BEGIN');
    handle.execute(
      'INSERT INTO characters (char_id,name,description) VALUES (?,?,?)',
      ['private-backup-card', 'Synthetic private card', private],
    );
    handle.execute(
      'INSERT INTO api_configs (config_id,name,api_key) VALUES (?,?,?)',
      ['private-backup-api', 'Synthetic private API', rowSecret],
    );
    handle.execute(
      'CREATE TABLE backup_loop_extra (id INTEGER PRIMARY KEY, body BLOB NOT NULL)',
    );
    handle.execute('INSERT INTO backup_loop_extra VALUES (?,?)', [
      1,
      private.codeUnits,
    ]);
    handle.execute(
      'CREATE INDEX backup_loop_extra_index ON backup_loop_extra(body)',
    );
    handle.execute(
      'CREATE VIEW backup_loop_extra_view AS SELECT id FROM backup_loop_extra',
    );
    handle.execute(
      'CREATE TRIGGER backup_loop_extra_trigger AFTER INSERT ON backup_loop_extra BEGIN SELECT 1; END',
    );
    handle.execute('COMMIT');
    if (!memory) expect(await File('$sourcePath-wal').length(), greaterThan(0));
    stableRedactor =
        redaction.redactor; // This ONE instance is retained thereafter.
  }

  Future<void> reconfirm() async {
    await runtime.refresh(resolve: true);
    final recipient = runtime.recipient as SupportResolvedRecipient;
    await permissions.selectRecipientFromNative(
      session,
      recipient.recipient,
      isCurrent: () => rootCurrent,
    );
    await runtime.refresh(resolve: true);
    runtime.recipientConfirmed =
        true; // Synthetic native review, never model JSON.
  }

  void clearHooks() {
    onCurrent = null;
    storage.beforeRead = null;
    storage.beforeWrite = null;
    primitive.beforeDecrypt = null;
    primitive.afterEncrypt = null;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    clearHooks();
    final failure = BackupLoopFailure();
    unlisten?.call();
    if (runtimeReady) await failure.run(runtime.dispose);
    if (nativeReady) await failure.run(native.dispose);
    await failure.run(revisions.dispose);
    await failure.run(redaction.dispose);
    if (databaseReady) await failure.run(db.close);
    if (opened) await failure.run(handle.close);
    if (created)
      await failure.run(() async {
        await for (final entry in directory.list(followLinks: false)) {
          expect(p.dirname(entry.path), directory.path);
          if (entry is! File && entry is! Link) {
            throw TestFailure('Unexpected non-flat synthetic backup directory');
          }
          await entry.delete();
        }
        await directory.delete();
      });
    failure.throwIfAny();
  }
}

/// File/socket tripwires precede source initialization. Only this unique subtree
/// is admitted. Native SQLite/Windows FFI is not claimed to be a universal sandbox.
final class BackupLoopIo extends IOOverrides {
  String? originalDirectory;
  final attempts = <String>[];
  Never block(String boundary) {
    attempts.add(boundary);
    throw StateError('Outside synthetic backup loop boundary');
  }

  bool _inside(String path) =>
      originalDirectory != null &&
      p.isAbsolute(path) &&
      (p.equals(path, originalDirectory!) ||
          p.isWithin(originalDirectory!, path));
  @override
  File createFile(String path) {
    if (!_inside(path)) block('file/default database');
    return super.createFile(path);
  }

  @override
  Directory createDirectory(String path) {
    if (!_inside(path) && path != BackupLoopNative.approvedRoot)
      block('directory');
    return super.createDirectory(path);
  }

  @override
  Link createLink(String path) => block('link');
  @override
  Future<Socket> socketConnect(
    host,
    int port, {
    sourceAddress,
    int sourcePort = 0,
    Duration? timeout,
  }) => block('socket.connect');
  @override
  Future<ConnectionTask<Socket>> socketStartConnect(
    host,
    int port, {
    sourceAddress,
    int sourcePort = 0,
  }) => block('socket.startConnect');
}

final class BackupLoopFailure {
  Object? _error;
  StackTrace? _stack;
  Future<void> run(FutureOr<void> Function() action) async {
    try {
      await action();
    } catch (error, stack) {
      _error ??= error;
      _stack ??= stack;
    }
  }

  void throwIfAny() {
    if (_error != null) Error.throwWithStackTrace(_error!, _stack!);
  }
}

/// Immediately attach a handler to ORIGINAL real-async signals. No stub receipt.
final class BackupLoopSignal<T> {
  BackupLoopSignal(this.original) {
    settled = original.then<void>(
      (value) {
        _value = value;
        done = true;
      },
      onError: (Object error, StackTrace stack) {
        _error = error;
        _stack = stack;
        done = true;
      },
    );
  }
  final Future<T> original;
  late final Future<void> settled;
  T? _value;
  Object? _error;
  StackTrace? _stack;
  bool done = false;
  void throwIfFailed() {
    if (_error != null) Error.throwWithStackTrace(_error!, _stack!);
  }

  T get value {
    throwIfFailed();
    return _value as T;
  }
}
