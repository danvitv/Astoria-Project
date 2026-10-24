part of '../session_repair_repo.dart';

final class _RepairInspectionReader {
  const _RepairInspectionReader(this.owner);
  final SessionRepairRepo owner;
  AppDatabase get db => owner._db;

  Future<SessionRepairInspection> inspect(
    String target,
    String parent,
    bool Function() current,
  ) async {
    try {
      final result = await _repairTransaction(db, current, () async {
        _repairRequire(
          owner._support.usesDatabase(db),
          SessionRepairIssue.authorityDenied,
        );
        final image = await owner._raw.capture(target, parent, current);
        final global = <SessionRepairIssue>[];
        global.addAll(sessionMetadataIssues(image));
        Set<String>? messageIds;
        try {
          messageIds = messages(image).map((m) => m.id).toSet();
        } on _RepairRefused catch (e) {
          global.add(e.issue);
        }
        final effectIssues = <String, List<SessionRepairIssue>>{};
        final reconciliation = await validateReconciliation(
          image,
          current,
          perEffect: effectIssues,
        );
        global.addAll(reconciliation);
        final targets = <SessionRepairTarget>[];
        void add(
          TableInfo table,
          Map<String, Object?> row,
          SessionRepairTargetKind kind,
          List<SessionRepairIssue> issues,
          SessionRepairAvailability availability,
        ) {
          if (targets.length >= 64) {
            if (!global.contains(SessionRepairIssue.incompleteInspection))
              global.add(SessionRepairIssue.incompleteInspection);
            return;
          }
          targets.add(
            SessionRepairTarget._(
              owner,
              image,
              image.slices.indexWhere((s) => identical(s.table, table)),
              row,
              kind,
              'sr-${_repairHash([image.stamp, kind.name, row])}',
              List.unmodifiable(issues),
              availability,
              current,
            ),
          );
        }

        for (final row in image.rows(db.cardEvolutionCollectorRuns)) {
          final issues = collectorIssues(image, row);
          SessionRepairAvailability availability =
              SessionRepairAvailability.unavailable;
          if (issues.isEmpty && global.isEmpty) {
            try {
              unusedAttempt(image, row);
              availability = SessionRepairAvailability.deleteUnusedAttempt;
            } on _RepairRefused catch (e) {
              issues.add(e.issue);
            }
          }
          add(
            db.cardEvolutionCollectorRuns,
            row,
            SessionRepairTargetKind.collectorAttempt,
            issues,
            availability,
          );
        }
        for (final row in image.rows(db.cardEvolutionObservations)) {
          final issues = observationIssues(image, row, messageIds);
          issues.add(
            row['status'] == 'promoted' || row['status'] == 'consumed'
                ? SessionRepairIssue.protectedTarget
                : SessionRepairIssue.aggregateOriginalUnavailable,
          );
          add(
            db.cardEvolutionObservations,
            row,
            SessionRepairTargetKind.observation,
            issues,
            SessionRepairAvailability.unavailable,
          );
        }
        final validator = _RepairLedgerValidation(db);
        for (final row in image.rows(db.trackerRows)) {
          final issue = validator.rowIssue(image, row);
          final issues = <SessionRepairIssue>[if (issue != null) issue];
          if ((row['value'] as String).isEmpty ||
              (row['value'] as String).length > 1200)
            issues.add(SessionRepairIssue.invalidValue);
          var available = issue == null && global.isEmpty;
          if (available) {
            try {
              _RepairMutationStore(owner).quietLedgerDependencies(image);
              validator.revision(image);
            } on _RepairRefused catch (e) {
              issues.add(e.issue);
              available = false;
            }
          }
          add(
            db.trackerRows,
            row,
            SessionRepairTargetKind.liveLedger,
            issues,
            available
                ? SessionRepairAvailability.correctExistingValue
                : SessionRepairAvailability.unavailable,
          );
        }
        for (final row in image.rows(db.ledgerReconciliationSuccessfulRuns)) {
          add(
            db.ledgerReconciliationSuccessfulRuns,
            row,
            SessionRepairTargetKind.reconciliation,
            [
              SessionRepairIssue.protectedTarget,
              ...?effectIssues[row['id']],
              if (reconciliation.contains(SessionRepairIssue.invalidChain))
                SessionRepairIssue.invalidChain,
            ],
            SessionRepairAvailability.unavailable,
          );
        }
        _repairRequire(await owner._raw.matches(image, current));
        return SessionRepairInspection._(
          List.unmodifiable(targets),
          List.unmodifiable(global),
          !global.contains(SessionRepairIssue.incompleteInspection),
        );
      });
      return result!;
    } on _RepairRefused catch (e) {
      return SessionRepairInspection._(const [], [e.issue], false);
    } on SessionRepairStorageException {
      return const SessionRepairInspection._([], [
        SessionRepairIssue.incompleteInspection,
      ], false);
    }
  }

