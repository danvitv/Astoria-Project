import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../constants/build_channel.dart';
import '../credentials/credential_storage.dart';
import '../credentials/credential_vault.dart';
import '../db/app_db.dart';
import '../db/repositories/database_restore_repo.dart';
import '../db/repositories/llm_request_capture_repo.dart';
import '../state/credential_vault_provider.dart';
import '../state/db_provider.dart';
import '../support/support_payload_cipher.dart';
import '../utils/platform_paths.dart';

enum DatabaseStartupSelection { normal, recovery, rejected }

/// Arguments select a surface, never a file, approval or persisted action.
DatabaseStartupSelection parseDatabaseStartupArguments(List<String> args) {
  if (args.isEmpty) return DatabaseStartupSelection.normal;
  if (args.length == 1 && args.single == '--astoria-recovery') {
    return DatabaseStartupSelection.recovery;
  }
  return DatabaseStartupSelection.rejected;
}

/// Compose only after a fresh picker result. Neither construction reads storage.
/// Retain these SAME owners when entering the normal application after recovery.
final class DatabaseRecoveryCredentials {
  DatabaseRecoveryCredentials({required this.storage, required String channel})
    : vault = CredentialVault(storage: storage, buildChannel: channel) {
    cipher = SupportPayloadCipher(vault: vault);
  }

  factory DatabaseRecoveryCredentials.native() => DatabaseRecoveryCredentials(
    storage: FlutterSecureCredentialStorage(
      const FlutterSecureStorage(),
      buildChannel: buildChannel,
    ),
    channel: buildChannel,
  );

  final CredentialStorage storage;
  final CredentialVault vault;
  late final SupportPayloadCipher cipher;
}

/// Process-owned storage, not a widget/scope lifetime or global writer drain.
/// Production retains this object, its guard and raw DB until OS termination.
final class ProcessDatabaseStartup {
  ProcessDatabaseStartup.windows({
    required NativeDatabaseStartupOwner owner,
    required File target,
    required Map<String, String> environment,
    AppDatabase Function(File)? openNormal,
  }) : startupOwner = owner,
       target = target,
       environment = Map.unmodifiable(environment),
       _openNormal = openNormal ?? _openFixedNormal;

  ProcessDatabaseStartup.otherPlatforms()
    : startupOwner = null,
      target = null,
      environment = null,
      _openNormal = null {
    if (Platform.isWindows) {
      throw const DatabaseRestoreException(DatabaseRestoreCode.unavailable);
    }
  }

  static ProcessDatabaseStartup acquireWindows(
    Map<String, String> environment,
  ) {
    final paths = resolveWindowsStartupPaths(environment);
    final owner = NativeDatabaseStartupOwner.acquire(
      existingStartupDirectory: paths.startupDirectory,
      target: paths.target,
    );
    return ProcessDatabaseStartup.windows(
      owner: owner,
      target: paths.target,
      // Only the fixed anchor is needed by the guarded migration pipeline.
      environment: {'APPDATA': paths.startupDirectory.path},
    );
  }

  final NativeDatabaseStartupOwner? startupOwner;
  final File? target;
  final Map<String, String>? environment;
  final AppDatabase Function(File)? _openNormal;
  AppDatabase? _database;
  LlmRequestCaptureRepo? _capture;
  AcceptedDatabaseRestore? _accepted;
  DatabaseRecoveryCredentials? _credentials;
  Future<void>? _opening;
  bool _fixtureClosed = false;
  bool _storageBootstrapAdmitted = false;

  AppDatabase get database =>
      _database ?? (throw StateError('Startup not admitted'));
  LlmRequestCaptureRepo get capture =>
      _capture ?? (throw StateError('Startup not admitted'));
  bool get normalOpeningBlocked => startupOwner?.normalOpeningBlocked ?? false;
  bool get storageBootstrapAdmitted =>
      _storageBootstrapAdmitted && !_fixtureClosed;

  Future<void> openNormal(Future<void> Function() bootstrap) {
    if (_opening != null || _database != null) {
      throw const DatabaseRestoreException(DatabaseRestoreCode.stale);
    }
    startupOwner?.claimNormalOpening(); // One-way, before the first migration.
    _storageBootstrapAdmitted = true;
    return _opening = _openAfterBootstrap(bootstrap);
  }

  Future<void> _openAfterBootstrap(Future<void> Function() bootstrap) async {
    await bootstrap();
    if (_fixtureClosed)
      throw const DatabaseRestoreException(DatabaseRestoreCode.closed);
    _install(target == null ? AppDatabase() : _openNormal!(target!));
  }

  /// Capability branch, deliberately NOT claimNormalOpening. Keep originals.
  void retainAccepted(
    AcceptedDatabaseRestore accepted,
    DatabaseRecoveryCredentials credentials,
  ) {
    if (_database != null || _opening != null || startupOwner == null) {
      throw const DatabaseRestoreException(DatabaseRestoreCode.stale);
    }
    _accepted = accepted;
    _credentials = credentials;
    _install(accepted.database); // The exact already-open wrapper/raw.
    _storageBootstrapAdmitted = true;
  }

  Future<void> finishAcceptedBootstrap(Future<void> Function() bootstrap) {
    if (_accepted == null || _opening != null) {
      throw const DatabaseRestoreException(DatabaseRestoreCode.stale);
    }
    return _opening = bootstrap();
  }

  void _install(AppDatabase db) {
    _database = db;
    _capture = LlmRequestCaptureRepo(db);
  }

  List<Override> get providerOverrides => [
    appDbProvider.overrideWithValue(database),
    llmRequestCaptureRepoProvider.overrideWithValue(capture),
    if (_credentials case final credentials?) ...[
      credentialStorageProvider.overrideWithValue(credentials.storage),
      credentialVaultProvider.overrideWithValue(credentials.vault),
      supportPayloadCipherProvider.overrideWithValue(credentials.cipher),
    ],
  ];

  static AppDatabase _openFixedNormal(File target) {
    // Only after admission + actual migrations. Preserve the ordinary lazy
    // background executor, while the accepted branch keeps its SAME live raw.
    return AppDatabase.fixedNativeFile(target);
  }

  /// Test owner supplies a join of ALL its original picker/restore/snapshot work.
  /// A failing join/close never reaches guard release. Not used by live startup.
  @visibleForTesting
  Future<void> closeForTesting(Future<void> Function() joinKnownWork) async {
    if (_fixtureClosed) return;
    await joinKnownWork();
    await _opening;
    await _capture?.close();
    if (_accepted case final accepted?) {
      await accepted.close();
    } else {
      await _database?.close();
    }
    // This method itself is fixture-only; production never releases custody.
    // ignore: invalid_use_of_visible_for_testing_member
    startupOwner?.closeForTesting();
    _fixtureClosed = true;
  }
}

/// The normal scope used by main on EVERY keyed UI restart. Value overrides
/// bypass provider factory disposers; this widget never owns process shutdown.
class ProcessDatabaseScope extends StatelessWidget {
  const ProcessDatabaseScope({
    super.key,
    required this.process,
    required this.child,
  });
  final ProcessDatabaseStartup process;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      ProviderScope(overrides: process.providerOverrides, child: child);
}
