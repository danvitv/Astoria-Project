part of '../database_snapshot_service.dart';

/// A synchronous terminal installed on the actual Drift background connection.
/// The caller owns the exclusive/read-transaction fence and private stage pins.
/// No command publishes, deletes files, or changes/closes the live source.
abstract final class BackgroundDatabaseSnapshotWorker {
  static const functionName = 'astoria_native_snapshot';
  static final _installed = Expando<bool>();

  static void install(
    Database source, {
    required String sourcePath,
    required String privateStageRoot,
  }) {
    if (!Platform.isAndroid) return;
    _install(source, sourcePath, privateStageRoot);
  }

  /// Windows is deliberately available only through this synthetic-test entry.
  static void installForTestingWindows(
    Database source, {
    required String sourcePath,
    required String privateStageRoot,
  }) {
    if (!Platform.isWindows) throw UnsupportedError('Synthetic Windows worker');
    _install(source, sourcePath, privateStageRoot);
  }

  static void _install(Database source, String sourcePath, String stageRoot) {
    if (_installed[source] == true ||
        !p.isAbsolute(sourcePath) ||
        !p.isAbsolute(stageRoot) ||
        sourcePath.contains('\u0000') ||
        stageRoot.contains('\u0000')) {
      throw ArgumentError('Invalid snapshot worker registration');
    }
    final worker = _BackgroundSnapshotWorker(source, sourcePath, stageRoot);
    source.createFunction(
      functionName: functionName,
      argumentCount: const AllowedArgumentCount(3),
      deterministic: false,
      directOnly: true,
      function: worker.command,
    );
    _installed[source] = true;
  }
}

final class _BackgroundSnapshotWorker {
  _BackgroundSnapshotWorker(this.source, this.sourcePath, this.stageRoot);
  final Database source;
  final String sourcePath, stageRoot;
  _WorkerSnapshot? active;
  String? closedToken;
  static final _token = RegExp(r'^[0-9a-f]{64}$');
  static const _stepPages = 64;

  String command(List<Object?> args) {
    if (args.length != 3 ||
        args[0] is! String ||
        args[1] is! String ||
        args[2] is! String)
      return _reply('invalid', false);
    final command = args[0] as String;
    final token = args[1] as String;
    final metadata = args[2] as String;
    if (token.length != 64 ||
        !_token.hasMatch(token) ||
        (command != 'start' && metadata.isNotEmpty)) {
      return _reply('invalid', false);
    }
    // Invalid/stale requests must never retire another owner's original handles.
    if (command == 'abort') {
      if (active?.token == token) return _retire('closed');
      return _reply(
        closedToken == token ? 'closed' : 'unavailable',
        closedToken == token,
      );
    }
    if (command == 'check') {
      try {
        return _reply(
          active == null && source.autocommit && _sameSource()
              ? 'ready'
              : 'unavailable',
          active == null,
        );
      } catch (_) {
        return _reply('unavailable', false);
      }
    }
    if (command != 'start' && command != 'step' && command != 'finish') {
      return _reply('invalid', false);
    }
    if (command == 'start'
        ? active != null || closedToken == token
        : active?.token != token)
      return _reply('unavailable', false);
    try {
      if (source.autocommit || !_sameSource()) {
        throw const _SnapshotFailure(DatabaseSnapshotStatus.unavailable);
      }
      if (command == 'start') return _start(token, metadata);
      final context = active!;
      context.guard.check();
      if (command == 'step') {
        if (context.done) return _reply('ready', false);
        if (++context.steps > _SnapshotLimits.maxPages ~/ _stepPages + 2) {
          throw const _SnapshotFailure(DatabaseSnapshotStatus.tooLarge);
        }
        final rc = nsql.sqlite3_backup_step(context.backup, _stepPages);
        context.guard.check();
        if (nsql.sqlite3_backup_pagecount(context.backup) >
            _SnapshotLimits.maxPages) {
          throw const _SnapshotFailure(DatabaseSnapshotStatus.tooLarge);
        }
        if (rc != 0 && rc != 101) {
          throw _SnapshotFailure(
            rc == 5 || rc == 6
                ? DatabaseSnapshotStatus.unknown
                : DatabaseSnapshotStatus.invalid,
          );
        }
        context.done = rc == 101;
        return _reply(context.done ? 'ready' : 'progress', false);
      }
      if (!context.done || context.finishBackup() != 0) {
        throw const _SnapshotFailure(DatabaseSnapshotStatus.invalid);
      }
      // Finish exactly once before touching the destination's journal or verifier.
      final journal = context.copy!.select('PRAGMA journal_mode = DELETE');
      if (journal.length != 1 || journal.single.values.single != 'delete') {
        throw const _SnapshotFailure(DatabaseSnapshotStatus.invalid);
      }
      _SnapshotSqlite.verify(
        context.copy!,
        context.schema,
        context.tables,
        context.guard,
      );
      final count = context.schema.counts.length;
      return _retire('verified', tableCount: count);
    } on _SnapshotFailure catch (error) {
      final status = switch (error.status) {
        DatabaseSnapshotStatus.tooLarge => 'tooLarge',
        DatabaseSnapshotStatus.unavailable => 'unavailable',
        DatabaseSnapshotStatus.unknown => 'uncertain',
        _ => 'invalid',
      };
      return active?.token == token ? _retire(status) : _reply(status, false);
    } catch (_) {
      return active?.token == token
          ? _retire('invalid')
          : _reply('invalid', false);
    }
  }

  bool _sameSource() {
    final rows = source.select('PRAGMA database_list');
    final main = rows.where((row) => row['name'] == 'main').toList();
    return main.length == 1 &&
        main.single['file'] is String &&
        (Platform.isWindows
            ? p.windows.equals(main.single['file'] as String, sourcePath)
            : main.single['file'] == sourcePath) &&
        rows.every((row) => row['name'] == 'main' || row['name'] == 'temp');
  }