  List<ChatMessage> messages(_RepairImage image) {
    try {
      final value = jsonDecode(
        image.rows(db.chatSessions).single['messages_json'] as String,
      );
      _repairRequire(value is List, SessionRepairIssue.invalidShape);
      final messages = <ChatMessage>[];
      for (final item in value as List) {
        _repairRequire(
          item is Map<String, dynamic> &&
              item['id'] is String &&
              (item['id'] as String).isNotEmpty &&
              item['role'] is String &&
              item['content'] is String,
          SessionRepairIssue.invalidShape,
        );
        messages.add(ChatMessage.fromJson(item as Map<String, dynamic>));
      }
      _repairRequire(
        messages.map((m) => m.id).toSet().length == messages.length,
        SessionRepairIssue.invalidShape,
      );
      return messages;
    } on _RepairRefused {
      rethrow;
    } catch (_) {
      throw const _RepairRefused(SessionRepairIssue.malformedPayload);
    }
  }

  List<SessionRepairIssue> sessionMetadataIssues(_RepairImage image) {
    final issues = <SessionRepairIssue>[];
    final row = image.rows(db.chatSessions).single;
    if (image.rows(db.characters).length != 1)
      issues.add(SessionRepairIssue.missingReference);
    if ((row['session_index'] as int) < 0 || (row['updated_at'] as int) < 0)
      issues.add(SessionRepairIssue.invalidShape);
    for (final field in [
      'session_vars_json',
      'authors_note_json',
      'last_scroll_anchor_json',
    ]) {
      if (row[field] == null) continue;
      try {
        if (jsonDecode(row[field] as String) is! Map<String, dynamic>)
          issues.add(SessionRepairIssue.invalidShape);
      } catch (_) {
        issues.add(SessionRepairIssue.malformedPayload);
      }
    }
    final checkpoints = image.rows(db.sessionCanonCheckpointRows).toList()
      ..sort((a, b) => (a['sequence'] as int).compareTo(b['sequence'] as int));
    String parent = '';
    for (var i = 0; i < checkpoints.length; i++) {
      final point = checkpoints[i];
      if (point['sequence'] != i || point['parent_checkpoint_id'] != parent)
        issues.add(SessionRepairIssue.invalidChain);
      if (!image
          .rows(db.characterRevisionRows)
          .any(
            (r) =>
                r['character_id'] == point['character_id'] &&
                r['revision'] == point['character_revision'] &&
                r['revision_hash'] == point['character_revision_hash'],
          ))
        issues.add(SessionRepairIssue.missingReference);
      parent = point['id'] as String;
    }
    if (image
        .rows(db.sessionLorebookRevisionRows)
        .any((r) => !checkpoints.any((p) => p['id'] == r['checkpoint_id'])))
      issues.add(SessionRepairIssue.missingReference);
    return issues.toSet().toList();
  }

  List<String> strings(Object? raw) {
    try {
      final value = jsonDecode(raw as String);
      _repairRequire(
        value is List && value.every((e) => e is String && e.isNotEmpty),
        SessionRepairIssue.invalidShape,
      );
      final result = (value as List).cast<String>();
      _repairRequire(
        result.toSet().length == result.length,
        SessionRepairIssue.invalidShape,
      );
      return result;
    } on _RepairRefused {
      rethrow;
    } catch (_) {
      throw const _RepairRefused(SessionRepairIssue.malformedPayload);
    }
  }

