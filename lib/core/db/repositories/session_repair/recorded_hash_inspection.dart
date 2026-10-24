part of '../session_repair_repo.dart';

enum SessionRecordedHashIssue {
  invalidHash,
  invalidSchema,
  invalidReferences,
  invalidChain,
  unknown,
}

/// Counts and fixed verdicts only; computed/recorded digests never leave custody.
final class SessionRecordedHashInspection {
  const SessionRecordedHashInspection._(
    this.runs,
    this.effects,
    this.issues, {
    this.truncated = false,
  });
  final int runs, effects;
  final List<SessionRecordedHashIssue> issues;
  final bool truncated;
  Map<String, Object?> toMetadata() => {
    'runsChecked': runs,
    'effectsChecked': effects,
    'issues': issues.map((i) => i.name).toList(),
    'complete': !issues.contains(SessionRecordedHashIssue.unknown),
    'truncated': truncated,
    'coverage': 'recorded_reconciliation_hashes',
    'unhashedStores': 'structural_notChecked',
    'narrativeTruth': 'notChecked',
  };
}

final class _RepairRecordedHashReader {
  const _RepairRecordedHashReader(this.owner);
  final SessionRepairRepo owner;
  AppDatabase get db => owner._db;

  Future<SessionRecordedHashInspection> inspect(
    String session,
    String parent,
    bool Function() current,
  ) async {
    try {
      final result = await _repairTransaction(db, current, () async {
        _repairRequire(owner._support.usesDatabase(db));
        final image = await owner._raw.capture(session, parent, current);
        final repo = LedgerReconciliationRunRepo(db);
        final issues = <SessionRecordedHashIssue>{};
        var runs = 0, effects = 0;
        // Strict hydration happens before invoking tolerant evidence readers.
        try {
          _RepairInspectionReader(owner).messages(image);
        } catch (_) {
          issues.add(SessionRecordedHashIssue.invalidSchema);
        }
        for (final row in image.rows(db.ledgerReconciliationSuccessfulRuns)) {
          _repairRequire(current());
          try {
            final run = decode(row);
            runs++;
            // The established canonical run implementation owns the algorithm.
            if (row['anchors_json'] != run.anchorsJson ||
                row['accepted_manifest_refs_json'] != run.manifestsJson ||
                row['canonical_result_json'] != run.resultJson ||
                row['ops_applied_json'] != run.opsJson) {
              issues.add(SessionRecordedHashIssue.invalidSchema);
            }
            if (row['range_hash'] != run.rangeHash ||
                row['content_hash'] != run.contentHash ||
                row['chain_hash'] != run.chainHash) {
              issues.add(SessionRecordedHashIssue.invalidHash);
            }
            if (row['start_message_id'] != run.start.messageId ||
                row['start_swipe_id'] != run.start.swipeId ||
                row['start_agent_swipe_id'] != run.start.agentSwipeId ||
                row['end_message_id'] != run.end.messageId ||
                row['end_swipe_id'] != run.end.swipeId ||
                row['end_agent_swipe_id'] != run.end.agentSwipeId) {
              issues.add(SessionRecordedHashIssue.invalidReferences);
            }
            final hydrated = LedgerReconciliationSuccessfulRunRow.fromJson({
              for (final c in db.ledgerReconciliationSuccessfulRuns.$columns)
                c.name.replaceAllMapped(
                  RegExp(r'_([a-z])'),
                  (m) => m[1]!.toUpperCase(),
                ): row[c.name],
            });
            final effect = await owner._raw.checked(
              current,
              () => repo.validateEffect(hydrated),
            );
            effects++;
            if (effect is ReconciliationEffectValid) {
              ReconciliationStateCodec.decode(
                sessionId: session,
                ledgerJson: effect.before.ledgerJson,
                knowledgeJson: effect.before.knowledgeJson,
              );
              ReconciliationStateCodec.decode(
                sessionId: session,
                ledgerJson: effect.after.ledgerJson,
                knowledgeJson: effect.after.knowledgeJson,
              );
            } else if (effect is ReconciliationEffectInvalid) {
              // Match only the owner's finite known verdicts; never echo reason.
              issues.add(switch (effect.reason) {
                'effect integrity hashes do not match its state' =>
                  SessionRecordedHashIssue.invalidHash,
                'effect contains malformed state' =>
                  SessionRecordedHashIssue.invalidSchema,
                'exact effect is unavailable' ||
                'effect does not belong to the reconciliation run' =>
                  SessionRecordedHashIssue.invalidReferences,
                _ => SessionRecordedHashIssue.unknown,
              });
            }
          } on _RecordedHashReferenceFailure {
            issues.add(SessionRecordedHashIssue.invalidReferences);
          } on _RepairRefused {
            rethrow;
          } catch (_) {
            issues.add(SessionRecordedHashIssue.invalidSchema);
          }
        }
        final chain = await owner._raw.checked(
          current,
          () => repo.validateChain(session),
        );
        if (chain is! ReconciliationRunValid) {
          issues.add(SessionRecordedHashIssue.invalidChain);
        }
        final audit = await owner._raw.checked(
          current,
          () => repo.readSessionAudit(session),
        );
        final invalid = image
            .rows(db.ledgerReconciliationRunInvalidations)
            .map((r) => r['run_id'])
            .toSet();
        final ids = image
            .rows(db.ledgerReconciliationSuccessfulRuns)
            .map((r) => r['id'])
            .toSet();
        if (!ids.containsAll(invalid) ||
            image
                .rows(db.ledgerReconciliationEffects)
                .any((r) => !ids.contains(r['run_id'])) ||
            (audit.integrity is ReconciliationRunValid &&
                audit.logical.length !=
                    audit.physical
                        .where((r) => !invalid.contains(r.id))
                        .length)) {
          issues.add(SessionRecordedHashIssue.invalidReferences);
        }
        _repairRequire(await owner._raw.matches(image, current));
        return SessionRecordedHashInspection._(
          runs,
          effects,
          List.unmodifiable(issues),
        );
      });
      return result!;
    } on _RepairRefused catch (e) {
      return SessionRecordedHashInspection._(
        0,
        0,
        [
          e.issue == SessionRepairIssue.invalidShape
              ? SessionRecordedHashIssue.invalidSchema
              : SessionRecordedHashIssue.unknown,
        ],
        truncated:
            e.issue == SessionRepairIssue.oversized ||
            e.issue == SessionRepairIssue.incompleteInspection,
      );
    } on SessionRepairStorageException {
      return const SessionRecordedHashInspection._(0, 0, [
        SessionRecordedHashIssue.unknown,
      ]);
    }
  }

