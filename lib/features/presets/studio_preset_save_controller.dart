import 'dart:async';

import '../../core/models/studio_config.dart';

typedef StudioPresetWriter = Future<void> Function(StudioPreset preset);

/// Debounces editor snapshots and serializes their full-row writes.
///
/// A timer callback is not itself a reliable indication that a snapshot was
/// saved: by the time it runs, the timer is inactive. The controller therefore
/// keeps the latest dirty snapshot independently and clears it only after its
/// write succeeds. Writes are chained so an older full-row snapshot cannot
/// finish after a newer one and overwrite it.
class StudioPresetSaveController {
  final StudioPresetWriter write;
  final Duration debounce;

  Timer? _timer;
  StudioPreset? _dirtyPreset;
  int _dirtyRevision = 0;
  int? _queuedRevision;
  Future<void>? _queuedDirtyWrite;

  Future<void> _tail = Future<void>.value();
  Future<void> _lastWrite = Future<void>.value();

  StudioPresetSaveController({
    required this.write,
    this.debounce = const Duration(milliseconds: 500),
  });

  bool get hasDirtySnapshot => _dirtyPreset != null;

  /// Records the latest editor state and starts/restarts the debounce window.
  void schedule(StudioPreset preset) {
    _dirtyPreset = preset;
    _dirtyRevision++;
    _timer?.cancel();
    _timer = Timer(debounce, _flushFromTimer);
  }

  /// Queues an immediate snapshot, superseding any not-yet-enqueued debounce.
  /// An already-running write remains in the chain and the immediate snapshot
  /// follows it, so the final durable row is still the latest one.
  Future<void> writeImmediately(StudioPreset preset) {
    _dirtyPreset = preset;
    _dirtyRevision++;
    return flush();
  }

  /// Flushes the current dirty snapshot and waits for all writes queued so far.
  /// A failed write deliberately leaves the dirty snapshot in place.
  Future<void> flushAndWait() async {
    await flush();
    await _lastWrite;
  }

  /// Cancels only the debounce. The dirty snapshot remains available for a
  /// later explicit flush, which is important when an inline editor closes.
  void cancelDebounce() {
    _timer?.cancel();
    _timer = null;
  }

  /// Drops an edit that is being abandoned, such as after preset deletion.
  void discardDirty() {
    cancelDebounce();
    _dirtyPreset = null;
    _dirtyRevision++;
    _queuedRevision = null;
    _queuedDirtyWrite = null;
  }

  /// Stops future timer callbacks. An already queued write is intentionally
  /// not cancelled; cancelling a full-row database write is not safe here.
  void dispose() => cancelDebounce();

  Future<void> flush() {
    cancelDebounce();
    final dirty = _dirtyPreset;
    if (dirty == null) return _lastWrite;

    final revision = _dirtyRevision;
    if (_queuedRevision == revision && _queuedDirtyWrite != null) {
      return _queuedDirtyWrite!;
    }

    _queuedRevision = revision;
    final write = _enqueue(dirty);
    final completed = write.then<void>(
      (_) {
        if (_dirtyRevision == revision && identical(_dirtyPreset, dirty)) {
          _dirtyPreset = null;
          _queuedRevision = null;
          _queuedDirtyWrite = null;
        } else if (_queuedRevision == revision) {
          // A newer edit is still dirty and must be flushed separately.
          _queuedRevision = null;
          _queuedDirtyWrite = null;
        }
      },
      onError: (Object error, StackTrace stack) {
        if (_queuedRevision == revision) {
          _queuedRevision = null;
          _queuedDirtyWrite = null;
        }
        Error.throwWithStackTrace(error, stack);
      },
    );
    _queuedDirtyWrite = completed;
    // Timer-triggered failures are observed below; explicit callers still
    // receive this failed future and must not reload over the dirty snapshot.
    _lastWrite = completed;
    return completed;
  }

  Future<void> _enqueue(StudioPreset preset) {
    final operation = _tail.then((_) => write(preset));
    // Keep the chain usable after a failure. The operation returned to the
    // caller still carries the original error and can abort an upgrade.
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _lastWrite = operation;
    return operation;
  }

  void _flushFromTimer() {
    unawaited(_flushFromTimerAsync());
  }

  Future<void> _flushFromTimerAsync() async {
    try {
      await flush();
    } catch (_) {
      // The dirty snapshot stays available for an explicit flush. Lifecycle
      // callbacks have no safe UI surface on which to report this failure.
    }
  }
}
