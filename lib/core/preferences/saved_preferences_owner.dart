import 'dart:async';

/// The finite saved-data surface. This is not a generic settings capability.
abstract final class SavedPreferencesKeys {
  static const families = <String, Set<String>>{
    'savedMemoryPreferences': {'memorySettings'},
    'savedPipelinePreferences': {'pipelineSettings'},
    'savedRegexPreferences': {
      'gz_global_regex_scripts',
      'gz_studio_regex_scripts',
    },
    'savedSelectionPreferences': {
      'activePresetId',
      'activePersonaId',
      'personaConnections',
      'presetConnections',
      'activeStudioPresetId',
      'feature_studio_enabled',
      'activeApiConfigId',
      'activeEmbeddingConfigId',
      'active_preset_id',
    },
    'savedGlobalVariables': {'globalVars', 'glaze.global_variables'},
  };
  static final Set<String> all = Set.unmodifiable(
    families.values.expand((v) => v),
  );
}

/// Shared by every attachment/container in THIS isolate, not SQLite or an OS
/// lock. Unknown plugins/processes/backends are explicitly outside this proof.
final class SavedPreferencesOwner {
  SavedPreferencesOwner._();
  static final process = SavedPreferencesOwner._();
  final _revisions = {for (final key in SavedPreferencesKeys.all) key: 0};
  final _pending = {for (final key in SavedPreferencesKeys.all) key: 0};
  final _stores = Expando<SavedPreferencesStore>();
  SavedPreferencesStore? _originalStore;
  int _storeRevision = 0;
  SavedPreferencesStore? get originalStore => _originalStore;

  /// Synchronous admission snapshot, not a new source lease. Reload must capture
  /// this before adding its own intent to detect setters already in flight.
  Set<String> get pendingKeys => Set.unmodifiable({
    for (final e in _pending.entries)
      if (e.value > 0) e.key,
  });

  SavedPreferencesStore attach(
    Object actualStore, {
    bool trustedPlugin = false,
    bool Function()? backendCurrent,
  }) {
    final existing = _stores[actualStore];
    if (existing != null) {
      if (existing._backendCurrent?.call() == false) existing._retired = true;
      if (trustedPlugin && !existing._retired) {
        existing._trustedPlugin = true;
        existing._backendCurrent ??= backendCurrent;
      }
      return existing; // A retired store never revives (ABA).
    }
    final next = SavedPreferencesStore._(this, actualStore);
    next._trustedPlugin = trustedPlugin;
    next._backendCurrent = backendCurrent;
    _stores[actualStore] = next;
    _originalStore?._retired = true;
    _originalStore = next;
    _storeRevision++;
    return next;
  }

  SavedPreferencesIntent begin(Iterable<String> keys) {
    final selected = keys.where(SavedPreferencesKeys.all.contains).toSet();
    for (final key in selected) {
      _revisions[key] = _revisions[key]! + 1;
      _pending[key] = _pending[key]! + 1;
    }
    return SavedPreferencesIntent._(this, selected);
  }

  SavedPreferencesLease capture(
    Iterable<String> keys, {
    SavedPreferencesStore? store,
  }) {
    final revisions = {for (final key in keys) key: _revisions[key]!};
    return SavedPreferencesLease._(
      this,
      store,
      Map.unmodifiable(revisions),
      revisions.keys.every(
        (k) => _pending[k] == 0 && !(store?._uncertain.contains(k) ?? false),
      ),
    );
  }

  void acknowledge(SavedPreferencesStore store, String key, bool success) {
    if (!SavedPreferencesKeys.all.contains(key)) return;
    if (!success || !store.current) {
      // The plugin cache is optimistic. A false/throw is not saved evidence.
      store._uncertain.add(key);
    }
    if (!identical(store, _originalStore)) {
      // Legacy plugin setters may consult a process-global backing producer.
      // A late setter retained by A can affect B without updating B's cache.
      // Never manufacture B's saved stability from A's acknowledgement.
      _originalStore?._uncertain.add(key);
    }
  }

  /// Narrow single-key native CAS admission. Does not relax ordinary read leases
  /// or failure quarantine. Its own issued revision is retained before callbacks.
  SavedPreferencesConditionalWrite? beginConditional(
    SavedPreferencesLease expected,
    SavedPreferencesStore store,
    String key,
  ) {
    if (!identical(expected.owner, this) ||
        !identical(expected.store, store) ||
        !expected.current ||
        expected.revisions.length != 1 ||
        !expected.revisions.containsKey(key))
      return null;
    final intent = begin([key]);
    return SavedPreferencesConditionalWrite._(
      this,
      store,
      key,
      intent,
      _revisions[key]!,
    );
  }
}