  LedgerReconciliationRun decode(Map<String, Object?> row) {
    List<Map<String, dynamic>> list(String field, Set<String> keys) {
      final value = jsonDecode(row[field] as String);
      if (value is! List) throw const FormatException();
      return value.map((v) {
        if (v is! Map<String, dynamic> ||
            v.length != keys.length ||
            !keys.every(v.containsKey))
          throw const FormatException();
        return v;
      }).toList();
    }

    String text(Object? value) {
      if (value is! String || value.isEmpty) throw const FormatException();
      return value;
    }

    int ordinal(Object? value) {
      if (value is! int || value < 0) throw const FormatException();
      return value;
    }

    final anchors =
        list('anchors_json', const {
              'messageId',
              'swipeId',
              'agentSwipeId',
              'role',
              'contentHash',
            })
            .map(
              (v) => ReconciliationAnchor(
                messageId: text(v['messageId']),
                swipeId: ordinal(v['swipeId']),
                agentSwipeId: ordinal(v['agentSwipeId']),
                role: text(v['role']),
                contentHash: text(v['contentHash']),
              ),
            )
            .toList();
    final refs =
        list('accepted_manifest_refs_json', const {
              'acceptanceId',
              'sessionId',
              'messageId',
              'swipeId',
              'agentSwipeId',
              'manifestHash',
              'acceptedByUserMessageId',
            })
            .map(
              (v) => AcceptedManifestRef(
                acceptanceId: text(v['acceptanceId']),
                sessionId: text(v['sessionId']),
                messageId: text(v['messageId']),
                swipeId: ordinal(v['swipeId']),
                agentSwipeId: ordinal(v['agentSwipeId']),
                manifestHash: text(v['manifestHash']),
                acceptedByUserMessageId: text(v['acceptedByUserMessageId']),
              ),
            )
            .toList();
    final result = jsonDecode(row['canonical_result_json'] as String);
    final ops = jsonDecode(row['ops_applied_json'] as String);
    if (anchors.isEmpty ||
        result is! Map<String, dynamic> ||
        ops is! List ||
        ops.any((v) => v is! String || v.isEmpty) ||
        anchors.any((v) => v.role != 'user' && v.role != 'assistant') ||
        ordinal(row['ordinal']) == 0 ||
        ordinal(row['contract_version']) == 0) {
      throw const FormatException();
    }
    if (refs.any((v) => v.sessionId != row['session_id'])) {
      throw const _RecordedHashReferenceFailure();
    }
    return LedgerReconciliationRun(
      id: text(row['id']),
      sessionId: text(row['session_id']),
      ordinal: row['ordinal'] as int,
      anchors: anchors,
      acceptedManifestRefs: refs,
      effectiveCanonStamp: text(row['effective_canon_stamp']),
      effectiveCanonRevision: ordinal(row['effective_canon_revision']),
      effectiveCanonHash: text(row['effective_canon_hash']),
      canonicalResult: result,
      predecessorChainHash: row['predecessor_chain_hash'] as String,
      contractVersion: row['contract_version'] as int,
      opsApplied: ops.cast<String>(),
      createdAt: ordinal(row['created_at']),
    );
  }
}

final class _RecordedHashReferenceFailure implements Exception {
  const _RecordedHashReferenceFailure();
}
