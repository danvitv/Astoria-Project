part of 'memory_setup_service.dart';

extension _MemorySetupSession on MemorySetupService {
  Map<String, Object?> _sessionFields(MemorySetupAnswers a) => {
    'enabled': true,
    'memoryMode': switch (a.profile) {
      MemorySetupProfile.economy => 'fast',
      MemorySetupProfile.balanced => 'balanced',
      MemorySetupProfile.detail => 'deep',
    },
    'maxInjectedEntries': switch (a.profile) {
      MemorySetupProfile.economy => 4,
      MemorySetupProfile.balanced => 7,
      MemorySetupProfile.detail => 10,
    },
    'maxInjectedTokens': a.tokens,
    'memoryPackingMode': 'hybrid',
    'memoryExcerptingEnabled': true,
    'keyMatchMode': 'both',
    'vectorSearchEnabled': a.semantic,
  };

  Future<MemorySetupReview?> _prepareSession(MemorySetupAnswers a) async {
    final checkpoint = _checkpoint, intent = ++_intent;
    final ticket = books.captureSetupTicket();
    bool source() => _sourceCurrent(checkpoint) && ticket.current;
    if (!source() ||
        !const [1024, 2048, 4096].contains(a.tokens) ||
        !await _fresh() ||
        !source())
      return null;
    final session = await chats.getById(_targetId!);
    if (!source() || session == null || intent != _intent)
      return null;
    final observed = await books.observeForControl(_targetId!);
    if (!source() || intent != _intent) return null;
    if (observed == null) {
      final exists = await books.existsForSetup(_targetId!);
      if (!source() || exists || intent != _intent)
        return null;
    }
    final proposed = _sessionFields(a);
    final before = books.setupFieldSnapshot(observed, proposed.keys);
    final fields = <String, Object?>{};
    for (final e in proposed.entries) {
      final old = before[e.key]! as Map;
      if (old['present'] != true || old['value'] != e.value)
        fields[e.key] = e.value;
    }
    if (fields.isEmpty) return null;
    final safeBefore = books.setupFieldSnapshot(observed, fields.keys);
    final after = {
      for (final e in fields.entries)
        e.key: <String, Object?>{'present': true, 'value': e.value},
    };
    final beforePlan = <String, Object?>{
      'session': _targetId,
      'bookExists': observed != null,
      'settings': safeBefore,
    };
    final afterPlan = <String, Object?>{
      'session': _targetId,
      'bookExists': true,
      'settings': after,
      if (observed == null)
        'creationSettings': {
          ...const MemoryBookSettings(
            autoCreateEnabled: false,
            autoGenerateEnabled: false,
            vectorSearchEnabled: false,
            consolidationEnabled: false,
          ).toJson(),
          ...fields,
        },
    };
    if (_evidence(beforePlan) == null || _evidence(afterPlan) == null)
      return null;
    return MemorySetupReview._(
      this,
      intent,
      MemorySetupScope.session,
      beforePlan,
      afterPlan,
      checkpoint,
      observed: observed,
      fields: fields,
      bookTicket: ticket,
    );
  }

  SupportMutationRecord? _record(MemorySetupReview r) {
    final before = _evidence(r.before), after = _evidence(r.after);
    if (before == null || after == null) return null;
    final id =
        'memory-setup-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}';
    return SupportMutationRecord(
      id: id,
      sessionId: _session,
      domain: 'memory_setup',
      targetId: r.scope.name,
      beforeJson: before,
      afterJson: after,
      status: 'pending',
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  }

  Future<MemorySetupResult> _applySession(
    MemorySetupReview r,
    int intent,
  ) async {
    bool live() => _intent == intent && _sourceCurrent(r._checkpoint) && r._bookTicket?.current == true;
    final undo = r._undo;
    if (undo != null) undo._used = true;
    if (!live() || !await _fresh() || !live()) return MemorySetupResult.refused;
    final record = undo == null ? _record(r) : null;
    if (undo == null && record == null) return MemorySetupResult.refused;
    // Own checkpoint is issued before ALL observers. Do not reread/adopt theirs.
    final admission = sources.beginObservedMutation(sessionId: _targetId!);
    final own = admission.checkpoint;
    final owner = _target!;
    final publication = owner.queue.beginPublication();
    bool admitted() => _intent == intent && _sourceCurrent(own, admitted: true);
    MemoryBookSetupCommit? committed;
    SupportMutationReservation? undone;
    var invoked = false, refreshPending = false;
    try {
      await owner.queue.run(() async {
        if (!admitted() || r._bookTicket?.current != true) return;
        invoked = true;
        if (undo == null) {
          committed = await books.applySetup(
            sessionId: _targetId!,
            expected: r.observed,
            fields: r._fields,
            journal: journal,
            record: record!,
            isCurrent: admitted,
            ticket: r._bookTicket!,
          );
        } else {
          undone = await books.undoSetup(
            receipt: undo._session!,
            expected: r.observed!,
            journal: journal,
            isCurrent: admitted,
            ticket: r._bookTicket!,
          );
        }
      });
      if (committed != null || undone != null) {
        _checkpoint = own;
        try {
          onBookChanged(_targetId!);
        } catch (_) {
          refreshPending = true;
        }
        if (admitted() && owner.queue.isCurrentPublication(publication)) {
          refreshPending =
              !await owner.refresh(_targetId!, publication) || refreshPending;
        } else {
          refreshPending = true;
        }
      }
    } catch (_) {
      // An exceptional commit-delivery boundary is not proof of rollback.
      return MemorySetupResult(
        invoked
            ? MemorySetupEffect.reconciliationRequired
            : MemorySetupEffect.refused,
      );
    } finally {
      admission.settle();
    }
    if (committed == null && undone == null) {
      // Consumed source admission never revives earlier approvals or receipts.
      _checkpoint = own;
      return const MemorySetupResult(MemorySetupEffect.conflict);
    }
    return MemorySetupResult(
      undo == null ? MemorySetupEffect.applied : MemorySetupEffect.undone,
      refreshPending: refreshPending,
      receipt: committed == null || committed!.ticket?.current != true
          ? null
          : MemorySetupReceipt._(
              this,
              r.scope,
              r.before,
              r.after,
              own,
              session: committed,
            ),
    );
  }
}
