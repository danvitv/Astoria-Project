part of '../support_repo.dart';

/// Pure read-only transactions. Filter before selecting primitive metadata;
/// never select evidence/body/cards or silently skip malformed selected rows.
final class _SupportMutationHistoryReader {
  const _SupportMutationHistoryReader(this.db, this.checks);
  final AppDatabase db;
  final _SupportMutationChecks checks;

  bool sameObservation(
    SupportMutationReservation a,
    SupportMutationReservation b,
  ) =>
      identical(a._db, db) &&
      identical(b._db, db) &&
      a._row == b._row &&
      checks.originalParent(a._parent, b._parent);

  Future<List<SupportMutationHistoryMetadata>> _query(
    _SupportHistoryFilter filter,
    bool Function() current, {
    SupportMutationHistoryMetadata? before,
    String? exactId,
    int limit = SupportMutationHistoryPage.pageSize + 1,
  }) async {
    final rows = await checks.checked(
      current,
      () => db
          .customSelect(
            'SELECT id, session_id, domain, target_id, status, created_at, '
            'typeof(id) AS id_type, typeof(session_id) AS session_type, '
            'typeof(domain) AS domain_type, typeof(target_id) AS target_type, '
            'typeof(status) AS status_type, typeof(created_at) AS time_type '
            'FROM support_mutation_journal '
            'WHERE session_id = ? AND domain = ? AND target_id = ? '
            '${exactId == null ? '' : 'AND id = ? '}'
            '${before == null ? '' : 'AND (created_at < ? OR (created_at = ? AND id < ?)) '}'
            'ORDER BY created_at DESC, id DESC LIMIT ?',
            variables: [
              Variable<String>(filter.sessionId),
              Variable<String>(filter.domain),
              Variable<String>(filter.targetId),
              if (exactId != null) Variable<String>(exactId),
              if (before != null) ...[
                Variable<int>(before.createdAt),
                Variable<int>(before.createdAt),
                Variable<String>(before.id),
              ],
              Variable<int>(limit),
            ],
            readsFrom: {db.supportMutationJournal},
          )
          .get(),
    );
    checks.require(current() && rows.length <= limit);
    final result = <SupportMutationHistoryMetadata>[];
    for (final row in rows) {
      final d = row.data,
          id = d['id'],
          time = d['created_at'],
          status = d['status'];
      checks.require(
        d['id_type'] == 'text' &&
            d['session_type'] == 'text' &&
            d['domain_type'] == 'text' &&
            d['target_type'] == 'text' &&
            d['status_type'] == 'text' &&
            d['time_type'] == 'integer' &&
            id is String &&
            checks.identifier(id) &&
            time is int &&
            checks.time(time) &&
            status is String &&
            status.length <= 128 &&
            d['session_id'] == filter.sessionId &&
            d['domain'] == filter.domain &&
            d['target_id'] == filter.targetId,
      );
      result.add((
        id: id as String,
        createdAt: time as int,
        status: status as String,
      ));
    }
    checks.require(current());
    return result;
  }

  Future<SupportMutationHistoryMetadata?> _newest(
    _SupportHistoryFilter filter,
    bool Function() current,
  ) async {
    final rows = await _query(filter, current, limit: 1);
    checks.require(current());
    return rows.isEmpty ? null : rows.single;
  }

  Future<void> _cursor(
    SupportMutationHistoryCursor cursor,
    _SupportHistoryFilter filter,
    SupportSessionRow parent,
    bool Function() current,
  ) async {
    checks.require(
      identical(cursor._reader, this) &&
          cursor._filter == filter &&
          checks.originalParent(parent, cursor._parent),
    );
    final boundary = await _query(
      filter,
      current,
      exactId: cursor._boundary.id,
      limit: 1,
    );
    checks.require(
      current() && boundary.length == 1 && boundary.single == cursor._boundary,
    );
    final newest = await _newest(filter, current);
    checks.require(current() && newest == cursor._newest);
  }

  Future<void> _validate(
    SupportMutationHistoryPage page,
    bool Function() current,
  ) async {
    checks.require(identical(page._reader, this));
    final parent = await checks.parent(page._filter.sessionId, current);
    checks.require(current() && parent == page._parent);
    if (page._position != null) {
      await _cursor(page._position, page._filter, parent, current);
      checks.require(current());
    }
    final newest = await _newest(page._filter, current);
    checks.require(current() && newest == page._newest);
    final rows = await _query(
      page._filter,
      current,
      before: page._position?._boundary,
    );
    checks.require(
      current() &&
          rows.length == page._observed.length &&
          List.generate(
            rows.length,
            (i) => rows[i] == page._observed[i],
          ).every((v) => v),
    );
    final latest = await checks.checked(
      current,
      () => checks.sessions.row(parent.id),
    );
    checks.require(current() && latest == parent);
  }

  Future<SupportMutationHistoryPage?> discover(
    String sessionId,
    String domain,
    String targetId,
    bool Function() current,
    SupportMutationHistoryCursor? cursor,
  ) async {
    try {
      checks.require(
        current() && [sessionId, domain, targetId].every(checks.identifier),
      );
      final filter = (sessionId: sessionId, domain: domain, targetId: targetId);
      final page = await checks.checked(
        current,
        () => db.transaction(() async {
          final parent = await checks.parent(sessionId, current);
          checks.require(current());
          if (cursor != null) {
            await _cursor(cursor, filter, parent, current);
            checks.require(current());
          }
          final newest = await _newest(filter, current);
          checks.require(current());
          final rows = await _query(filter, current, before: cursor?._boundary);
          checks.require(current());
          final result = SupportMutationHistoryPage._(
            this,
            filter,
            parent,
            cursor,
            newest,
            rows,
          );
          await _validate(result, current);
          checks.require(current());
          return result;
        }),
      );
      checks.require(current());
      return page;
    } catch (_) {
      return null; // Payload-free explicit unavailability, including DB/AEAD loss.
    }
  }

  Future<bool> validate(
    SupportMutationHistoryPage page,
    bool Function() current,
  ) async {
    try {
      await checks.checked(
        current,
        () => db.transaction(() => _validate(page, current)),
      );
      checks.require(current());
      return true;
    } catch (_) {
      return false;
    }
  }
}
