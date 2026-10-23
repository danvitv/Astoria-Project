part of 'native_provider_credentials.dart';

final class NativeConnectionStamp {
  const NativeConnectionStamp._(this._owner, this._revision);
  final NativeConnectionMutationOwner _owner;
  final int _revision;

  @override
  String toString() => 'NativeConnectionStamp';
}

final class NativeConnectionAdmission {
  NativeConnectionAdmission._(this._stamp, this._isOriginalOwner);
  final NativeConnectionStamp _stamp;
  final bool Function() _isOriginalOwner;
  bool _claimed = false;

  @override
  String toString() => 'NativeConnectionAdmission';
}

/// Its own observer fences revoke old references, but not the original effect.
/// Competing edits, including A -> B -> A, permanently invalidate this lease.
final class NativeConnectionOperationLease {
  NativeConnectionOperationLease._(
    this._owner,
    this._revision,
    this._isOriginalOwner,
  );
  final NativeConnectionMutationOwner _owner;
  int _revision;
  final bool Function() _isOriginalOwner;
  bool _closed = false;
  bool _invalidated = false;
  NativeConnectionStamp? _settlementStamp;

  /// Available only after the outer operation has settled without competition.
  /// A repository may retain this opaque stamp in its native receipt, not JSON.
  NativeConnectionStamp? get settlementStamp => _settlementStamp;

  bool get isCurrent {
    bool ownsLease() =>
        !_closed &&
        !_invalidated &&
        !_owner._disposed &&
        _owner._active == this &&
        _owner._revision == _revision;
    return ownsLease() && _current(_isOriginalOwner) && ownsLease();
  }

  /// The repository's no-ID start/finish observer recognizes ONLY this zone.
  /// Keep the outer transaction inside this call; never settle nested commits.
  /// Repo owns per-await/precommit admission; an already committed return is an
  /// original fact, not a new admission. Publication must be fenced separately.
  Future<T> runObservedMutation<T>(Future<T> Function() operation) async {
    _requireCurrent(() => isCurrent);
    try {
      return await runZoned(operation, zoneValues: {_owner._zoneKey: this});
    } on NativeProviderException {
      rethrow;
    } catch (_) {
      throw const NativeProviderException(NativeProviderFailure.unavailable);
    }
  }

  @override
  String toString() => 'NativeConnectionOperationLease';
}

/// One same-process global owner per database/storage namespace. Global FIFO is
/// deliberately conservative because ApiConfigRepo's observer supplies no ID.
/// This is not a DB transaction, cross-process CAS or durable ABA receipt.
final class NativeConnectionMutationOwner {
  NativeConnectionMutationOwner({required this._redaction});

  final SecretRedactionCoordinator _redaction;
  final Object _zoneKey = Object();
  final Map<String, _NativeSavedRow> _rows = {};
  final List<void Function()> _fences = [];
  int _revision = 0;
  int _observedMutations = 0;
  NativeConnectionOperationLease? _active;
  Future<void> _tail = Future<void>.value();
  int _ownedPending = 0;
  bool _disposed = false;

  bool get isStable => !_disposed && _active == null && _observedMutations == 0;

  /// Only the original held operation's observer zone, not a competing import.
  bool get isInOwnedMutation {
    final lease = Zone.current[_zoneKey];
    return lease is NativeConnectionOperationLease && lease.isCurrent;
  }

  NativeConnectionStamp? observe() =>
      isStable ? NativeConnectionStamp._(this, _revision) : null;

  bool isCurrent(NativeConnectionStamp stamp) =>
      !_disposed &&
      identical(stamp._owner, this) &&
      stamp._revision == _revision &&
      _active == null &&
      _observedMutations == 0;

  NativeConnectionAdmission? admit({
    required NativeConnectionStamp expected,
    required bool Function() isOriginalOwner,
  }) => isCurrent(expected) && _current(isOriginalOwner) && isCurrent(expected)
      ? NativeConnectionAdmission._(expected, isOriginalOwner)
      : null;

  void addFenceListener(void Function() listener) {
    if (!_disposed) _fences.add(listener);
  }

  void removeFenceListener(void Function() listener) =>
      _fences.remove(listener);

  /// Permanent container retirement. Already-invoked work may settle its original
  /// fact, but can never mint fresh references/leases/permits or regain stability.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _fence(null);
    _fences.clear();
  }

  /// Wire alongside (never instead of) existing registry/redaction observers.
  /// External restore/import bypasses must call this outer fence too.
  /// No-ID observation revokes ALL stamps, never guesses which key to disable.
  void Function() onMutationStarted() {
    if (_disposed) return () {};
    final token = Zone.current[_zoneKey];
    final own = token is NativeConnectionOperationLease && token.isCurrent
        ? token
        : null;
    _observedMutations++;
    _fence(own);
    var finished = false;
    return () {
      if (finished) return;
      finished = true;
      _observedMutations--;
      _fence(own != null && own.isCurrent ? own : null);
    };
  }

  Future<T> runOwned<T>({
    required NativeConnectionAdmission admission,
    required Future<T> Function(NativeConnectionOperationLease lease) operation,
  }) {
    if (admission._claimed) {
      return Future.error(
        const NativeProviderException(NativeProviderFailure.stale),
      );
    }
    admission._claimed = true;
    Future<T> invoke() async {
      NativeConnectionOperationLease? lease;
      try {
        if (!isCurrent(admission._stamp)) {
          throw const NativeProviderException(NativeProviderFailure.stale);
        }
        _requireCurrent(admission._isOriginalOwner);
        if (!isCurrent(admission._stamp)) {
          throw const NativeProviderException(NativeProviderFailure.stale);
        }
        final activeLease = NativeConnectionOperationLease._(
          this,
          _revision,
          admission._isOriginalOwner,
        );
        lease = activeLease;
        _active = activeLease;
        _fence(activeLease);
        _requireCurrent(() => activeLease.isCurrent);
        return await operation(activeLease);
      } on NativeProviderException {
        rethrow;
      } catch (_) {
        throw const NativeProviderException(NativeProviderFailure.unavailable);
      } finally {
        _ownedPending--;
        if (lease != null) {
          lease._closed = true;
          _active = null;
          final expectedSettlementRevision = _revision + 1;
          _fence(null);
          if (!_disposed &&
              !lease._invalidated &&
              _observedMutations == 0 &&
              _active == null &&
              _revision == expectedSettlementRevision) {
            lease._settlementStamp = NativeConnectionStamp._(this, _revision);
          }
        }
      }
    }

    // First admission fences SYNCHRONOUSLY, before the first storage await.
    // A queued operation still rechecks its original stamp at execution.
    final startNow = _ownedPending == 0;
    _ownedPending++;
    final result = startNow ? invoke() : _tail.then((_) => invoke());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  void _fence(NativeConnectionOperationLease? own) {
    if (_active != null && !identical(_active, own)) {
      _active!._invalidated = true;
    }
    _revision++;
    _rows.clear();
    if (own != null) own._revision = _revision;
    for (final listener in List.of(_fences)) {
      // Observer errors must not turn a successful write into an unsafe error.
      try {
        listener();
      } catch (_) {
        /* fencing remains in effect */
      }
    }
  }

  _NativeSavedRow? _row(NativeProviderConnectionIdentity connection) {
    final row = _rows[connection.id];
    return row != null && row.identity == connection && isCurrent(row.stamp)
        ? row
        : null;
  }

  @override
  String toString() => 'NativeConnectionMutationOwner';
}
