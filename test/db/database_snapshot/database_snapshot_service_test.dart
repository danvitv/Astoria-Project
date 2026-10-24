import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/services/database_snapshot_service.dart';
import 'package:sqlite3/sqlite3.dart';

import 'snapshot_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  snapshotTest(
    'online snapshot includes committed WAL and every registered/extra entity',
    (f) async {
      final originalMain = await File(f.sourcePath).readAsBytes();
      final originalWal = await File('${f.sourcePath}-wal').readAsBytes();
      expect(originalWal, isNotEmpty);
      // Regression: a fresh native API sees existing WAL/SHM, then the first
      // missing optional sidecar. Lazy error-binding initialization must not
      // turn that absent journal into an unsupported identity failure.
      expect(await File('${f.sourcePath}-shm').exists(), isTrue);
      expect(await File('${f.sourcePath}-journal').exists(), isFalse);
      final schema = f.schema(f.writer!);
      final service = f.build();
      final result = await service.create(
        control: DatabaseSnapshotControl(isCurrent: () => true),
      );
      f.expectStatus(result, DatabaseSnapshotStatus.verified);
      expect(result.handle, isNotNull);
      expect(result.tableCount, greaterThanOrEqualTo(f.registered.length + 1));
      expect(result.externalKeyVaultIncluded, isFalse);
      expect(result.keyRecoverabilityKnown, isFalse);
      expect(result.missingKeysCannotBeRecovered, isTrue);
      expect(result.toString(), isNot(contains(SnapshotFixture.canary)));
      expect(result.toString(), isNot(contains(f.sourcePath)));
      expect(result.handle.toString(), 'VerifiedDatabaseSnapshot');
      expect(
        service.runtimeRestoreStatus,
        DatabaseSnapshotStatus.unsupportedRestore,
      );
      final copy = sqlite3.open(f.destinationPath, mode: OpenMode.readOnly);
      try {
        expect(f.schema(copy), schema);
        expect(copy.userVersion, f.writer!.userVersion);
        for (final table in f.registered) {
          final name = '"${table.replaceAll('"', '""')}"';
          expect(
            copy.select('SELECT count(*) FROM $name').first.values,
            f.writer!.select('SELECT count(*) FROM $name').first.values,
          );
        }
        expect(
          copy
              .select('SELECT summary_ciphertext FROM support_context_blocks')
              .single
              .values
              .single,
          SnapshotFixture.canary,
        );
        expect(
          copy
              .select('SELECT before_ciphertext FROM support_mutation_journal')
              .single
              .values
              .single,
          'before-${SnapshotFixture.canary}',
        );
        expect(
          copy
              .select('SELECT secret FROM extra_snapshot_entity')
              .single
              .values
              .single,
          SnapshotFixture.canary.codeUnits,
        );
        expect(
          copy.select('PRAGMA integrity_check').map((r) => r.values.single),
          ['ok'],
        );
      } finally {
        copy.close();
      }
      expect(await File(f.sourcePath).readAsBytes(), originalMain);
      expect(await File('${f.sourcePath}-wal').readAsBytes(), originalWal);
      expect(await f.partials(), isEmpty);
      final originalSnapshot = await File(f.destinationPath).readAsBytes();
      final verification = service.verifyHandle(
        result.handle!,
        control: DatabaseSnapshotControl(isCurrent: () => true),
      );
      // A second caller cannot reposition/read the held pin during its yield.
      final nested = await service.verifyHandle(
        result.handle!,
        control: DatabaseSnapshotControl(isCurrent: () => true),
      );
      expect(nested.status, DatabaseSnapshotStatus.unavailable);
      final verified = await verification;
      expect(verified.status, DatabaseSnapshotStatus.verified);
      // Repeat on the retained pin: its native file pointer must reset to zero.
      final repeated = await service.verifyHandle(
        result.handle!,
        control: DatabaseSnapshotControl(isCurrent: () => true),
      );
      expect(repeated.status, DatabaseSnapshotStatus.verified);
      final cancelled = DatabaseSnapshotControl(isCurrent: () => true)
        ..cancel();
      expect(
        (await service.verifyHandle(result.handle!, control: cancelled)).status,
        DatabaseSnapshotStatus.cancelled,
      );
      expect(
        (await service.verifyHandle(
          result.handle!,
          control: DatabaseSnapshotControl(isCurrent: () => false),
        )).status,
        DatabaseSnapshotStatus.stale,
      );
      expect(await File(f.destinationPath).readAsBytes(), originalSnapshot);
      expect(await File(f.sourcePath).readAsBytes(), originalMain);
      expect(await File('${f.sourcePath}-wal').readAsBytes(), originalWal);
      final disposedWhileHashing = service.verifyHandle(
        result.handle!,
        control: DatabaseSnapshotControl(isCurrent: () => true),
      );
      service.dispose();
      expect((await disposedWhileHashing).status, DatabaseSnapshotStatus.stale);
      expect(
        (await service.verifyHandle(
          result.handle!,
          control: DatabaseSnapshotControl(isCurrent: () => true),
        )).status,
        DatabaseSnapshotStatus.unavailable,
      );
      expect(await File(f.destinationPath).readAsBytes(), originalSnapshot);
    },
  );

  snapshotTest('existing destination preserved and source alias refused', (
    f,
  ) async {
    final bytes = [1, 3, 7, 11];
    await File(f.destinationPath).writeAsBytes(bytes);
    var result = await f.build().create(
      control: DatabaseSnapshotControl(isCurrent: () => true),
    );
    expect(result.status, DatabaseSnapshotStatus.destinationExists);
    expect(await File(f.destinationPath).readAsBytes(), bytes);
    f.service!.dispose();
    result = await f
        .build(destination: f.sourcePath)
        .create(control: DatabaseSnapshotControl(isCurrent: () => true));
    expect(result.status, DatabaseSnapshotStatus.unsupportedIdentity);
    expect(await f.partials(), isEmpty);
  });

  snapshotTest(
    'cancellation at a native backup step removes only owned staging',
    (f) async {
      expect(f.native, isNull);
      expect(await File('${f.sourcePath}-wal').exists(), isTrue);
      expect(await File('${f.sourcePath}-shm').exists(), isTrue);
      expect(await File('${f.sourcePath}-journal').exists(), isFalse);
      f.writer!.execute(
        'INSERT INTO extra_snapshot_entity VALUES (2,zeroblob(2097152))',
      );
      var backupPages = 0;
      late DatabaseSnapshotControl control;
      control = DatabaseSnapshotControl(
        isCurrent: () => true,
        onBoundary: (boundary) async {
          if (boundary == DatabaseSnapshotBoundary.backupPage) {
            backupPages++;
            control.cancel();
          }
        },
      );
      final source = f.schema(f.writer!);
      final result = await f.build().create(control: control);
      f.expectStatus(result, DatabaseSnapshotStatus.cancelled);
      expect(backupPages, 1);
      expect(f.native!.identityFailure, isNull);
      expect(result.handle, isNull);
      expect(await File(f.destinationPath).exists(), isFalse);
      expect(await f.partials(), isEmpty);
      expect(f.schema(f.writer!), source);
    },
  );

  snapshotTest(
    'concurrent WAL commit does not invalidate the consistent snapshot counts',
    (f) async {
      var committed = false;
      final result = await f.build().create(
        control: DatabaseSnapshotControl(
          isCurrent: () => true,
          onBoundary: (boundary) async {
            if (boundary == DatabaseSnapshotBoundary.backupPage && !committed) {
              committed = true;
              f.writer!.execute(
                'INSERT INTO extra_snapshot_entity VALUES (?,?)',
                [2, SnapshotFixture.canary.codeUnits],
              );
            }
          },
        ),
      );
      expect(result.status, DatabaseSnapshotStatus.verified);
      final copy = sqlite3.open(f.destinationPath, mode: OpenMode.readOnly);
      try {
        expect(
          copy
              .select('SELECT count(*) FROM extra_snapshot_entity')
              .single
              .values
              .single,
          1,
        );
        expect(
          f.writer!
              .select('SELECT count(*) FROM extra_snapshot_entity')
              .single
              .values
              .single,
          2,
        );
      } finally {
        copy.close();
      }
    },
  );

  snapshotTest(
    'unproved network destination is refused before any network access',
    (f) async {
      final result = await f
          .build(destination: r'\\synthetic-server\share\snapshot.db')
          .create(control: DatabaseSnapshotControl(isCurrent: () => true));
      expect(result.status, DatabaseSnapshotStatus.unsupportedIdentity);
      expect(await f.partials(), isEmpty);
    },
  );

  snapshotTest('source pin refuses replacement while snapshot is in flight', (
    f,
  ) async {
    var replacementRefused = false;
    final result = await f.build().create(
      control: DatabaseSnapshotControl(
        isCurrent: () => true,
        onBoundary: (boundary) async {
          if (boundary == DatabaseSnapshotBoundary.beforePublish) {
            try {
              await File(f.sourcePath).rename('${f.sourcePath}.replaced');
            } on FileSystemException {
              replacementRefused = true;
            }
          }
        },
      ),
    );
    expect(replacementRefused, isTrue);
    expect(result.status, DatabaseSnapshotStatus.verified);
    expect(await File('${f.sourcePath}.replaced').exists(), isFalse);
  });

  snapshotTest(
    'cancelled or stale before starting never creates a destination',
    (f) async {
      final control = DatabaseSnapshotControl(isCurrent: () => true)..cancel();
      final service = f.build();
      expect(
        (await service.create(control: control)).status,
        DatabaseSnapshotStatus.cancelled,
      );
      f.sourceCurrent = false;
      expect(
        (await service.create(
          control: DatabaseSnapshotControl(isCurrent: () => true),
        )).status,
        DatabaseSnapshotStatus.stale,
      );
      expect(await File(f.destinationPath).exists(), isFalse);
      expect(await f.partials(), isEmpty);
    },
  );

  snapshotTest(
    'native source epoch invalidation before rename prevents publication',
    (f) async {
      final service = f.build();
      final result = await service.create(
        control: DatabaseSnapshotControl(
          isCurrent: () => true,
          onBoundary: (boundary) async {
            if (boundary == DatabaseSnapshotBoundary.beforePublish)
              f.sourceCurrent = false;
          },
        ),
      );
      expect(result.status, DatabaseSnapshotStatus.stale);
      expect(result.handle, isNull);
      expect(await File(f.destinationPath).exists(), isFalse);
      expect(await f.partials(), isEmpty);
    },
  );

  snapshotTest(
    'reentrant hook is unavailable and cannot publish a second snapshot',
    (f) async {
      final service = f.build();
      DatabaseSnapshotResult? nested;
      final result = await service.create(
        control: DatabaseSnapshotControl(
          isCurrent: () => true,
          onBoundary: (boundary) async {
            if (boundary == DatabaseSnapshotBoundary.beforePublish) {
              nested = await service.create(
                control: DatabaseSnapshotControl(isCurrent: () => true),
              );
            }
          },
        ),
      );
      expect(nested!.status, DatabaseSnapshotStatus.unavailable);
      expect(result.status, DatabaseSnapshotStatus.verified);
      expect(await f.partials(), isEmpty);
    },
  );

  snapshotTest(
    'destination appearing at final hook is preserved without overwrite',
    (f) async {
      final bytes = [4, 2, 6];
      final result = await f.build().create(
        control: DatabaseSnapshotControl(
          isCurrent: () => true,
          onBoundary: (boundary) async {
            if (boundary == DatabaseSnapshotBoundary.beforePublish) {
              await File(f.destinationPath).writeAsBytes(bytes);
            }
          },
        ),
      );
      expect(result.status, DatabaseSnapshotStatus.destinationExists);
      expect(await File(f.destinationPath).readAsBytes(), bytes);
      expect(await f.partials(), isEmpty);
    },
  );

  snapshotTest(
    'validation refuses missing registered coverage with fixed failure',
    (f) async {
      final result = await f
          .build(tables: {...f.registered, 'not_registered'})
          .create(control: DatabaseSnapshotControl(isCurrent: () => true));
      expect(result.status, DatabaseSnapshotStatus.invalid);
      expect(result.toString(), isNot(contains('not_registered')));
      expect(await File(f.destinationPath).exists(), isFalse);
      expect(await f.partials(), isEmpty);
    },
  );

  snapshotTest('malformed SQLite is not promoted to healthy by copying', (
    f,
  ) async {
    expect(f.native, isNull);
    expect(await File('${f.sourcePath}-wal').exists(), isFalse);
    expect(await File('${f.sourcePath}-shm').exists(), isFalse);
    expect(await File('${f.sourcePath}-journal').exists(), isFalse);
    final original = await File(f.sourcePath).readAsBytes();
    expect(original.length, 4096);
    expect(original.every((byte) => byte == 0x41), isTrue);
    var backupReached = false;
    var publicationReached = false;
    final result = await f.build().create(
      control: DatabaseSnapshotControl(
        isCurrent: () => true,
        onBoundary: (boundary) async {
          if (boundary == DatabaseSnapshotBoundary.backupPage) {
            backupReached = true;
          }
          if (boundary == DatabaseSnapshotBoundary.beforePublish) {
            publicationReached = true;
          }
        },
      ),
    );
    f.expectStatus(result, DatabaseSnapshotStatus.invalid);
    expect(f.native!.identityFailure, isNull);
    expect(backupReached, isFalse);
    expect(publicationReached, isFalse);
    expect(result.handle, isNull);
    expect(result.toString(), 'DatabaseSnapshotResult(invalid)');
    expect(await File(f.sourcePath).readAsBytes(), original);
    expect(await File(f.destinationPath).exists(), isFalse);
    expect(await f.partials(), isEmpty);
  }, malformed: true);

  snapshotTest(
    'first native absence capture keeps existing SHM and absent journal distinct',
    (f) async {
      expect(f.native, isNull);
      expect(await File('${f.sourcePath}-wal').exists(), isTrue);
      expect(await File('${f.sourcePath}-shm').exists(), isTrue);
      expect(await File('${f.sourcePath}-journal').exists(), isFalse);
      var boundaryReached = false;
      // An empty registration stops inspection before staging/backup/hash. The
      // ORIGINAL fresh owner must first acquire existing WAL/SHM and accept the
      // missing journal through its first native error capture. No FFI priming
      // or injected identity/health/cancellation result exists in this fixture.
      final result = await f
          .build(tables: const <String>{})
          .create(
            control: DatabaseSnapshotControl(
              isCurrent: () => true,
              onBoundary: (_) async {
                boundaryReached = true;
              },
            ),
          );
      f.expectStatus(result, DatabaseSnapshotStatus.tooLarge);
      expect(f.native!.identityFailure, isNull);
      expect(boundaryReached, isFalse);
      expect(result.handle, isNull);
      expect(await File(f.destinationPath).exists(), isFalse);
      expect(await f.partials(), isEmpty);
    },
  );

  snapshotTest(
    'first native absence capture reaches malformed source without WAL or SHM',
    (f) async {
      expect(f.native, isNull);
      expect(await File('${f.sourcePath}-wal').exists(), isFalse);
      expect(await File('${f.sourcePath}-shm').exists(), isFalse);
      expect(await File('${f.sourcePath}-journal').exists(), isFalse);
      final original = await File(f.sourcePath).readAsBytes();
      var boundaryReached = false;
      // The first native attributes failure is now WAL, with no earlier
      // successful sidecar calls. Only the production error consumer is primed.
      final result = await f.build().create(
        control: DatabaseSnapshotControl(
          isCurrent: () => true,
          onBoundary: (_) async {
            boundaryReached = true;
          },
        ),
      );
      f.expectStatus(result, DatabaseSnapshotStatus.invalid);
      expect(f.native!.identityFailure, isNull);
      expect(boundaryReached, isFalse);
      expect(result.handle, isNull);
      expect(result.toString(), 'DatabaseSnapshotResult(invalid)');
      expect(await File(f.sourcePath).readAsBytes(), original);
      expect(await File(f.destinationPath).exists(), isFalse);
      expect(await f.partials(), isEmpty);
    },
    malformed: true,
  );

  snapshotTest(
    'finite registration bound reports tooLarge rather than verified',
    (f) async {
      final tables = {
        ...f.registered,
        ...List.generate(513, (i) => 'synthetic_registration_$i'),
      };
      final result = await f
          .build(tables: tables)
          .create(control: DatabaseSnapshotControl(isCurrent: () => true));
      expect(result.status, DatabaseSnapshotStatus.tooLarge);
      expect(result.handle, isNull);
      expect(await File(f.destinationPath).exists(), isFalse);
      expect(await f.partials(), isEmpty);
    },
  );
}
