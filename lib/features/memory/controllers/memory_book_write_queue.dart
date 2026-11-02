import '../../../core/models/memory_book.dart';

/// Serializes MemoryBook persistence for the sheet's own edits.
///
/// [saveLatest] deliberately reads the book only after earlier writes finish,
/// so two edits made in quick succession are written in order rather than as
/// competing snapshots. Draft generation does not come through here at all —
/// it outlives the sheet, so it writes its one draft through the repository's
/// own transaction (`MemoryBookRepo.mutateDraft`).
class MemoryBookWriteQueue {
  final MemoryBook? Function() readLatest;
  final Future<void> Function(MemoryBook book) persist;

  Future<void> _tail = Future<void>.value();
  int _revision = 0, _pending = 0;
  bool _exhausted = false;
  int get revision => _revision;
  bool get idle => !_exhausted && _pending == 0;
  void _advance() {
    if (_revision >= 9007199254740991) {
      _exhausted = true;
    } else {
      _revision++;
    }
  }

  MemoryBookWriteQueue({required this.readLatest, required this.persist});

  Future<void> saveLatest() => _enqueue(() async {
    final latest = readLatest();
    if (latest != null) await persist(latest);
  });

  Future<void> runDurableOperation(Future<void> Function() operation) =>
      _enqueue(operation);
  Future<void> _enqueue(Future<void> Function() operation) {
    _advance();
    _pending++;
    final previous = _tail;
    final next = () async {
      try {
        await previous;
      } catch (_) {
        // One failed write must not poison subsequent queued operations.
      }
      try {
        await operation();
      } finally {
        _pending--;
        _advance();
      }
    }();
    _tail = next.then<void>((_) {}, onError: (_, _) {});
    return next;
  }

  /// One original queue admission, not a replacement queue or retry capability.
  Future<T?> runNative<T>(
    int expected,
    Future<T?> Function(bool Function() queueCurrent) effect,
  ) async {
    if (!idle || revision != expected) return null;
    T? result;
    await _enqueue(() async {
      bool current() =>
          !_exhausted && _pending == 1 && _revision == expected + 1;
      if (current()) result = await effect(current);
    });
    return result;
  }
}
