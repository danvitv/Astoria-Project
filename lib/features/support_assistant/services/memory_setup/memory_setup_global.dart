part of 'memory_setup_service.dart';

extension _MemorySetupGlobals on MemorySetupService {
  Future<List<MemorySetupConnection>> _savedConnections() async {
    if (!current || _target == null || !await _fresh()) return const [];
    final revision = connections.revision;
    final rows = await loadConnectionMetadata(() => current);
    if (!current || !connections.isStable || connections.revision != revision)
      return const [];
    _metadata = List.unmodifiable(rows);
    // Original native saved config + protected credential metadata, not a key
    // pasted into a wizard answer. Purpose admission remains the real generator's.
    return List.unmodifiable([
      MemorySetupConnection._(
        this,
        '',
        'Текущее подключение (без смены активного)',
      ),
      for (final row in rows)
        if (row.mode != 'embedding' &&
            _safeText(row.connectionId) != null &&
            _safeText(row.displayName) != null &&
            _safeText(row.model) != null)
          MemorySetupConnection._(
            this,
            row.connectionId,
            '${row.displayName} · ${row.model} · ${row.llmCredential.configured ? "ключ сохранён" : "ключ не настроен"} (не проверено)',
          ),
    ]);
  }

  Map<String, dynamic>? _rawDocument(String? raw, MemorySetupScope scope) {
    try {
      final root = raw == null
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(raw) as Map);
      if (scope == MemorySetupScope.draftConnection &&
          raw != null &&
          !root.containsKey('studioAgent'))
        return null;
      // Legacy flat pipeline needs a real migration owner; never normalize it here.
      if (scope == MemorySetupScope.draftConnection &&
          root['memoryBookApi'] != null &&
          root['memoryBookApi'] is! Map)
        return null;
      return root;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _slot(
    Map<String, dynamic> root,
    MemorySetupScope scope,
  ) => scope == MemorySetupScope.automation
      ? root
      : Map<String, dynamic>.from(root['memoryBookApi'] as Map? ?? const {});

  Map<String, Object?> _snapshot(
    Map<String, dynamic> slot,
    Iterable<String> keys,
  ) => {
    for (final k in keys)
      k: <String, Object?>{
        'present': slot.containsKey(k),
        if (slot.containsKey(k)) 'value': slot[k],
      },
  };

  Future<MemorySetupReview?> _prepareGlobal(
    MemorySetupAnswers a,
    MemorySetupScope scope,
  ) async {
    final prefs = preferences, checkpoint = _checkpoint, intent = ++_intent;
    if (prefs == null || !_sourceCurrent(checkpoint) || !prefs.store.current)
      return null;
    final key = scope == MemorySetupScope.automation
        ? 'memorySettings'
        : 'pipelineSettings';
    final lease = prefs.store.owner.capture([key], store: prefs.store);
    final raw = prefs.getString(key);
    if (!lease.current ||
        !await _fresh() ||
        !_sourceCurrent(checkpoint) ||
        !lease.current ||
        intent != _intent ||
        prefs.getString(key) != raw)
      return null;
    final root = _rawDocument(raw, scope);
    if (root == null) return null;
    final slot = _slot(root, scope);
    final Map<String, Object?> proposed;
    if (scope == MemorySetupScope.automation) {
      proposed = {
        'autoCreateEnabled': a.automation != MemorySetupAutomation.manual,
        'autoGenerateEnabled': a.automation == MemorySetupAutomation.llmDrafts,
        'vectorSearchEnabled': a.semantic,
      };
    } else {
      final choice = a.connection;
      if (choice == null || !identical(choice._service, this)) return null;
      if (choice._id.isNotEmpty &&
          !_metadata.any(
            (m) => m.connectionId == choice._id && m.mode != 'embedding',
          ))
        return null;
      proposed = {
        'generationSource': 'current',
        'apiConfigId': choice._id,
        'generationModel': '',
      };
    }
    final changed = <String, Object?>{};
    for (final e in proposed.entries) {
      if (!slot.containsKey(e.key) || slot[e.key] != e.value)
        changed[e.key] = e.value;
    }
    if (changed.isEmpty) return null;
    final before = _snapshot(slot, changed.keys);
    slot.addAll(changed);
    final after = _snapshot(slot, changed.keys);
    if (scope == MemorySetupScope.draftConnection) root['memoryBookApi'] = slot;
    final beforePlan = <String, Object?>{
      'scope': 'global_all_sessions',
      'store': key,
      'fields': before,
    };
    final afterPlan = <String, Object?>{
      'scope': 'global_all_sessions',
      'store': key,
      'fields': after,
    };
    if (_evidence(beforePlan) == null || _evidence(afterPlan) == null)
      return null;
    final global = _MemorySetupGlobal(
      key,
      raw,
      lease,
      before,
      after,
      jsonEncode(root),
    );
    return MemorySetupReview._(
      this,
      intent,
      scope,
      beforePlan,
      afterPlan,
      checkpoint,
      global: global,
    );
  }

  Future<MemorySetupResult> _applyGlobal(
    MemorySetupReview r,
    int intent,
  ) async {
    bool live() => _intent == intent && _sourceCurrent(r._checkpoint);
    final g = r._global!, prefs = preferences!, undo = r._undo;
    if (undo != null) undo._used = true;
    if (!live() ||
        !g.lease.current ||
        !await _fresh() ||
        !live() ||
        !g.lease.current ||
        prefs.getString(g.key) != g.raw) {
      return MemorySetupResult.refused;
    }
    String next = g.nextRaw;
    if (undo != null) {
      final root = _rawDocument(g.raw, r.scope);
      if (root == null) return MemorySetupResult.refused;
      final slot = _slot(root, r.scope);
      if (jsonEncode(_snapshot(slot, g.after.keys)) != jsonEncode(g.after))
        return MemorySetupResult.refused;
      for (final e in g.before.entries) {
        final old = e.value! as Map;
        if (old['present'] == true) {
          slot[e.key] = old['value'];
        } else {
          slot.remove(e.key);
        }
      }
      if (r.scope == MemorySetupScope.draftConnection)
        root['memoryBookApi'] = slot;
      next = jsonEncode(root);
    }
    SupportMutationReservation? reserved;
    try {
      if (undo == null) {
        final record = _record(r);
        if (record == null) return MemorySetupResult.refused;
        reserved = await journal.reserveMutation(
          record: record,
          isCurrent: () => live() && g.lease.current,
        );
      } else {
        reserved = await journal.reserveMutationUndo(
          expected: undo._journal!,
          isCurrent: () => live() && g.lease.current,
        );
      }
    } catch (_) {
      return const MemorySetupResult(MemorySetupEffect.reconciliationRequired);
    }
    if (reserved == null) return MemorySetupResult.refused;
    ({bool started, bool accepted, SavedPreferencesLease? receipt}) write;
    var verified = false;
    try {
      write = await prefs.compareAndSetString(
        key: g.key,
        expectedRaw: g.raw,
        value: next,
        expected: g.lease,
        isCurrent: live,
      );
      verified =
          write.accepted &&
          write.receipt?.current == true &&
          live() &&
          prefs.getString(g.key) == next;
    } catch (_) {
      // Unexpected acknowledgement/read delivery is still not no-effect proof.
      write = (started: true, accepted: false, receipt: null);
      prefs.store.owner.acknowledge(prefs.store, g.key, false);
    }
    var refreshPending = false;
    if (verified) {
      try {
        refreshPending = !(r.scope == MemorySetupScope.automation
            ? publishMemory(next, write.receipt!)
            : publishPipeline(next, write.receipt!));
      } catch (_) {
        refreshPending = true;
      }
    }
    SupportMutationReservation? settled;
    try {
      settled = await journal.settleMutation(
        expected: reserved,
        fact: verified
            ? (undo == null
                  ? SupportMutationFact.applied
                  : SupportMutationFact.undone)
            : write.started
            ? SupportMutationFact.reconciliationRequired
            : undo == null
            ? SupportMutationFact.failed
            : SupportMutationFact.undoConflict,
        hasOriginalDbCustody: dbCurrent,
      );
    } catch (_) {
      /* Original persisted effect is not rolled back by SQL failure. */
    }
    // The journal await is another retirement boundary. Its completion cannot
    // renew an earlier plugin acknowledgement or issue Undo on a stale lease.
    var finalProof = false;
    try {
      finalProof = verified &&
          write.receipt?.current == true &&
          live() &&
          prefs.getString(g.key) == next;
    } catch (_) {
      /* Lost original observation remains uncertain, never a fresh lookup. */
    }
    // Preferences + SQLite journal are NOT atomic; no unsafe compensation.
    if (write.started && (!finalProof || settled == null)) {
      return const MemorySetupResult(MemorySetupEffect.reconciliationRequired);
    }
    if (!verified) return const MemorySetupResult(MemorySetupEffect.conflict);
    return MemorySetupResult(
      undo == null ? MemorySetupEffect.applied : MemorySetupEffect.undone,
      refreshPending: refreshPending,
      receipt: undo != null || settled == null
          ? null
          : MemorySetupReceipt._(
              this,
              r.scope,
              r.before,
              r.after,
              r._checkpoint,
              journal: settled,
              global: _MemorySetupGlobal(
                g.key,
                next,
                write.receipt!,
                g.before,
                g.after,
                next,
              ),
            ),
    );
  }
}
