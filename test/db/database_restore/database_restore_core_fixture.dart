import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_storage.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/database_restore_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:sqlite3/sqlite3.dart';

// Reuse only the already-proved fixture WAL retention control, not its port
// tests, image, lease implementation, acceptance callback or rollback fixture.
import 'sqlite_native_abi_probe.dart';

final class RestoreCoreFixture {
  RestoreCoreFixture(this.mode);
  final String mode;
  late final Directory directory;
  late final File target;
  late final File candidate;
  final _storage = _RestoreMemoryKeys();
  late final SupportPayloadCipher cipher;
  final owners = <NativeDatabaseRestoreOwner>[];
  final _raws = <Database>[];
  final _closed = <Database>{};
  late final String originalWitness;
  late final String candidateWitness;
  static const supportId = 'core-synthetic-support';
  static const characterId = 'core-synthetic-character';
  static const canary = 'CORE_SYNTHETIC_PRIVATE_PAYLOAD';

  Future<void> create() async {
    final approved = Directory(r'C:\Users\Даниил\AppData\Local\Temp\opencode');
    directory = approved.createTempSync('database-restore-core-');
    target = File('${directory.path}\\target.db');
    candidate = File('${directory.path}\\candidate.db');
    cipher = SupportPayloadCipher(
      vault: CredentialVault(
        storage: _storage,
        buildChannel: 'restore_core_memory',
      ),
    );
    originalWitness = await _seed(target, mode, 'original');
    candidateWitness = await _seed(candidate, 'DELETE', 'candidate');
  }

  Database open(File file, {OpenMode mode = OpenMode.readWrite}) {
    final db = sqlite3.open(
      '${Uri.file(file.path, windows: true)}?cache=private',
      uri: true,
      mode: mode,
    );
    _raws.add(db);
    db.execute('PRAGMA busy_timeout = 0');
    return db;
  }

  void closeRaw(Database db) {
    if (_closed.contains(db)) return;
    db.close();
    _closed.add(db);
  }

  NativeDatabaseRestoreOwner owner({
    void Function(DatabaseRestoreTestBoundary)? fault,
  }) {
    final value = NativeDatabaseRestoreOwner.acquire(
      target: target,
      candidate: candidate,
      payloadCipher: cipher,
      testFault: fault,
    );
    owners.add(value);
    return value;
  }