  String _start(String token, String metadata) {
    final tables = _registeredTables(metadata);
    final guard = _SnapshotGuard(
      DatabaseSnapshotControl(isCurrent: () => true),
      () => !source.autocommit,
    );
    final schema = _SnapshotSqlite.inspect(source, tables, guard);
    final stage = p.join(stageRoot, token, 'snapshot.db');
    // Native exclusive creation/custody is the root's responsibility. Opening
    // never creates a stage, and a previously written stage is never reused.
    if (p.equals(stage, sourcePath) ||
        FileSystemEntity.typeSync(stage, followLinks: false) !=
            FileSystemEntityType.file ||
        File(stage).lengthSync() != 0 ||
        ['-wal', '-shm', '-journal'].any(
          (suffix) =>
              FileSystemEntity.typeSync('$stage$suffix', followLinks: false) !=
              FileSystemEntityType.notFound,
        )) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.invalid);
    }
    final context = _WorkerSnapshot(token, schema, tables, guard);
    active =
        context; // Keep original handles even if partial initialization fails.
    context.memory = _WorkerSnapshotMemory();
    context.name = context.memory!.allocate();
    context.name.asTypedList(5).setAll(0, [109, 97, 105, 110, 0]);
    context.copy = sqlite3.open(stage, mode: OpenMode.readWrite);
    _SnapshotSqlite.configure(context.copy!, guard, readOnly: false);
    context.backup = nsql.sqlite3_backup_init(
      context.copy!.handle.cast(),
      context.name.cast(),
      source.handle.cast(),
      context.name.cast(),
    );
    if (context.backup == nullptr) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.invalid);
    }
    return _reply('ready', false);
  }

  Set<String> _registeredTables(String metadata) {
    if (metadata.length > _SnapshotLimits.maxSchemaBytes ||
        utf8.encode(metadata).length > _SnapshotLimits.maxSchemaBytes ||
        utf8.decode(utf8.encode(metadata)) != metadata) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.tooLarge);
    }
    final names = jsonDecode(metadata);
    if (names is! List ||
        names.isEmpty ||
        names.length > _SnapshotLimits.maxTables) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.invalid);
    }
    final tables = <String>{};
    for (final name in names) {
      if (name is! String ||
          name.isEmpty ||
          name.contains('\u0000') ||
          utf8.encode(name).length > _SnapshotLimits.maxIdentifierBytes ||
          utf8.decode(utf8.encode(name)) != name ||
          !tables.add(name)) {
        throw const _SnapshotFailure(DatabaseSnapshotStatus.invalid);
      }
    }
    return Set.unmodifiable(tables);
  }

  String _retire(String status, {int? tableCount}) {
    final context = active!;
    if (!context.close()) return _reply('uncertain', false);
    active = null;
    closedToken = context.token;
    return _reply(status, true, tableCount: tableCount);
  }

  static String _reply(String status, bool closed, {int? tableCount}) =>
      jsonEncode({
        'status': status,
        'closed': closed,
        if (status == 'verified' && tableCount != null)
          'tableCount': tableCount,
      });
}

/// The original destination and backup stay owned here until real native close.
final class _WorkerSnapshot {
  _WorkerSnapshot(this.token, this.schema, this.tables, this.guard);
  final String token;
  final _SnapshotSchema schema;
  final Set<String> tables;
  final _SnapshotGuard guard;
  Database? copy;
  _WorkerSnapshotMemory? memory;
  Pointer<Uint8> name = nullptr;
  Pointer<nsql.sqlite3_backup> backup = nullptr;
  int steps = 0;
  bool done = false;
  int? finishCode;

  int finishBackup() {
    if (backup != nullptr) {
      finishCode = nsql.sqlite3_backup_finish(backup);
      backup = nullptr; // Even a non-OK finish consumed the native handle.
    }
    return finishCode ?? 0;
  }

  bool close() {
    try {
      finishBackup();
      copy?.close();
      copy = null;
      if (name != nullptr) {
        memory!.free(name);
        name = nullptr;
      }
      return backup == nullptr && copy == null && name == nullptr;
    } catch (_) {
      return false; // Abort retries cleanup on these same original handles.
    }
  }
}

final class _WorkerSnapshotMemory {
  _WorkerSnapshotMemory() {
    final library = DynamicLibrary.open(
      Platform.isWindows ? 'kernel32.dll' : 'libc.so',
    );
    if (Platform.isWindows) {
      final allocate = library
          .lookupFunction<
            Pointer<Uint8> Function(Uint32, UintPtr),
            Pointer<Uint8> Function(int, int)
          >('LocalAlloc');
      final release = library
          .lookupFunction<
            Pointer<Void> Function(Pointer<Void>),
            Pointer<Void> Function(Pointer<Void>)
          >('LocalFree');
      _allocate = () => allocate(0x40, 5);
      _free = (name) {
        if (release(name.cast()) != nullptr)
          throw StateError('Native release failed');
      };
    } else {
      final allocate = library
          .lookupFunction<
            Pointer<Uint8> Function(UintPtr),
            Pointer<Uint8> Function(int)
          >('malloc');
      final release = library
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('free');
      _allocate = () => allocate(5);
      _free = (name) => release(name.cast());
    }
  }
  late final Pointer<Uint8> Function() _allocate;
  late final void Function(Pointer<Uint8>) _free;

  Pointer<Uint8> allocate() {
    final result = _allocate();
    if (result == nullptr) throw StateError('Native allocation failed');
    return result;
  }

  void free(Pointer<Uint8> name) => _free(name);
}
