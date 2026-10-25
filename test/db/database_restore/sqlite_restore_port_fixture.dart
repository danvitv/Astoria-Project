import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_storage.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3/unstable/ffi_bindings.dart' as nsql;

import 'sqlite_native_abi_probe.dart';

part 'sqlite_restore_port_cases.dart';
part 'sqlite_restore_port_image.dart';
part 'sqlite_restore_port_native.dart';

enum RestorePortCase { complete, contention, incomplete, bootstrap }

/// Preserve the original failure privately with its original stack, but never
/// expose a native path, SQLite error body or synthetic payload in diagnostics.
final class _RestoreFailure implements Exception {
  _RestoreFailure(this.cause, {required this.cleanup});
  final Object cause;
  final bool cleanup;
  @override
  String toString() => cleanup
      ? 'Synthetic SQLite restore port cleanup failed'
      : 'Synthetic SQLite restore port operation failed';
}

void restorePortTest(String name, String mode, RestorePortCase kind) {
  test(name, () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final previous = messenger.allMessagesHandler;
    var platformAttempts = 0;
    messenger.allMessagesHandler = (channel, handler, message) {
      platformAttempts++;
      throw StateError('Platform access outside synthetic restore fixture');
    };
    try {
      await HttpOverrides.runZoned(
        () async {
          final fixture = _RestoreFixture(
            approvedTempRoot: Directory(
              r'C:\Users\Даниил\AppData\Local\Temp\opencode',
            ),
            mode: mode,
          );
          Object? first;
          StackTrace? firstStack;
          try {
            await fixture.create();
            switch (kind) {
              case RestorePortCase.complete:
                await fixture.complete();
              case RestorePortCase.contention:
                await fixture.contention();
              case RestorePortCase.incomplete:
                await fixture.incomplete();
              case RestorePortCase.bootstrap:
                await fixture.bootstrap();
            }
          } catch (error, stack) {
            // Keep the original stack but never echo SQLite paths/row payloads.
            first = error is TestFailure || error is SqliteNativeAbiFailure
                ? error
                : _RestoreFailure(error, cleanup: false);
            firstStack = stack;
          } finally {
            try {
              await fixture.close();
            } catch (error, stack) {
              first ??= _RestoreFailure(error, cleanup: true);
              firstStack ??= stack;
            }
          }
          if (first != null) Error.throwWithStackTrace(first, firstStack!);
        },
        createHttpClient: (_) =>
            throw StateError('Network outside synthetic restore fixture'),
      );
      await messenger.platformMessagesFinished;
      expect(platformAttempts, 0, reason: 'No prefs/vault/platform calls');
    } finally {
      messenger.allMessagesHandler = previous;
    }
  });
}

final class _RestoreFixture {
  _RestoreFixture({required this.approvedTempRoot, required this.mode});
  final Directory approvedTempRoot;
  final String mode;
  Directory? _directory;
  SqliteRestoreTestAbi? _abi;
  final _rawOwners = <_RawOwner>[];
  final _wrappers = <_WrapperOwner>[];
  final _pins = <_PinOwner>[];
  final _paths = <String>{};
  final storage = _SyntheticKeyStorage();
  late final SupportPayloadCipher cipher;
  late final String targetPath;
  late final String candidatePath;
  late final Set<String> registered;
  late final _LogicalImage originalSeedImage;
  _RawOwner? target;
  _PinOwner? targetPin;
  _RawOwner? candidate;
  final contenders = <_RawOwner>[];
  _NativeBackup? _liveBackup;
  static const canary = 'SYNTHETIC_RESTORE_PRIVATE_CANARY';
  static const supportId = 'synthetic-support';
  static const characterId = 'synthetic-character';

  SqliteRestoreTestAbi get abi => _abi!;
  String path(String basename) {
    final result = '${_directory!.path}\\$basename';
    _paths.add(result);
    return result;
  }

  Future<void> create() async {
    expect(
      approvedTempRoot.path == r'C:\Users\Даниил\AppData\Local\Temp\opencode',
      true,
    );
    _abi = SqliteRestoreTestAbi();
    _directory = approvedTempRoot.createTempSync('sqlite-restore-port-');
    cipher = SupportPayloadCipher(
      vault: CredentialVault(
        storage: storage,
        buildChannel: 'synthetic_restore',
      ),
    );
    targetPath = path('target.db');
    candidatePath = path('candidate.db');
    registered = await seed(targetPath, mode, 'original');
    final candidateTables = await seed(candidatePath, 'DELETE', 'candidate');
    expect(registered.length, 61, reason: 'Actual compiled registration');
    expect(registered.difference(candidateTables).isEmpty, true);
    candidate = open(candidatePath, OpenMode.readOnly);
    _LogicalImage.capture(candidate!.db).requireRegistration(registered);
    final candidatePin = pin(candidatePath);
    abi.verifyConnection(candidate!.db, candidatePin.handle);
  }