  List<SessionRepairIssue> observationIssues(
    _RepairImage image,
    Map<String, Object?> row,
    Set<String>? messageIds,
  ) {
    final issues = <SessionRepairIssue>[];
    void capture(void Function() work) {
      try {
        work();
      } on _RepairRefused catch (e) {
        if (!issues.contains(e.issue)) issues.add(e.issue);
      } catch (_) {
        issues.add(SessionRepairIssue.malformedPayload);
      }
    }

    if (!const {
      'active',
      'expired',
      'promoted',
      'consumed',
    }.contains(row['status']))
      issues.add(SessionRepairIssue.unknownStatus);
    if (row['character_id'] !=
        image.rows(db.chatSessions).single['character_id'])
      issues.add(SessionRepairIssue.missingReference);
    capture(() {
      final evidence = strings(row['evidence_message_ids']);
      _repairRequire(
        evidence.isNotEmpty,
        SessionRepairIssue.incompleteEvidence,
      );
      _repairRequire(
        messageIds != null && evidence.every(messageIds.contains),
        SessionRepairIssue.missingReference,
      );
      final decoded = jsonDecode(row['evidence_clusters_json'] as String);
      _repairRequire(decoded is List, SessionRepairIssue.invalidShape);
      final union = <String>{};
      for (final cluster in decoded as List) {
        final ids = strings(jsonEncode(cluster));
        _repairRequire(
          ids.isNotEmpty && ids.every(union.add),
          SessionRepairIssue.invalidShape,
        );
      }
      _repairRequire(
        union.length == evidence.length &&
            union.containsAll(evidence) &&
            (decoded as List).length == row['repeat_count'],
        SessionRepairIssue.incompleteEvidence,
      );
    });
    capture(() {
      final keys = strings(row['retrieval_keys_json']);
      final trackers = image.rows(db.trackerRows);
      _repairRequire(
        keys.every((key) => trackers.any((r) => r['name'] == key)),
        SessionRepairIssue.missingReference,
      );
      _repairRequire(
        row['target_kind'] == 'main_character_card' ||
            row['target_kind'] == 'injected_lorebook_entry',
        SessionRepairIssue.invalidShape,
      );
      if (row['target_kind'] == 'injected_lorebook_entry')
        throw const _RepairRefused(SessionRepairIssue.incompleteEvidence);
    });
    final runs = image.rows(db.cardEvolutionCollectorRuns);
    for (final key in ['run_ordinal', 'first_seen_run', 'last_confirmed_run']) {
      if (row[key] != null &&
          !runs.any(
            (r) =>
                r['collector_ordinal'] == row[key] &&
                r['status'] == 'completed',
          ))
        issues.add(SessionRepairIssue.missingReference);
    }
    return issues;
  }

  List<SessionRepairIssue> collectorIssues(
    _RepairImage image,
    Map<String, Object?> row,
  ) {
    final issues = <SessionRepairIssue>[];
    if (!const {'claimed', 'completed', 'failed'}.contains(row['status']))
      issues.add(SessionRepairIssue.unknownStatus);
    if (row['character_id'] !=
        image.rows(db.chatSessions).single['character_id'])
      issues.add(SessionRepairIssue.missingReference);
    final refs = image
        .rows(db.ledgerReconciliationSuccessfulRuns)
        .where((r) => r['id'] == row['reconciliation_run_id'])
        .toList();
    if (refs.length != 1 ||
        refs.single['ordinal'] != row['reconciliation_run_ordinal'] ||
        refs.single['chain_hash'] != row['reconciliation_chain_hash'])
      issues.add(SessionRepairIssue.missingReference);
    final ordinal = row['reconciliation_run_ordinal'] as int;
    final batch =
        image
            .rows(db.ledgerReconciliationSuccessfulRuns)
            .where(
              (r) =>
                  (r['ordinal'] as int) > ordinal - 3 &&
                  (r['ordinal'] as int) <= ordinal,
            )
            .toList()
          ..sort(
            (a, b) => (a['ordinal'] as int).compareTo(b['ordinal'] as int),
          );
    if (ordinal <= 0 ||
        ordinal % 3 != 0 ||
        batch.length != 3 ||
        row['range_hash'] !=
            sha256
                .convert(
                  utf8.encode(
                    batch
                        .map((r) => '${r['id']}\u001f${r['range_hash']}')
                        .join('\u001e'),
                  ),
                )
                .toString())
      issues.add(SessionRepairIssue.incompleteEvidence);
    if (row['last_call_id'] != null &&
        !image
            .rows(db.llmCallEventRows)
            .any((r) => r['call_id'] == row['last_call_id']))
      issues.add(SessionRepairIssue.missingReference);
    if (row['last_call_id'] != null &&
        (image
                .rows(db.llmCallEventRows)
                .any(
                  (r) =>
                      r['call_id'] == row['last_call_id'] &&
                      r['truncated'] == 1,
                ) ||
            image
                .rows(db.llmRequestCaptureRows)
                .any(
                  (r) =>
                      r['call_id'] == row['last_call_id'] &&
                      r['truncated'] == 1,
                )))
      issues.add(SessionRepairIssue.truncatedEvidence);
    if (row['status'] == 'failed' &&
        (row['failure_code'] == null ||
            row['failed_at'] == null ||
            row['lease_expires_at'] != 0 ||
            row['completed_at'] != null ||
            row['model_output_hash'] != null))
      issues.add(SessionRepairIssue.invalidShape);
    if (row['status'] == 'completed' &&
        (row['completed_at'] == null || row['model_output_hash'] == null))
      issues.add(SessionRepairIssue.incompleteEvidence);
    return issues;
  }

