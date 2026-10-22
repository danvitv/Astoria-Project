import 'dart:math';

/// Native metadata, not a configuration/credential fingerprint or durable log.
/// Every new lifetime requires recipient reconfirmation. Raw database writers
/// which bypass the repository/outer import hook are NOT observed here.
final class ConnectionRevisionRegistry {
  ConnectionRevisionRegistry() : _revision = _randomBaseline();

  static const _maxRevision = 9007199254740991;
  int _revision;
  int _pending = 0;
  bool _exhausted = false;
  bool _disposed = false;
  final _listeners = <Object, void Function()>{};

  int get revision => _revision;
  bool get isStable => !_disposed && !_exhausted && _pending == 0;

  /// Synchronous state-change observation, with no initial call or read effect.
  /// Listeners read [revision]/[isStable] after begin or each nested settlement.
  /// Each subscription is independent; unsubscribe is idempotent and prevents
  /// calls not yet dispatched, including within a current notification.
  /// Failures are isolated and never formatted or logged. A disposed registry
  /// accepts no observers and returns an inert unsubscribe callback.
  void Function() subscribe(void Function() listener) {
    if (_disposed) return () {};
    final key = Object();
    _listeners[key] = listener;
    return () => _listeners.remove(key);
  }

  /// Called synchronously before mutation admission, even before map decoding.
  /// Global invalidation deliberately revokes all native recipient bindings.
  /// The returned callback settles the fence, whether the write succeeds or not.
  void Function() beginMutation() {
    _advance();
    _pending++;
    if (!_disposed) _notify();
    var finished = false;
    return () {
      if (finished) return;
      finished = true;
      _pending--;
      _advance();
      if (!_disposed) _notify();
    };
  }

  /// Permanently invalidates native reads and notifies once before releasing
  /// observers. Already-admitted ordinary writes can still settle idempotently.
  /// Stale ordinary service/repository instances may also begin/settle writes:
  /// counts advance normally, but this lifetime never becomes stable again and
  /// emits no more notifications. Disposal does not cancel or roll back writes.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _advance();
    _notify();
    _listeners.clear();
  }

  void _notify() {
    for (final entry in _listeners.entries.toList()) {
      if (!_listeners.containsKey(entry.key)) continue;
      try {
        entry.value();
      } on Object {
        // Observation must not abort an ordinary write or expose its error.
      }
    }
  }

  void _advance() {
    if (_revision == _maxRevision) {
      _exhausted = true;
    } else {
      _revision++;
    }
  }

  static int _randomBaseline() {
    final random = Random.secure();
    // 52 random bits, independent of any user/config/secret, leaving headroom.
    return 1 + random.nextInt(1 << 26) * (1 << 26) + random.nextInt(1 << 26);
  }
}