/// Finite already-admitted writer, not a renewed read fence. Overlapping intents,
/// including same-value ABA, invalidate both the completion and its receipt.
final class SavedPreferencesConditionalWrite {
  SavedPreferencesConditionalWrite._(
    this.owner,
    this.store,
    this.key,
    this._intent,
    this._revision,
  );
  final SavedPreferencesOwner owner;
  final SavedPreferencesStore store;
  final String key;
  final SavedPreferencesIntent _intent;
  final int _revision;
  bool _closed = false;
  bool get current =>
      !_closed &&
      store.current &&
      owner._revisions[key] == _revision &&
      owner._pending[key] == 1;

  SavedPreferencesLease? finish(bool accepted) {
    if (_closed) return null;
    final retained = current;
    // An overlapping setter can persist after a newer optimistic cache paint.
    // Its true ack does not certify that cache as saved observation.
    owner.acknowledge(store, key, accepted && retained);
    _closed = true;
    _intent.settle();
    if (!retained ||
        !accepted ||
        !store.current ||
        owner._revisions[key] != _revision + 1 ||
        owner._pending[key] != 0 ||
        store._uncertain.contains(key))
      return null;
    return SavedPreferencesLease._(
      owner,
      store,
      Map.unmodifiable({key: _revision + 1}),
      true,
    );
  }
}

final class SavedPreferencesStore {
  SavedPreferencesStore._(this.owner, this.actualStore);
  final SavedPreferencesOwner owner;
  final Object actualStore;
  bool _retired = false;
  final _uncertain = <String>{};
  bool _trustedPlugin = false;
  bool Function()? _backendCurrent;
  bool get current {
    if (_backendCurrent?.call() == false) _retired = true;
    return !_retired && _trustedPlugin && identical(owner._originalStore, this);
  }
}

final class SavedPreferencesIntent {
  SavedPreferencesIntent._(this._owner, this._keys);
  final SavedPreferencesOwner _owner;
  final Set<String> _keys;
  bool _settled = false;
  void settle() {
    if (_settled) return;
    _settled = true;
    for (final key in _keys) {
      _owner._pending[key] = _owner._pending[key]! - 1;
      _owner._revisions[key] = _owner._revisions[key]! + 1;
    }
  }
}

/// Once invalid, always invalid. A producer's late resolution may bind only the
/// originally retained ticket, never capture replacement revisions after await.
final class SavedPreferencesLease {
  SavedPreferencesLease._(this.owner, this._store, this.revisions, bool valid)
    : _retired = !valid,
      _storeRevision = owner._storeRevision;
  final SavedPreferencesOwner owner;
  SavedPreferencesStore? _store;
  final Map<String, int> revisions;
  bool _retired;
  final int _storeRevision;
  SavedPreferencesStore? get store => _store;
  bool bindOriginalStore(SavedPreferencesStore store) {
    if (!current || (_store != null && !identical(_store, store))) {
      retire();
      return false;
    }
    _store ??= store;
    return current;
  }

  bool get current {
    if (_retired) return false;
    if ((_store != null && !_store!.current) ||
        (_store == null && owner._storeRevision > _storeRevision + 1) ||
        revisions.entries.any(
          (e) =>
              owner._revisions[e.key] != e.value ||
              owner._pending[e.key] != 0 ||
              (_store?._uncertain.contains(e.key) ?? false),
        )) {
      _retired = true;
    }
    return !_retired;
  }

  void retire() => _retired = true;
  List<Object?> get privateMaterial => [
    identityHashCode(owner),
    identityHashCode(_store),
    _storeRevision,
    revisions,
  ];
}

/// Outer writer hooks MUST surround queue admission, acquisition and optimistic
/// publication. Facade setters additionally retain actual acknowledgement work.
abstract final class SavedPreferencesWrites {
  static Future<T> run<T>(Iterable<String> keys, Future<T> Function() write) {
    final intent = SavedPreferencesOwner.process.begin(keys);
    return Future.sync(write).whenComplete(intent.settle);
  }

  static T runSync<T>(Iterable<String> keys, T Function() write) {
    final intent = SavedPreferencesOwner.process.begin(keys);
    try {
      return write();
    } finally {
      intent.settle();
    }
  }
}