  void unusedAttempt(_RepairImage image, Map<String, Object?> row) {
    _repairRequire(
      row['status'] == 'failed',
      SessionRepairIssue.protectedTarget,
    );
    _repairRequire(
      collectorIssues(image, row).isEmpty,
      SessionRepairIssue.incompleteEvidence,
    );
    // No per-pass originals exist. Even an unrelated aggregate could conceal
    // prior pass contributions; this initial operation admits only an unused
    // failed attempt in a session with NO stored observations/proposal lane.
    _repairRequire(
      image.rows(db.cardEvolutionObservations).isEmpty,
      SessionRepairIssue.aggregateOriginalUnavailable,
    );
    for (final table in <TableInfo>[
      db.cardEvolutionClaims,
      db.cardEvolutionProposalRuns,
      db.cardEvolutionWriterCalls,
      db.ledgerReconciliationCursors,
      db.rewriteJobs,
      db.rewriteOperations,
    ]) {
      _repairRequire(
        image.rows(table).isEmpty,
        SessionRepairIssue.dependentEffectUnsupported,
      );
    }
    final ordinal = row['collector_ordinal'] as int;
    _repairRequire(
      !image
          .rows(db.cardEvolutionCollectorRuns)
          .any((r) => (r['collector_ordinal'] as int) > ordinal),
      SessionRepairIssue.dependentEffectUnsupported,
    );
  }

  Future<List<SessionRepairIssue>> validateReconciliation(
    _RepairImage image,
    bool Function() current, {
    Map<String, List<SessionRepairIssue>>? perEffect,
  }) async {
    final issues = <SessionRepairIssue>[];
    final repo = LedgerReconciliationRunRepo(db);
    final runIds = image
        .rows(db.ledgerReconciliationSuccessfulRuns)
        .map((r) => r['id'])
        .toSet();
    if (image
        .rows(db.ledgerReconciliationEffects)
        .any((r) => !runIds.contains(r['run_id'])))
      issues.add(SessionRepairIssue.invalidEffect);
    // Raw preflight already bounded all run/effect/manifest/session rows and
    // dynamic column types. Existing owners provide structural chain validation.
    try {
      final chain = await owner._raw.checked(
        current,
        () => repo.validateChain(image.targetSession),
      );
      if (chain is! ReconciliationRunValid)
        issues.add(SessionRepairIssue.invalidChain);
      final audit = await owner._raw.checked(
        current,
        () => repo.readSessionAudit(image.targetSession),
      );
      if (audit.integrity is! ReconciliationRunValid)
        issues.add(SessionRepairIssue.invalidChain);
      final invalid = image
          .rows(db.ledgerReconciliationRunInvalidations)
          .map((r) => r['run_id'])
          .toSet();
      if (audit.logical.length !=
          audit.physical.where((r) => !invalid.contains(r.id)).length)
        issues.add(SessionRepairIssue.incompleteEvidence);
    } on _RepairRefused {
      rethrow;
    } catch (_) {
      issues.add(SessionRepairIssue.malformedPayload);
    }
    for (final row in image.rows(db.ledgerReconciliationSuccessfulRuns)) {
      final found = <SessionRepairIssue>[];
      try {
        final run = LedgerReconciliationSuccessfulRunRow.fromJson({
          for (final c in db.ledgerReconciliationSuccessfulRuns.$columns)
            c.name.replaceAllMapped(
              RegExp(r'_([a-z])'),
              (m) => m[1]!.toUpperCase(),
            ): row[c.name],
        });
        final effect = await owner._raw.checked(
          current,
          () => repo.validateEffect(run),
        );
        if (effect is! ReconciliationEffectValid) {
          found.add(SessionRepairIssue.invalidEffect);
        } else {
          ReconciliationStateCodec.decode(
            sessionId: image.targetSession,
            ledgerJson: effect.before.ledgerJson,
            knowledgeJson: effect.before.knowledgeJson,
          );
          ReconciliationStateCodec.decode(
            sessionId: image.targetSession,
            ledgerJson: effect.after.ledgerJson,
            knowledgeJson: effect.after.knowledgeJson,
          );
        }
      } on _RepairRefused {
        rethrow;
      } catch (_) {
        found.add(SessionRepairIssue.malformedPayload);
      }
      if (perEffect != null)
        perEffect[row['id'] as String] = List.unmodifiable(found);
      issues.addAll(found);
    }
    return issues.toSet().toList();
  }
}