  Future<Set<String>> seed(
    String filename,
    String journal,
    String label,
  ) async {
    final owner = open(filename, OpenMode.readWriteCreate);
    final db = owner.db;
    db.execute('PRAGMA journal_mode = $journal');
    db.execute('PRAGMA synchronous = FULL');
    if (journal == 'WAL') {
      abi.preserveWalOnOwnedConnection(db);
      db.execute('PRAGMA wal_autocheckpoint = 0');
    }
    final wrapper = wrap(owner);
    // Real opening creates the compiled schema, never default/background DB.
    await ChatRepo(wrapper.db).countByCharacterId(characterId);
    expect(wrapper.db.schemaVersion, 137);
    final tables = wrapper.db.allTables.map((t) => t.actualTableName).toSet();
    final support = SupportRepo(wrapper.db, cipher);
    await support.createSession(
      SupportSession(
        id: supportId,
        title: '$canary-$label',
        createdAt: 1,
        updatedAt: 2,
      ),
    );
    await support.appendMessage(
      SupportMessage(
        id: 'synthetic-message',
        sessionId: supportId,
        role: 'user',
        body: '$canary-body-$label',
        cardsJson: '[]',
        createdAt: 3,
      ),
    );
    await support.putContextBlock(
      SupportContextBlock(
        id: 'synthetic-context',
        sessionId: supportId,
        startMessageId: 'synthetic-message',
        endMessageId: 'synthetic-message',
        summary: '$canary-context-$label',
        protectedFactsJson: '[]',
        createdAt: 4,
      ),
    );
    await ChatRepo(wrapper.db).put(
      ChatSession(
        id: 'synthetic-chat',
        characterId: characterId,
        sessionIndex: 0,
        messages: [],
      ),
    );
    await wrapper.close();
    idle(owner);
    db.execute('PRAGMA application_id = 1095976018');
    db.execute(
      'CREATE TABLE extra_restore_entity ('
      'id INTEGER PRIMARY KEY, integer_value INTEGER, real_value REAL, '
      'text_value TEXT, blob_value BLOB, nullable_value TEXT)',
    );
    db.execute(
      'CREATE INDEX extra_restore_index '
      'ON extra_restore_entity(text_value)',
    );
    db.execute(
      'CREATE VIEW extra_restore_view AS '
      'SELECT id,blob_value FROM extra_restore_entity',
    );
    db.execute(
      'CREATE TRIGGER extra_restore_trigger AFTER INSERT '
      'ON extra_restore_entity BEGIN SELECT 1; END',
    );
    db.execute('BEGIN IMMEDIATE');
    // Enough genuine pages for a one-page copy to remain incomplete.
    for (var i = 1; i <= 12; i++) {
      db.execute('INSERT INTO extra_restore_entity VALUES (?,?,?,?,?,?)', [
        i,
        i.isEven ? 9223372036854775806 : -9223372036854775807,
        i + 0.125,
        '$canary-$label-$i\u0000',
        Uint8List.fromList(List<int>.generate(8192, (n) => (n + i) & 255)),
        null,
      ]);
    }
    db.execute('COMMIT');
    final image = _LogicalImage.capture(db);
    image.requireRegistration(tables);
    expect(image.pageCount <= 2048, true, reason: 'Bounded synthetic file');
    // Reuse this already captured original image. No bootstrap reopen/read is
    // added before invalidation, so the persisted WAL scenario stays intact.
    if (label == 'original') originalSeedImage = image;
    await owner.close();
    return tables;
  }

  _RawOwner open(String filename, OpenMode mode) {
    // Explicit private cache even if another caller changed global defaults.
    final uri = '${Uri.file(filename, windows: true)}?cache=private';
    final owner = _RawOwner(sqlite3.open(uri, uri: true, mode: mode));
    _rawOwners.add(owner);
    owner.db.execute('PRAGMA busy_timeout = 0');
    return owner;
  }

  _WrapperOwner wrap(_RawOwner owner) {
    final wrapper = _WrapperOwner(
      AppDatabase.openedNative(owner.db, closeUnderlyingOnClose: false),
    );
    _wrappers.add(wrapper);
    return wrapper;
  }

  _PinOwner pin(String filename) {
    final result = _PinOwner(abi, abi.openNamePin(filename));
    _pins.add(result);
    return result;
  }

  Future<void> close() async {
    Object? first;
    StackTrace? firstStack;
    Future<void> attempt(FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (error, stack) {
        first ??= error;
        firstStack ??= stack;
      }
    }

    await attempt(() {
      _liveBackup?.finish();
    });
    for (final wrapper in _wrappers.reversed) {
      await attempt(wrapper.close);
    }
    final wrappersClosed = _wrappers.every((w) => w.closed);
    if (wrappersClosed && (_liveBackup == null || _liveBackup!.finished)) {
      for (final owner in _rawOwners.reversed) {
        await attempt(owner.close);
      }
    }
    final rawsClosed = _rawOwners.every((r) => r.closed);
    if (wrappersClosed && rawsClosed) {
      for (final ownedPin in _pins.reversed) {
        await attempt(ownedPin.close);
      }
    }
    final pinsClosed = _pins.every((p) => p.closed);
    if (wrappersClosed && rawsClosed && pinsClosed) {
      await attempt(() => _abi?.close());
      // Exact owned paths only; no inventory/recursive old-temp deletion.
      for (final filename in _paths) {
        for (final suffix in ['', '-wal', '-shm', '-journal']) {
          await attempt(() {
            final file = File('$filename$suffix');
            if (file.existsSync()) file.deleteSync();
          });
        }
      }
      if (first == null) await attempt(() => _directory?.deleteSync());
    }
    storage.clear();
    if (first != null) Error.throwWithStackTrace(first!, firstStack!);
  }
}

/// A memory-only key backend, never the installation vault or platform plugin.
final class _SyntheticKeyStorage implements CredentialStorage {
  final _values = <String, String>{};
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  void clear() => _values.clear();
}
