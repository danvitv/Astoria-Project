import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
// v11 does not export its platform override; keep this seam test-only.
// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/constants/build_channel.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/database_restore_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/startup/database_startup.dart';
import 'package:glaze_flutter/core/utils/platform_paths.dart';
import 'package:glaze_flutter/features/database_recovery/database_recovery_controller.dart';
import 'package:glaze_flutter/features/database_recovery/database_recovery_operation.dart';
import 'package:sqlite3/sqlite3.dart';

import '../db/database_restore/sqlite_native_abi_probe.dart';
import '../startup/startup_memory_keys.dart';

// ignore: implementation_imports
export 'package:file_picker/src/platform/file_picker_platform_interface.dart'
    show FilePickerPlatform;

/// Fresh synthetic installation, native Core, and recording fake key backend.
/// No fabricated accepted result and no installed credential/plugin/prefs input.
final class DatabaseRecoveryFixture {
  DatabaseRecoveryFixture({this.journal = 'DELETE'});
  final String journal;
  late final Directory anchor;
  late final File target, candidate;
  late final NativeDatabaseStartupOwner startup;
  late final ProcessDatabaseStartup process;
  late DatabaseRecoveryCredentials credentials;
  late StartupMemoryKeys keys;
  final operations = <DatabaseRecoveryOperation>[];
  int normalOpens = 0,
      bootstraps = 0,
      publications = 0,
      credentialCompositions = 0;
  ProcessDatabaseStartup? published;

  Future<void> create() async {
    anchor = Directory(
      r'C:\Users\Даниил\AppData\Local\Temp\opencode',
    ).createTempSync('d2-recovery-screen-');
    target = resolveWindowsStartupPaths({'APPDATA': anchor.path}).target;
    target.parent.createSync();
    candidate = File('${anchor.path}\\candidate.db');
    keys = StartupMemoryKeys(base64UrlEncode(List<int>.generate(32, (i) => i)));
    credentials = DatabaseRecoveryCredentials(
      storage: keys,
      channel: buildChannel,
    );
    await _seed(target, journal, 'original');
    await _seed(candidate, 'DELETE', 'candidate');
    keys.reads = keys.writes = keys.deletes = 0;
    startup = NativeDatabaseStartupOwner.acquire(
      existingStartupDirectory: anchor,
      target: target,
    );
    process = ProcessDatabaseStartup.windows(
      owner: startup,
      target: target,
      environment: {'APPDATA': anchor.path},
      openNormal: (_) {
        normalOpens++;
        throw StateError(
          'Ordinary database open forbidden in recovery fixture',
        );
      },
    );
  }

  Future<void> _seed(File file, String mode, String title) async {
    final raw = sqlite3.open(file.path);
    final abi = mode == 'WAL' ? SqliteRestoreTestAbi() : null;
    final db = AppDatabase.openedNative(raw, closeUnderlyingOnClose: false);
    try {
      raw.execute('PRAGMA journal_mode = $mode');
      abi?.preserveWalOnOwnedConnection(raw);
      await ChatRepo(db).put(
        ChatSession(
          id: 'recovery-chat',
          characterId: 'recovery-character',
          sessionIndex: 0,
          messages: [],
        ),
      );
      await SupportRepo(db, credentials.cipher).createSession(
        SupportSession(
          id: 'recovery-support',
          title: title,
          createdAt: 1,
          updatedAt: 2,
        ),
      );
    } finally {
      await db.close();
      raw.close();
      abi?.close();
    }
  }

  DatabaseRecoveryController controller({
    DatabaseRecoveryPicker picker = pickDatabaseRecoveryFile,
    DatabaseRestoreCode? block,
    void Function(DatabaseRestoreTestBoundary)? fault,
  }) => DatabaseRecoveryController(
    process: process,
    initialBlock: block,
    picker: picker,
    bootstrap: () async {
      bootstraps++;
    },
    publishNormal: (value) {
      publications++;
      published = value;
    },
    operationFactory: (current) {
      final operation = DatabaseRecoveryOperation(
        startup: startup,
        picker: picker,
        credentialsFactory: () {
          credentialCompositions++;
          return credentials;
        },
        isViewCurrent: current,
        restoreOwnerFactory:
            ({required startup, required candidate, required payloadCipher}) =>
                NativeDatabaseRestoreOwner.fromStartup(
                  startup: startup,
                  candidate: candidate,
                  payloadCipher: payloadCipher,
                  testFault: fault,
                ),
      );
      operations.add(operation);
      return operation;
    },
  );

  FilePickerResult selection() => FilePickerResult([
    PlatformFile(
      name: 'candidate.db',
      path: candidate.path,
      size: candidate.lengthSync(),
    ),
  ]);

  void expectBusy() => expect(
    () => NativeDatabaseStartupOwner.acquire(
      existingStartupDirectory: anchor,
      target: target,
    ),
    throwsA(
      isA<DatabaseRestoreException>().having(
        (e) => e.code,
        'process-owned guard',
        DatabaseRestoreCode.busy,
      ),
    ),
  );

  Future<void> close(
    DatabaseRecoveryController controller, {
    Future<void> Function()? extraJoin,
  }) async {
    await process.closeForTesting(() async {
      await controller.joinForTesting();
      await extraJoin?.call();
      for (final operation in operations) {
        await operation.cancelAndJoin();
        // Accepted owner is closed EXACTLY through process.closeForTesting.
      }
    });
    _removeKnown(Directory(anchor.path));
  }

  void _removeKnown(Directory directory) {
    final children = directory.listSync(followLinks: false);
    expect(children.length <= 24, true);
    for (final child in children) {
      if (child is Directory) {
        expect(
          child.path == target.parent.path ||
              child.path.split('\\').last.startsWith('.restore-'),
          true,
        );
        _removeKnown(child);
      } else {
        expect(child is File, true);
        (child as File).deleteSync();
      }
    }
    directory.deleteSync();
  }
}

/// Overrides the real platform singleton, rather than replacing controller
/// success/consent. Every production pickFiles named argument is recorded.
final class ControlledRecoveryPicker extends FilePickerPlatform {
  final pending = Completer<FilePickerResult?>();
  int calls = 0;
  FileType? actualType;
  List<String>? actualExtensions;
  bool? actualAllowMultiple, actualWithData;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    void Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
  }) {
    calls++;
    actualType = type;
    actualExtensions = allowedExtensions;
    actualAllowMultiple = allowMultiple;
    actualWithData = withData;
    return pending.future;
  }
}