  Future<String> _seed(File file, String journal, String label) async {
    final db = open(file, mode: OpenMode.readWriteCreate);
    final abi = journal == 'WAL' ? SqliteRestoreTestAbi() : null;
    AppDatabase? app;
    try {
      db.execute('PRAGMA journal_mode = $journal');
      db.execute('PRAGMA synchronous = FULL');
      if (abi != null) {
        abi.preserveWalOnOwnedConnection(db);
        db.execute('PRAGMA wal_autocheckpoint = 0');
      }
      app = AppDatabase.openedNative(db, closeUnderlyingOnClose: false);
      await ChatRepo(app).countByCharacterId(characterId);
      expect(app.schemaVersion, 137);
      expect(app.allTables.length, 61);
      expect(db.select('PRAGMA application_id').single.values.single, 0);
      final support = SupportRepo(app, cipher);
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
          id: 'core-message',
          sessionId: supportId,
          role: 'user',
          body: '$canary-body-$label',
          cardsJson: '[]',
          createdAt: 3,
        ),
      );
      await support.putContextBlock(
        SupportContextBlock(
          id: 'core-context',
          sessionId: supportId,
          startMessageId: 'core-message',
          endMessageId: 'core-message',
          summary: '$canary-summary-$label',
          protectedFactsJson: '[]',
          createdAt: 4,
        ),
      );
      await ChatRepo(app).put(
        ChatSession(
          id: 'core-chat',
          characterId: characterId,
          sessionIndex: 0,
          messages: [],
        ),
      );
      await app.close();
      app = null;
      db.execute(
        'CREATE TABLE core_extra (id INTEGER, i INTEGER, r REAL, t TEXT, b BLOB, n TEXT)',
      );
      db.execute('CREATE INDEX core_extra_index ON core_extra(t)');
      db.execute('CREATE VIEW core_extra_view AS SELECT id,b FROM core_extra');
      db.execute(
        'CREATE TRIGGER core_extra_trigger AFTER INSERT ON core_extra BEGIN SELECT 1; END',
      );
      db.execute('BEGIN IMMEDIATE');
      for (var i = 0; i < 8; i++) {
        // Duplicates, int64, double bits, NUL, blobs, NULL, no primary key.
        db.execute('INSERT INTO core_extra VALUES(?,?,?,?,?,?)', [
          i ~/ 2,
          i.isEven ? -9223372036854775807 : 9223372036854775806,
          i + 0.125,
          '$canary-$label\u0000',
          Uint8List.fromList(List.generate(8192, (n) => (n + i) & 255)),
          null,
        ]);
      }
      db.execute('INSERT INTO core_extra SELECT * FROM core_extra WHERE id=0');
      db.execute('COMMIT');
      return witness(db);
    } finally {
      if (app != null) await app.close();
      closeRaw(db);
      abi?.close();
    }
  }

  /// Small independent assertion witness, NEVER a restore implementation. The
  /// only effect engine under test is the new production owning repo.
  String witness(Database db) {
    final schema = db.select(
      'SELECT type,name,tbl_name,rootpage,sql FROM sqlite_schema ORDER BY type,name',
    );
    expect(schema.length <= 512, true);
    final tables = db.select(
      "SELECT name FROM pragma_table_list WHERE schema='main' AND type='table' ORDER BY name",
    );
    expect(tables.length <= 128, true);
    final image = <Object?>[
      db.select('PRAGMA application_id').single.values.single,
      db.select('PRAGMA user_version').single.values.single,
      db.select('PRAGMA page_size').single.values.single,
      db.select('PRAGMA page_count').single.values.single,
      schema.map((r) => typed(r.values)).toList(),
    ];
    var count = 0;
    for (final row in tables) {
      final name = row['name'] as String;
      final quoted = '"${name.replaceAll('"', '""')}"';
      final rows = db.select('SELECT * FROM $quoted');
      count += rows.length;
      expect(count <= 512, true);
      final contents = rows.map((r) => typed(r.values)).toList()..sort();
      image.add([
        name,
        db
            .select('PRAGMA table_xinfo($quoted)')
            .map((r) => typed(r.values))
            .toList(),
        contents,
      ]);
    }
    return jsonEncode(image);
  }

  static String typed(Iterable<Object?> values) => jsonEncode(
    values.map((value) {
      if (value == null) return ['null'];
      if (value is int) return ['integer', value.toString()];
      if (value is double) {
        final bytes = ByteData(8)..setFloat64(0, value, Endian.big);
        return ['real', base64Encode(bytes.buffer.asUint8List())];
      }
      if (value is String) return ['text', base64Encode(utf8.encode(value))];
      if (value is Uint8List) return ['blob', base64Encode(value)];
      throw StateError('Unsupported synthetic value');
    }).toList(),
  );

  void expectOriginal() {
    final db = open(target, mode: OpenMode.readOnly);
    try {
      expect(
        witness(db) == originalWitness,
        true,
        reason: 'Complete original schema and typed rows restored',
      );
    } finally {
      closeRaw(db);
    }
  }

  List<Directory> archives() {
    final entries = directory.listSync();
    expect(entries.length <= 24, true);
    return entries
        .whereType<Directory>()
        .where((d) => d.path.split('\\').last.startsWith('.restore-'))
        .toList();
  }

  bool get interruptionExists =>
      File('${directory.path}\\.astoria-restore-interrupted').existsSync();

  void expectArchivedOriginal({String? expected}) {
    final stages = archives();
    expect(stages.length, 1);
    final raw = open(
      File('${stages.single.path}\\original.db'),
      mode: OpenMode.readOnly,
    );
    try {
      expect(
        witness(raw) == (expected ?? originalWitness),
        true,
        reason:
            'Independent FULL native original contains whole original image',
      );
    } finally {
      closeRaw(raw);
    }
  }

  static bool sameBytes(List<int> a, List<int> b) =>
      a.length == b.length &&
      Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);

  Future<void> close() async {
    Object? first;
    StackTrace? stack;
    for (final owner in owners.reversed) {
      try {
        await owner.close();
      } catch (error, trace) {
        first ??= error;
        stack ??= trace;
      }
    }
    for (final db in _raws.reversed) {
      try {
        closeRaw(db);
      } catch (error, trace) {
        first ??= error;
        stack ??= trace;
      }
    }
    _storage.clear();
    if (first != null) Error.throwWithStackTrace(first, stack!);
    // All resources are actually closed. Delete bounded exact files in THIS
    // unique approved fixture, never old inventory or broad recursive paths.
    final stages = archives();
    for (final stage in stages) {
      final files = stage.listSync();
      expect(files.length <= 16, true);
      for (final entry in files) {
        expect(entry is File, true);
        (entry as File).deleteSync();
      }
      stage.deleteSync();
    }
    for (final file in [target, candidate]) {
      for (final suffix in ['', '-wal', '-shm', '-journal']) {
        final exact = File('${file.path}$suffix');
        if (exact.existsSync()) exact.deleteSync();
      }
    }
    for (final name in [
      '.astoria-restore-startup.lock',
      '.astoria-restore-interrupted',
    ]) {
      final exact = File('${directory.path}\\$name');
      if (exact.existsSync()) exact.deleteSync();
    }
    directory.deleteSync();
  }
}

final class _RestoreMemoryKeys implements CredentialStorage {
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

final class _RestoreFixtureFailure implements Exception {
  _RestoreFixtureFailure(this._cause);
  // Private original cause never interpolated into public diagnostics.
  final Object _cause;
  @override
  String toString() => 'Synthetic restore core failure (${_cause.runtimeType})';
}

void restoreCoreTest(
  String name,
  String mode,
  Future<void> Function(RestoreCoreFixture) body,
) {
  test(name, () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final previous = messenger.allMessagesHandler;
    var platformCalls = 0;
    messenger.allMessagesHandler = (_, _, _) {
      platformCalls++;
      throw StateError(
        'Platform calls forbidden in synthetic restore core test',
      );
    };
    try {
      await HttpOverrides.runZoned(
        () async {
          final fixture = RestoreCoreFixture(mode);
          Object? first;
          StackTrace? stack;
          var created = false;
          try {
            await fixture.create();
            created = true;
            await body(fixture);
          } catch (error, trace) {
            first = error is TestFailure || error is DatabaseRestoreException
                ? error
                : _RestoreFixtureFailure(error);
            stack = trace;
          } finally {
            if (created) {
              try {
                await fixture.close();
              } catch (error, trace) {
                first ??= _RestoreFixtureFailure(error);
                stack ??= trace;
              }
            }
          }
          if (first != null) Error.throwWithStackTrace(first, stack!);
        },
        createHttpClient: (_) => throw StateError(
          'Network forbidden in synthetic restore core test',
        ),
      );
      await messenger.platformMessagesFinished;
      expect(platformCalls, 0);
    } finally {
      messenger.allMessagesHandler = previous;
    }
  });
}
