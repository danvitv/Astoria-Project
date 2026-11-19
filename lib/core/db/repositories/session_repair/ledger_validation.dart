part of '../session_repair_repo.dart';

/// Finite native current-state grammar from StudioLedgerExportParser. This does
/// not run the tolerant model parser (which normalizes/drops fields and logs
/// private rejection text). Inputs are one exact native key plus one String;
/// no export JSON, dropped ops, eval, cleanup, facts or generic mutation verbs.
final class _RepairLedgerValidation {
  const _RepairLedgerValidation(this.db);
  final AppDatabase db;
  static const clockKeys = {'world:time', 'world:date', 'world:day'};
  bool key(String name) {
    if (name.length > 256 ||
        name != name.trim() ||
        name.contains(RegExp(r'[\x00-\x1f]'))) {
      return false;
    }
    if (RegExp(
          r'^world:(location|time|date|day|active_threats|current_conditions)$',
        ).hasMatch(name) ||
        RegExp(
          r'^scene\.(present_entities|absent_backstory_entities|immediate_thread|active_tensions)$',
        ).hasMatch(name)) {
      return true;
    }
    if (RegExp(
          r'^npc:([^.:][^.]*?)\.(relationship_to_user|attitude_to_user|trust_to_user|boundaries|card_overrides|location|current_emotional_residue|current_goal|persistent_condition)$',
        ).hasMatch(name) ||
        RegExp(
          r'^relationship:([^.:][^:]*):([^.:][^.]*?)\.(trust|status|relationship|attitude|boundaries|card_override)$',
        ).hasMatch(name) ||
        RegExp(
          r'^arc:([^.:][^.]*?)\.(status|title|summary|do_not_reopen|card_override)$',
        ).hasMatch(name)) {
      // Focal identity is not derivable without the selected persona owner's
      // explicit contract. Entity-key repairs are currently fail-closed rather
      // than pretending empty focalUserName proves absence of user-owned state.
      return false;
    }
    return false;
  }

  SessionRepairIssue? rowIssue(_RepairImage image, Map<String, Object?> row) {
    final name = row['name'] as String;
    if (row['scope'] != 'ledger' ||
        name.startsWith('canon_') ||
        name.startsWith('__')) {
      return SessionRepairIssue.protectedTarget;
    }
    if (!key(name)) return SessionRepairIssue.unsupportedTarget;
    final rows = image.rows(db.trackerRows);
    if (rows.any(
      (r) =>
          r['name'] == 'canon_lock:$name' &&
          (r['value'] != 'false' ||
              r['scope'] != 'ledger' ||
              (r['provenance'] as String).isEmpty ||
              (r['updated_at'] as int) < 0),
    )) {
      return SessionRepairIssue.lockedTarget;
    }
    if (rows.any((r) => r['name'] == 'canon_override:$name')) {
      return SessionRepairIssue.protectedTarget;
    }
    final rev = row['basis_revision'] as int;
    final hash = row['basis_revision_hash'] as String;
    if (rev < 0 ||
        (rev == 0 ? hash.isNotEmpty : hash.isEmpty) ||
        (row['updated_at'] as int) < 0 ||
        (row['provenance'] as String).isEmpty) {
      return SessionRepairIssue.invalidShape;
    }
    if (rev > 0 &&
        !image
            .rows(db.characterRevisionRows)
            .any((r) => r['revision'] == rev && r['revision_hash'] == hash)) {
      return SessionRepairIssue.missingReference;
    }
    final provenanceIssue = provenance(image, row);
    if (provenanceIssue != null) return provenanceIssue;
    return null;
  }

