import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/database_restore_repo.dart';
import 'package:glaze_flutter/core/services/database_snapshot_service.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/core/utils/platform_paths.dart';

import 'database_restore_core_fixture.dart';

/// Only a disposable APPDATA-shaped subtree of the existing approved fixture.
/// Core seed and ABI fixture are reused, not audited or reimplemented here.
final class RestoreStartupFixture {
  RestoreStartupFixture(this.core, {bool withoutSharedMemorySeed = false}) {
    anchor = Directory('${core.directory.path}\\startup');
    anchor.createSync();
    final paths = resolveWindowsStartupPaths({'APPDATA': anchor.path});
    target = paths.target;
    target.parent.createSync();
    // Closed synthetic seed files only. No real installation/prefs/vault input.
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      if (withoutSharedMemorySeed && suffix == '-shm') continue;
      final source = File('${core.target.path}$suffix');
      if (source.existsSync()) source.copySync('${target.path}$suffix');
    }
    if (withoutSharedMemorySeed) {
      expect(File('${target.path}-wal').lengthSync(), greaterThan(0));
      expect(File('${target.path}-shm').existsSync(), false);
    }
    startup = NativeDatabaseStartupOwner.acquire(
      existingStartupDirectory: paths.startupDirectory,
      target: target,
    );
  }
  final RestoreCoreFixture core;
  late final Directory anchor;
  late final File target;
  late final NativeDatabaseStartupOwner startup;
  final owners = <NativeDatabaseRestoreOwner>[];
  final snapshots = <DatabaseSnapshotService>[];

  NativeDatabaseRestoreOwner owner({
    SupportPayloadCipher? cipher,
    void Function(DatabaseRestoreTestBoundary)? fault,
  }) {
    final owner = NativeDatabaseRestoreOwner.fromStartup(
      startup: startup,
      candidate: core.candidate,
      payloadCipher: cipher ?? core.cipher,
      testFault: fault,
    );
    owners.add(owner);
    core.owners.add(owner);
    return owner;
  }

  void expectBusy() => expect(
    () => NativeDatabaseStartupOwner.acquire(
      existingStartupDirectory: anchor,
      target: target,
    ),
    throwsA(
      isA<DatabaseRestoreException>().having(
        (e) => e.code,
        'same process guard',
        DatabaseRestoreCode.busy,
      ),
    ),
  );

  Future<void> close() async {
    for (final service in snapshots) {
      await service.close();
    }
    for (final owner in owners.reversed) {
      await owner.close();
    }
    startup.closeForTesting();
    // Known, bounded, unique fixture descendants only, after actual safe close.
    final children = target.parent.listSync();
    expect(children.length <= 24, true);
    for (final child in children) {
      if (child is Directory) {
        expect(child.path.split('\\').last.startsWith('.restore-'), true);
        final files = child.listSync();
        expect(files.length <= 16, true);
        for (final file in files) {
          expect(file is File, true);
          (file as File).deleteSync();
        }
        child.deleteSync();
      } else {
        (child as File).deleteSync();
      }
    }
    target.parent.deleteSync();
    File('${anchor.path}\\.astoria-restore-startup.lock').deleteSync();
    anchor.deleteSync();
  }
}
