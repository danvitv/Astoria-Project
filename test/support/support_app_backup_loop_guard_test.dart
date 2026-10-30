import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support_app_backup_loop_native.dart';

void main() {
  test(
    'backup bootstrap denies early files and unowned directory factories',
    () {
      final io = BackupLoopIo();
      IOOverrides.runWithIOOverrides(() {
        for (final path in [
          BackupLoopNative.approvedRoot,
          '${BackupLoopNative.approvedRoot}\\model-backup-loop-not-owned',
        ]) {
          expect(() => File(path), throwsStateError);
          expect(() => Directory(path), throwsStateError);
        }
        expect(io.originalDirectory, isNull);
        expect(() => Link(BackupLoopNative.approvedRoot), throwsStateError);
        expect(
          () => io.socketConnect('synthetic.invalid', 1),
          throwsStateError,
        );
        expect(
          () => io.socketStartConnect('synthetic.invalid', 1),
          throwsStateError,
        );
      }, io);
    },
  );

  test('backup bootstrap Windows boundaries reject traversal spellings', () {
    final approved = BackupLoopNative.approvedRoot;
    expect(
      BackupLoopIo.canonicalPath(approved.replaceAll(r'\', '/').toUpperCase()),
      BackupLoopIo.canonicalPath(approved),
    );
    for (final path in [
      '$approved\\..\\opencode\\model-backup-loop-child',
      '$approved\\.\\model-backup-loop-child',
      '$approved/model-backup-loop-child/../other',
      r'C:relative',
      r'\Users\synthetic',
      '$approved\\model-backup-loop-child.',
      '$approved\\model-backup-loop-child ',
      '$approved\\model-backup-loop-child:stream',
    ]) {
      expect(BackupLoopIo.canonicalPath(path), isNull);
    }
  });

  test(
    'backup bootstrap captures one real atomic root before factory return',
    () async {
      final io = BackupLoopIo();
      final failure = BackupLoopFailure();
      Directory? captured;
      var captures = 0;
      await IOOverrides.runWithIOOverrides(() async {
        await failure.run(() async {
          final returned = await io.createOwnedRoot((owned) {
            captured = owned;
            captures++;
            expect(
              io.originalDirectory,
              BackupLoopIo.canonicalPath(owned.path),
            );
            expect(
              BackupLoopIo.canonicalPath(p.windows.dirname(owned.path)),
              BackupLoopIo.canonicalPath(BackupLoopNative.approvedRoot),
            );
            expect(
              p.windows.basename(owned.path),
              startsWith('model-backup-loop-'),
            );
            expect(
              p.windows.basename(owned.path).length,
              greaterThan('model-backup-loop-'.length),
            );
            // These only construct denied objects. No sibling is created or read.
            for (final sibling in [
              '${owned.path}-sibling',
              '${BackupLoopNative.approvedRoot}\\model-backup-loop-second',
              '${BackupLoopNative.approvedRoot}\\model-backup-loop-',
              '${owned.path}\\..\\${p.windows.basename(owned.path)}',
              '${owned.path}\\.\\child',
            ]) {
              expect(() => Directory(sibling), throwsStateError);
              expect(() => File(sibling), throwsStateError);
            }
            expect(
              () => Directory(BackupLoopNative.approvedRoot),
              throwsStateError,
            );
            expect(() => Link('${owned.path}\\link'), throwsStateError);
            expect(
              () => io.socketConnect('synthetic.invalid', 1),
              throwsStateError,
            );
            expect(
              () => io.socketStartConnect('synthetic.invalid', 1),
              throwsStateError,
            );
            // Capture confers test I/O scope, not SQLite/provider/source authority.
            expect(
              File('${owned.path}\\synthetic.db').path,
              endsWith('synthetic.db'),
            );
            expect(Directory('${owned.path}\\child').path, endsWith('child'));
            expect(
              Directory(owned.path.replaceAll(r'\', '/').toUpperCase()).path,
              isNotEmpty,
            );
          });
          expect(identical(returned, captured), isTrue);
          expect(captures, 1);
          expect(await returned.exists(), isTrue);
          await expectLater(
            io.createOwnedRoot((_) => fail('Second capture')),
            throwsStateError,
          );
        });
        // Delete only the exact owned creation, even if a post-capture check failed.
        if (captured != null) {
          await failure.run(() async {
            await captured!.delete();
          });
        }
      }, io);
      failure.throwIfAny();
    },
    skip: !Platform.isWindows,
  );
}
