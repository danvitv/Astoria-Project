part of 'theme_selection.dart';

/// Same-owner admission/ABA fence. All effects use the notifier's actual queue,
/// injected here rather than a second service-owned queue or optimistic API.
class ThemeSelectionOwner {
  ThemeSelectionOwner({
    required this.prepare,
    required this.sequence,
    required this.storage,
    required this.active,
    required this.publish,
  });

  final Future<void> Function() prepare;
  final Future<T> Function<T>(Future<T> Function()) sequence;
  final ThemeSelectionStore? Function() storage;
  final ThemePreset Function() active;
  final void Function(ThemePreset, List<ThemePreset>?) publish;
  final Object _identity = Object();
  final Expando<bool> _consumed = Expando<bool>();
  int _revision = 0;
  bool _retired = false;

  int get revision => _revision;
  int admitOrdinaryMutation() => ++_revision;
  void retire() {
    _retired = true;
    ++_revision;
  }

  bool _current(int revision, bool Function() isCurrent) {
    if (_retired || revision != _revision) return false;
    try {
      final approved = isCurrent();
      return approved && !_retired && revision == _revision;
    } catch (_) {
      return false;
    }
  }

  ThemeSelectionCode _denialCode(int revision) =>
      !_retired && revision != _revision
      ? ThemeSelectionCode.conflict
      : ThemeSelectionCode.revoked;

  Future<ThemeSelectionReadResult> observe({
    required bool Function() isCurrent,
  }) async {
    final revision = _revision;
    if (!_current(revision, isCurrent)) {
      return ThemeSelectionReadResult(_denialCode(revision));
    }
    try {
      await prepare();
      if (!_current(revision, isCurrent)) {
        return ThemeSelectionReadResult(_denialCode(revision));
      }
      final result = await sequence(() async {
        if (!_current(revision, isCurrent)) {
          return ThemeSelectionReadResult(_denialCode(revision));
        }
        final store = storage();
        if (store == null) {
          return const ThemeSelectionReadResult(
            ThemeSelectionCode.unsupportedStorage,
          );
        }
        final stored = await store.readSelectionFresh();
        if (!_current(revision, isCurrent)) {
          return ThemeSelectionReadResult(_denialCode(revision));
        }
        if (active() != stored.active) {
          return const ThemeSelectionReadResult(ThemeSelectionCode.conflict);
        }
        return ThemeSelectionReadResult(
          ThemeSelectionCode.ready,
          ThemeSelectionObservation._(_identity, revision, stored),
        );
      });
      return _current(revision, isCurrent)
          ? result
          : ThemeSelectionReadResult(_denialCode(revision));
    } on ThemeSelectionInvalidStorage {
      return ThemeSelectionReadResult(
        _current(revision, isCurrent)
            ? ThemeSelectionCode.invalidStorage
            : _denialCode(revision),
      );
    } catch (_) {
      return ThemeSelectionReadResult(
        _current(revision, isCurrent)
            ? ThemeSelectionCode.readFailed
            : _denialCode(revision),
      );
    }
  }

  Future<ThemeSelectionResult> apply(
    ThemeSelectionPlan plan, {
    required bool Function() isCurrent,
  }) => _select(
    token: plan,
    owner: plan._owner,
    revision: plan._revision,
    before: plan._before,
    after: plan._after,
    mode: plan._mode,
    isCurrent: isCurrent,
  );

  Future<ThemeSelectionResult> undo(
    ThemeSelectionReceipt receipt, {
    required bool Function() isCurrent,
  }) => _select(
    token: receipt,
    owner: receipt._owner,
    revision: receipt._revision,
    before: receipt._after,
    after: receipt._before,
    mode: receipt._mode?.reversed,
    isCurrent: isCurrent,
  );

  Future<ThemeSelectionResult> _select({
    required Object token,
    required Object owner,
    required int revision,
    required ThemePreset before,
    required ThemePreset after,
    required _ThemeModeSnapshots? mode,
    required bool Function() isCurrent,
  }) async {
    if (!identical(owner, _identity)) {
      return const ThemeSelectionResult(ThemeSelectionCode.ownerChanged);
    }
    if (_consumed[token] == true) {
      return const ThemeSelectionResult(ThemeSelectionCode.alreadyConsumed);
    }
    _consumed[token] = true;
    if (!_current(revision, isCurrent)) {
      return ThemeSelectionResult(_denialCode(revision));
    }
    try {
      await prepare();
    } catch (_) {
      return ThemeSelectionResult(
        _current(revision, isCurrent)
            ? ThemeSelectionCode.preparationFailed
            : _denialCode(revision),
      );
    }
    if (!_current(revision, isCurrent)) {
      return ThemeSelectionResult(_denialCode(revision));
    }
    // This queued callback owns both fresh comparison and the actual invocation.
    return sequence(() async {
      if (!_current(revision, isCurrent)) {
        return ThemeSelectionResult(_denialCode(revision));
      }
      final store = storage();
      if (store == null || (mode != null && store is! ThemeModeStore)) {
        return const ThemeSelectionResult(
          ThemeSelectionCode.unsupportedStorage,
        );
      }
      ThemeSelectionStoredState stored;
      try {
        stored = await store.readSelectionFresh();
      } on ThemeSelectionInvalidStorage {
        return ThemeSelectionResult(
          _current(revision, isCurrent)
              ? ThemeSelectionCode.invalidStorage
              : _denialCode(revision),
        );
      } catch (_) {
        return ThemeSelectionResult(
          _current(revision, isCurrent)
              ? ThemeSelectionCode.readFailed
              : _denialCode(revision),
        );
      }
      if (!_current(revision, isCurrent)) {
        return ThemeSelectionResult(_denialCode(revision));
      }
      final matches = mode == null
          ? _matches(stored, before, after)
          : mode.matchesBefore(stored);
      if (!matches || active() != before) {
        return const ThemeSelectionResult(ThemeSelectionCode.conflict);
      }
      if (before == after) {
        return const ThemeSelectionResult(
          ThemeSelectionCode.noOp,
          freshObserved: ThemeSelectionFreshObservation.before,
          ownerCurrent: true,
        );
      }
      // No await between the final owner/content check and external invocation.
      final effectRevision = ++_revision;
      return _runThemeSelectionEffect(
        store: store,
        owner: _identity,
        revision: effectRevision,
        before: before,
        after: after,
        mode: mode,
        isCurrent: () => _current(effectRevision, isCurrent),
        publish: publish,
      );
    });
  }

  bool _matches(
    ThemeSelectionStoredState stored,
    ThemePreset active,
    ThemePreset other,
  ) =>
      stored.activeId == active.id &&
      stored.installed(active.id) == active &&
      stored.installed(other.id) == other;
}
