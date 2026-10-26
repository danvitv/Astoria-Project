@DefaultAsset('package:sqlite3/src/ffi/libsqlite3.g.dart')
library;

import 'dart:ffi';
import 'dart:typed_data';

// Original declarations of official SQLite C interfaces. All symbols resolve
// from sqlite3's EXISTING native asset; no second library or ownership transfer.
@Native<Pointer<Void> Function(Uint64)>()
external Pointer<Void> sqlite3_malloc64(int bytes);
@Native<Void Function(Pointer<Void>)>()
external void sqlite3_free(Pointer<Void> memory);
@Native<
  Int Function(
    Pointer<Void>,
    Pointer<Uint8>,
    Pointer<Uint8>,
    Pointer<Uint8>,
    Int64,
    Int,
    Pointer<Pointer<Void>>,
  )
>()
external int sqlite3_blob_open(
  Pointer<Void> db,
  Pointer<Uint8> schema,
  Pointer<Uint8> table,
  Pointer<Uint8> column,
  int rowid,
  int flags,
  Pointer<Pointer<Void>> result,
);
@Native<Int Function(Pointer<Void>)>()
external int sqlite3_blob_bytes(Pointer<Void> blob);
@Native<Int Function(Pointer<Void>, Pointer<Void>, Int, Int)>()
external int sqlite3_blob_read(
  Pointer<Void> blob,
  Pointer<Void> buffer,
  int length,
  int offset,
);
@Native<Int Function(Pointer<Void>)>()
external int sqlite3_blob_close(Pointer<Void> blob);
@Native<
  Void Function(
    Pointer<Void>,
    Int,
    Pointer<NativeFunction<Int Function(Pointer<Void>)>>,
    Pointer<Void>,
  )
>()
external void sqlite3_progress_handler(
  Pointer<Void> db,
  int instructions,
  Pointer<NativeFunction<Int Function(Pointer<Void>)>> callback,
  Pointer<Void> state,
);

/// Borrows the logical database pointer only during an original-worker command.
/// Every blob/allocation/callback closes before the command's future settles.
/// Byte offsets here are LOCAL BACKFILL ONLY, never model navigation.
final class HistoryBlobRead {
  HistoryBlobRead(Pointer<Void> database, int rowid) {
    _memory = sqlite3_malloc64(8256);
    if (_memory == nullptr) throw StateError('Native history unavailable');
    try {
    final bytes = _memory.cast<Uint8>().asTypedList(8256);
    bytes.fillRange(0, 64, 0);
    bytes.setRange(0, 5, 'main\x00'.codeUnits);
    bytes.setRange(8, 22, 'chat_sessions\x00'.codeUnits);
    bytes.setRange(24, 38, 'messages_json\x00'.codeUnits);
    final base = _memory.cast<Uint8>();
    final slot = (base + 48).cast<Pointer<Void>>();
    if (sqlite3_blob_open(
          database,
          base,
          base + 8,
          base + 24,
          rowid,
          0,
          slot,
        ) !=
        0) {
      throw StateError('Native history unavailable');
    }
    _blob = slot.value;
    } catch (_) {
      close();
      rethrow;
    }
  }
  Pointer<Void> _memory = nullptr, _blob = nullptr;
  int get length => sqlite3_blob_bytes(_blob);
  Uint8List read(int offset, int bytes) {
    if (bytes < 1 ||
        bytes > 8192 ||
        offset < 0 ||
        offset + bytes > length ||
        sqlite3_blob_read(
              _blob,
              (_memory.cast<Uint8>() + 64).cast(),
              bytes,
              offset,
            ) !=
            0) {
      throw StateError('Native history unavailable');
    }
    return Uint8List.fromList((_memory.cast<Uint8>() + 64).asTypedList(bytes));
  }

  void close() {
    final blob = _blob, memory = _memory;
    _blob = nullptr;
    _memory = nullptr;
    try {
      if (blob != nullptr) sqlite3_blob_close(blob);
    } finally {
      if (memory != nullptr) sqlite3_free(memory);
    }
  }
}

/// A native VM deadline, not Future.timeout. It interrupts SQL VM work on the
/// invoking worker. Blob I/O is additionally checked between 8 KiB reads; SQLite
/// does NOT promise progress callbacks during overflow-page traversal or OS I/O.
final class HistoryNativeDeadline {
  HistoryNativeDeadline(this.db, Duration duration)
    : _expires = DateTime.now().add(duration) {
    _callback = NativeCallable<Int Function(Pointer<Void>)>.isolateLocal(
      (Pointer<Void> _) => expired ? 1 : 0,
      exceptionalReturn: 1,
    );
    try {
      sqlite3_progress_handler(db, 256, _callback.nativeFunction, nullptr);
    } catch (_) {
      _callback.close();
      rethrow;
    }
  }
  final Pointer<Void> db;
  final DateTime _expires;
  late final NativeCallable<Int Function(Pointer<Void>)> _callback;
  bool _closed = false;
  bool get expired => !DateTime.now().isBefore(_expires);
  void check() {
    if (expired) throw StateError('Native history deadline');
  }

  void close() {
    if (_closed) return;
    _closed = true;
    try {
      sqlite3_progress_handler(db, 0, nullptr, nullptr);
    } finally {
      _callback.close();
    }
  }
}
