part of '../support_source_text_repo.dart';

/// Read-only, original-native navigation boundary. Create a new instance per run.
/// Every operation checks actual SQLite changes/data_version asynchronously.
/// The synchronous lease latches observed invalidation; it is NOT a synchronous
/// external-writer detector. The host MUST exclude writes in its original ROOT
/// and final synchronous ownership/POST gate after the last async revalidation.
final class SupportSourceNavigationRepo
    implements nav.OriginalRootNavigationRepository {
  SupportSourceNavigationRepo({
    required this._boundary,
    required bool Function() isCurrent,
    Future<String> Function()? activeStudioPresetId,
    Future<String?> Function()? activeOrdinaryPresetId,
  }) : _current = isCurrent,
       _activeStudio = activeStudioPresetId,
       _activeOrdinary = activeOrdinaryPresetId;

  final SupportSourceTextRepo _boundary;
  final bool Function() _current;
  final Future<String> Function()? _activeStudio;
  final Future<String?> Function()? _activeOrdinary;
  List<nav.SourceObservation> _lastDiscovery = const [];

  /// Exact observations from the last bounded page, for LOCAL target selection.
  List<nav.SourceObservation> get nativeDiscoveryCandidates => _lastDiscovery;
  AppDatabase get _db => _boundary._db;
  NativeDataSourceIdentity? _native;
  SecretRedactor? _projectionPolicy;
  (int, int)? _fence;
  int? _schemaVersion;
  bool _addressAttested = false;
  bool _retired = false, _checking = false, _busy = false;
  final Map<nav.SourceKey, _NavSource> _sources = {};
  final Map<String, _NavCapture> _captures = {};
  int _captureBytes = 0;
  SupportSourceReadFailure? _failure;
  _NavRootRevalidation? _rootValidation;
  bool _rootAdmissionPending = false;
  SupportSourceReadFailure? get lastFailure => _failure;

  bool usesDatabase(AppDatabase db) => _boundary.usesDatabase(db);

  @override
  nav.OriginalRootRevalidation? get currentOriginalRootRevalidation =>
      _rootValidation;

  /// The native owner, not a caller boolean, establishes this batch's ROOT.
  /// The history boundary rejects unknown/unaudited connections before invoking
  /// checkReadOnly. No completed fence or permission survives the single batch.
  Future<bool> admitOriginalRoot({
    required SupportTextContextRepo history,
    required List<SupportTextContextSnapshot> snapshots,
    required bool Function() isCurrent,
    required SupportTextAdmissionCheck checkReadOnly,
    required void Function() dispatch,
  }) async {
    if (_rootAdmissionPending || _rootValidation != null || _busy) {
      _retire();
      return false;
    }
    if (!_alive() || !history.retainsNativeDataSource(_native!)) return false;
    _rootAdmissionPending = true;
    try {
      return await history.admitDispatch(
        snapshots: snapshots,
        isCurrent: () => _alive() && isCurrent(),
        checkReadOnly: (checkpoint) async {
          checkpoint();
          if (_rootValidation != null) _fail();
          final validation = _NavRootRevalidation(this, checkpoint);
          _rootValidation = validation;
          try {
            final valid = await checkReadOnly(checkpoint);
            checkpoint();
            return valid;
          } finally {
            validation._active = false;
            _rootValidation = null;
          }
        },
        dispatch: dispatch,
      );
    } finally {
      _rootAdmissionPending = false;
    }
  }

  nav.FrozenScope? approvalScope(nav.SourceObservation observation) {
    final source = _owned(observation);
    if (source == null || !_alive()) return null;
    return source.scope;
  }

  /// Local UI only. Never put this authored label in discovery/model metadata.
  String? nativeLabel(nav.SourceObservation observation) =>
      _owned(observation)?.label;

  String nativeIdentityHint(nav.SourceObservation observation) {
    final source = _owned(observation);
    if (source == null || !_alive()) return '';
    final index = source.header['session_index'];
    final activity = source.header['updated_at'];
    String date = 'Дата активности неизвестна';
    if (activity is int && activity > 0) {
      try {
        final local = DateTime.fromMillisecondsSinceEpoch(
          _navActivity(activity),
        ).toLocal();
        String two(int n) => n.toString().padLeft(2, '0');
        date =
            'Сохранённая активность: ${two(local.day)}.${two(local.month)}.${local.year} '
            '${two(local.hour)}:${two(local.minute)} (местное время)';
      } on ArgumentError {
        /* Out-of-range imported dates stay unknown. */
      }
    }
    return '${index is int ? 'Сессия ${index + 1} · ' : ''}'
        '${observation.activeAtListing == true ? 'Выбран сейчас · ' : ''}'
        '$date';
  }

  /// Only call immediately after the host's successful ORIGINAL CAS append.
  /// This does not prove write identity; the host owns that attestation. Foreign
  /// changes, extra trigger writes, external commits and failed CAS never rebase.
  Future<bool> refreshAfterOwnSourceExtension(
    SupportReplySourceCommit commit,
  ) async {
    try {
      if (_rootValidation != null) _fail();
      _guard();
      final previous = _fence;
      if (previous == null) return false;
      final next = await _stamp();
      _guard();
      if (!commit.consumeForSourceAdvance(_db, previous, next)) {
        _fail(SupportSourceReadFailure.changed);
      }
      _fence = next;
      return true;
    } catch (_) {
      _retire();
      return false;
    }
  }

  void retire() => _retire();

  List<String>? nativeIdsFor(nav.ProvenanceEntry entry) {
    final material = _provenance(entry);
    return material == null ? null : List.unmodifiable(material.$1);
  }

  String? privateDigestFor(nav.ProvenanceEntry entry) {
    final material = _provenance(entry);
    if (material == null) return null;
    return sha256.convert(utf8.encode(jsonEncode(material.$2))).toString();
  }

  (List<String>, Object)? _provenance(nav.ProvenanceEntry entry) {
    final source = _owned(entry.source);
    if (source == null ||
        !_alive() ||
        entry.extents.length > 16 ||
        entry.grant.source != entry.source.key ||
        !entry.grant.snapshot.same(entry.source.snapshot)) {
      return null;
    }
    // The source/session/character are already exact private bindings in the
    // entry and digest. This bounded list is the native selected-record extent,
    // not a duplicate list of all binding/citation identities.
    final ids = <String>{};
    final captures = <Object?>[];
    for (final extent in entry.extents) {
      if (!_allowed(source, entry.grant.scope, extent.selection)) return null;
      final capture = source.captures[_selectionKey(extent.selection)];
      if (capture == null) return null;
      final record = capture.record;
      if (record == null ||
          jsonEncode(_bindingMaterial(record.binding)) !=
              jsonEncode(_bindingMaterial(extent.binding))) {
        return null;
      }
      ids.addAll(capture.ids);
      if (ids.length > 16) return null;
      if ((extent.startScalar == null) != (extent.endScalar == null) ||
          (extent.startScalar != null &&
              (extent.startScalar! < 0 ||
                  extent.endScalar! < extent.startScalar!))) {
        return null;
      }
      if (extent.endScalar != null &&
          (record.payload is! String ||
              extent.endScalar! >
                  _projectComplete(record.payload as String).runes.length)) {
        return null;
      }
      // These are projected scalar extents, not invented raw/evidence offsets.
      captures.add([
        capture.raw,
        _selectionMaterial(extent.selection),
        extent.startScalar,
        extent.endScalar,
        _bindingMaterial(extent.binding),
      ]);
    }
    if (ids.isEmpty) ids.add(entry.source.key.nativeId);
    return (
      ids.toList(growable: false),
      [
        entry.source.key.domain.name,
        entry.source.key.nativeId,
        source.header,
        entry.source.snapshot.incarnation,
        entry.source.snapshot.revision,
        entry.source.snapshot.privateIntegrity,
        captures,
        entry.operation,
        entry.argumentsJson,
        entry.exactWireJson,
        entry.exactEnvelopeJson,
        entry.projection.incarnation,
        entry.projection.revision,
      ],
    );
  }

  bool _alive() {
    try {
      _guard();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _guard() {
    if (_retired || _checking) _fail();
    _checking = true;
    try {
      final native = _db.nativeDataSourceIdentity;
      if (!_current() ||
          native == null ||
          _db.isClosing ||
          !_boundary._text.retainsNativeDataSource(native) ||
          (_native != null && !identical(native, _native))) {
        _fail();
      }
      _native ??= native;
      final policy = _boundary._currentRedactor();
      if (_projectionPolicy != null && !identical(_projectionPolicy, policy)) {
        _fail(SupportSourceReadFailure.changed);
      }
      _projectionPolicy ??= policy;
    } catch (_) {
      _retire();
      rethrow;
    } finally {
      _checking = false;
    }
  }

  void _retire() {
    _retired = true;
    _rootValidation?._active = false;
    _failure ??= SupportSourceReadFailure.unavailable;
  }

  Never _fail([
    SupportSourceReadFailure failure = SupportSourceReadFailure.unavailable,
  ]) {
    _failure ??= failure;
    _retired = true;
    throw SupportSourceReadException(failure: _failure!);
  }

  Future<List<QueryRow>> _sql(
    String sql, [
    List<Variable> variables = const [],
  ]) async {
    _guard();
    final result = await _db.customSelect(sql, variables: variables).get();
    _guard();
    _rootValidation?._check();
    return result;
  }

  Future<(int, int)> _stamp() async {
    if (!_addressAttested) {
      if (!await _db.historySourceIndex.attestNavigation()) _fail();
      _guard();
      _rootValidation?._check();
      _addressAttested = true;
    }
    final rows = await _sql(
      'SELECT total_changes() AS changes, '
      'data_version AS version,schema_version AS schema_revision FROM pragma_data_version,pragma_schema_version',
    );
    _guard();
    final schema = rows.single.read<int>('schema_revision');
    if (_schemaVersion != null && _schemaVersion != schema) {
      _fail(SupportSourceReadFailure.changed);
    }
    _schemaVersion ??= schema;
    return (rows.single.read<int>('changes'), rows.single.read<int>('version'));
  }

  Future<void> _fresh() async {
    final stamp = await _stamp();
    _guard();
    if (_fence != null && stamp != _fence) {
      _fail(SupportSourceReadFailure.changed);
    }
    _fence ??= stamp;
  }

  Future<T> _run<T>(nav.WorkBound bound, Future<T> Function() action) async {
    if (_rootValidation != null && !_rootValidation!._running) _fail();
    if (_busy) _fail();
    _busy = true;
    try {
      _guard();
      if (bound.pageSize < 1 ||
          bound.pageSize > 16 ||
          bound.candidateLimit < 1 ||
          bound.candidateLimit > 4096 ||
          bound.rawByteLimit < 1 ||
          bound.rawByteLimit > nav.Limits.rawBytes) {
        _fail();
      }
      await _fresh();
      _guard();
      _rootValidation?._check();
      final value = await action();
      _guard();
      _rootValidation?._check();
      await _fresh();
      _guard();
      _rootValidation?._check();
      return value;
    } on SupportSourceReadException catch (error) {
      _fail(error.failure);
    } on FormatException {
      _fail(SupportSourceReadFailure.unsupportedFormat);
    } catch (_) {
      _fail();
    } finally {
      _busy = false;
    }
  }

  _NavSource? _owned(nav.SourceObservation observation) {
    final source = _sources[observation.key];
    return source != null && identical(source.observation, observation)
        ? source
        : null;
  }

  _NavSource _source(nav.SourceObservation observation, nav.FrozenScope scope) {
    _guard();
    final source = _owned(observation);
    if (source == null ||
        source.scope == null ||
        !_scopeWithin(source.scope!, scope)) {
      _fail();
    }
    return source;
  }

  @override
  Future<nav.Page<nav.SourceObservation>> discover(
    nav.SourceDomain domain,
    nav.SourceKey? parent,
    Object? cursor,
    nav.WorkBound bound,
  ) => _run(bound, () async {
    final page = await _discover(domain, parent, cursor, bound);
    _lastDiscovery = List.unmodifiable(page.items);
    return page;
  });
  @override
  Future<nav.SourceObservation?> observe(
    nav.SourceKey key,
    nav.WorkBound bound,
  ) => _run(bound, () => _observe(key, bound));
  @override
  Future<bool> revalidate(
    nav.SourceObservation original,
    nav.WorkBound bound,
  ) async {
    if (_owned(original) == null || !_alive()) return false;
    try {
      return await _run(bound, () async => _owned(original) != null);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<nav.Page<nav.SectionDescriptor>> contents(
    nav.SourceObservation source,
    nav.FrozenScope scope,
    nav.Selection? section,
    Object? cursor,
    nav.WorkBound bound,
  ) => _run(
    bound,
    () => _contents(_source(source, scope), scope, section, cursor, bound),
  );
  @override
  Future<nav.Page<nav.DataRecord>> search(
    nav.SourceObservation source,
    nav.FrozenScope scope,
    String literal,
    nav.Selection? section,
    Object? cursor,
    nav.WorkBound bound,
  ) => _run(
    bound,
    () =>
        _search(_source(source, scope), scope, literal, section, cursor, bound),
  );
  @override
  Future<nav.Page<nav.DataRecord>> read(
    nav.SourceObservation source,
    nav.FrozenScope scope,
    nav.ReadQuery query,
    nav.WorkBound bound,
  ) => _run(bound, () => _read(_source(source, scope), scope, query, bound));
}

/// One joined native operation, not a memoization window around a callback.
/// All observations share this repo's exact global fence; no per-source SQL is
/// hidden in the loop. The ordinary revalidate API remains independently fresh.
final class _NavRootRevalidation implements nav.OriginalRootRevalidation {
  _NavRootRevalidation(this.repository, this._checkpoint);
  @override
  final SupportSourceNavigationRepo repository;
  final void Function() _checkpoint;
  bool _active = true, _used = false;
  bool _running = false;
  List<nav.SourceObservation> _originals = const [];

  void _check() {
    _checkpoint();
    repository._guard();
    if (!_active ||
        !identical(repository._rootValidation, this) ||
        _originals.any((o) => repository._owned(o) == null)) {
      repository._fail();
    }
  }

  @override
  bool get isCurrent =>
      _active &&
      !_used &&
      identical(repository._rootValidation, this) &&
      repository._alive();

  @override
  Future<bool> revalidate(
    List<nav.SourceObservation> originals,
    nav.WorkBound bound,
  ) async {
    if (!isCurrent ||
        originals.isEmpty ||
        originals.length > nav.Limits.references) {
      return false;
    }
    _used = true;
    _running = true;
    _originals = List.unmodifiable(originals);
    try {
      _check();
      final valid = await repository._run(bound, () async {
        _check();
        return true;
      });
      _check();
      return valid;
    } catch (_) {
      repository._retire();
      return false;
    } finally {
      _active = false;
      _running = false;
      _originals = const [];
    }
  }
}

final class _NavSource {
  _NavSource(this.observation, this.header, this.label, this.scope);
  final nav.SourceObservation observation;
  final Map<String, Object?> header;
  final String? label;
  final nav.FrozenScope? scope;
  final Map<String, _NavCapture> captures = {};
}

final class _NavLease implements nav.SnapshotLease {
  _NavLease(this.repo);
  final SupportSourceNavigationRepo repo;
  @override
  bool isCurrent() => repo._alive();
}

final class _NavCapture {
  _NavCapture(this.raw, this.ids, this.record);
  final Object raw;
  final List<String> ids;
  final nav.DataRecord? record;
}