  SessionRepairIssue? provenance(_RepairImage image, Map<String, Object?> row) {
    final raw = row['provenance'] as String;
    if (raw == 'manual_session_repair') return null;
    if (raw == 'game_time_seed') {
      return clockKeys.contains(row['name'])
          ? null
          : SessionRepairIssue.invalidShape;
    }
    // Actual LedgerOpApplier/buildLedgerProvenance tuple. Unknown legacy formats
    // are not guessed into ownership, nor is private evidence prose returned.
    final match = RegExp(
      r'^source=studio_ledger\|message=([^|]+)\|swipe=(\d+)\|agentSwipe=(\d+)(?:\|evidence=([\s\S]*))?$',
    ).firstMatch(raw);
    if (match == null) return SessionRepairIssue.incompleteEvidence;
    try {
      final decoded = _repairMessagePayloads(image, db);
      if (decoded.any((m) => m is! Map<String, dynamic>)) {
        return SessionRepairIssue.malformedPayload;
      }
      final found = decoded
          .where((m) => (m as Map<String, dynamic>)['id'] == match[1])
          .toList();
      if (found.length != 1) return SessionRepairIssue.missingReference;
      final message = ChatMessage.fromJson(
        found.single as Map<String, dynamic>,
      );
      if ('${message.swipeId}' != match[2] ||
          '${message.agentSwipeId}' != match[3]) {
        return SessionRepairIssue.missingReference;
      }
      return null;
    } catch (_) {
      return SessionRepairIssue.malformedPayload;
    }
  }

  int revision(_RepairImage image) {
    final rows = image
        .rows(db.trackerRows)
        .where((r) => r['name'] == TrackerRepo.ledgerManualMutationRevisionName)
        .toList();
    if (rows.isEmpty) return 0;
    _repairRequire(rows.length == 1, SessionRepairIssue.invalidShape);
    final row = rows.single;
    final raw = row['value'] as String;
    final value = int.tryParse(raw);
    _repairRequire(
      row['scope'] == 'system' &&
          row['provenance'] == 'manual_ledger_mutation' &&
          value != null &&
          value >= 0 &&
          value < 9007199254740991 &&
          '$value' == raw &&
          row['basis_revision'] == 0 &&
          row['basis_revision_hash'] == '',
      SessionRepairIssue.invalidShape,
    );
    return value!;
  }

  void validate(_RepairImage image, Map<String, Object?> row, String value) {
    final issue = rowIssue(image, row);
    _repairRequire(issue == null, issue ?? SessionRepairIssue.invalidValue);
    _repairRequire(
      value.isNotEmpty &&
          value == value.trim() &&
          value.length <= 1200 &&
          !value.contains(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]')) &&
          value != row['value'],
      SessionRepairIssue.invalidValue,
    );
    final name = row['name'] as String;
    if (!clockKeys.contains(name)) return;
    final values = <String, String>{};
    for (final key in clockKeys) {
      final found = image
          .rows(db.trackerRows)
          .where((r) => r['name'] == key)
          .toList();
      _repairRequire(
        found.length == 1 && rowIssue(image, found.single) == null,
        SessionRepairIssue.incompleteEvidence,
      );
      values[key] = found.single['value'] as String;
    }
    GameTimeState parse(Map<String, String> v) => GameTimeState.parse(
      time: v['world:time']!,
      date: v['world:date']!,
      day: v['world:day']!,
    );
    bool canonical(GameTimeState c, Map<String, String> v) =>
        c.format() != null &&
        c.time == v['world:time'] &&
        c.date == v['world:date'] &&
        '${c.day}' == v['world:day'];
    final old = parse(values);
    _repairRequire(
      canonical(old, values),
      SessionRepairIssue.incompleteEvidence,
    );
    final proposed = {...values, name: value};
    final next = parse(proposed);
    _repairRequire(canonical(next, proposed), SessionRepairIssue.invalidValue);
    DateTime date(String v) {
      final p = v.split('.').map(int.parse).toList();
      return DateTime.utc(p[2], p[1], p[0]);
    }

    int minutes(String v) {
      final p = v.split(':').map(int.parse).toList();
      return p[0] * 60 + p[1];
    }

    final delta = next.day! - old.day!;
    _repairRequire(
      delta >= 0 &&
          date(next.date!).difference(date(old.date!)).inDays == delta &&
          minutes(next.time!) - minutes(old.time!) + delta * 1440 >= 0,
      SessionRepairIssue.invalidValue,
    );
  }
}
