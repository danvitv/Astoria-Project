part of '../support_source_text_repo.dart';

extension _SourceMetadataReader on SupportSourceTextRepo {
  static const _gameMetadata = '''SELECT s.rowid AS native_identity,
    c.rowid AS parent_identity,
    CASE WHEN typeof(s.session_id) = 'text' AND length(s.session_id) <= 128 AND
      length(CAST(s.session_id AS BLOB)) <= 512 THEN s.session_id END AS source_id,
    CASE WHEN typeof(s.character_id) = 'text' AND length(s.character_id) <= 128 AND
      length(CAST(s.character_id AS BLOB)) <= 512 THEN s.character_id END AS character_id,
    s.session_index, s.updated_at,
    CASE WHEN typeof(c.name) = 'text' AND length(c.name) <= 256 AND
      length(CAST(c.name AS BLOB)) <= 1024 THEN c.name END AS label,
    CASE WHEN c.variant_group_id IS NULL OR (typeof(c.variant_group_id) = 'text' AND
      length(c.variant_group_id) <= 128 AND length(CAST(c.variant_group_id AS BLOB)) <= 512)
      THEN c.variant_group_id END AS variant_group_id,
    CASE WHEN c.variant_group_id IS NULL OR (typeof(c.variant_group_id) = 'text' AND
      length(c.variant_group_id) <= 128 AND length(CAST(c.variant_group_id AS BLOB)) <= 512)
      THEN 1 ELSE 0 END AS group_valid, c.variant_order
    FROM chat_sessions s INNER JOIN characters c ON c.char_id = s.character_id
    WHERE typeof(c.hidden) = 'integer' AND c.hidden = 0''';
  static const _studioMetadata = '''SELECT rowid AS native_identity,
    CASE WHEN typeof(preset_id) = 'text' AND length(preset_id) <= 128 AND
      length(CAST(preset_id AS BLOB)) <= 512 THEN preset_id END AS source_id,
    CASE WHEN typeof(name) = 'text' AND length(name) <= 256 AND
      length(CAST(name AS BLOB)) <= 1024 THEN name END AS label, updated_at
    FROM studio_preset_rows WHERE 1 = 1''';

  Map<String, Object?> _metadata(QueryRow row, SupportSourceDomain domain) {
    final map = Map<String, Object?>.unmodifiable(row.data);
    if (!_identity(map['source_id']) ||
        map['native_identity'] is! int ||
        map['updated_at'] is! int ||
        (map['updated_at'] as int) < 0 ||
        (map['updated_at'] as int) > 8640000000000000 ||
        map['label'] is! String ||
        (map['label'] as String).length > 256 ||
        utf8.encode(map['label'] as String).length > 1024)
      _deny();
    if (domain == SupportSourceDomain.game &&
        (!_identity(map['character_id']) ||
            map['parent_identity'] is! int ||
            map['group_valid'] != 1 ||
            map['session_index'] is! int ||
            (map['session_index'] as int) < 0 ||
            (map['session_index'] as int) > 1000000 ||
            map['variant_order'] is! int ||
            (map['variant_order'] as int) < 0 ||
            (map['variant_order'] as int) > 1000000 ||
            (map['variant_group_id'] != null &&
                map['variant_group_id'] != '' &&
                !_identity(map['variant_group_id']))))
      _deny();
    return map;
  }

  Future<SupportSourceCatalogPage> _catalog(
    SupportSourceDomain domain,
    int offset,
    bool Function() current,
  ) async {
    try {
      void guard() {
        if (!current()) _deny();
      }

      guard();
      if (offset < 0 || offset > 4096) _deny();
      final base = domain == SupportSourceDomain.game
          ? _gameMetadata
          : _studioMetadata;
      final activity = domain == SupportSourceDomain.game
          ? 's.updated_at'
          : 'updated_at';
      final identity = domain == SupportSourceDomain.game
          ? 's.session_id'
          : 'preset_id';
      final rows = await _db
          .customSelect(
            '$base ORDER BY $activity DESC, $identity ASC LIMIT 17 OFFSET ?',
            variables: [Variable.withInt(offset)],
          )
          .get();
      guard();
      if (rows.length > SupportSourceTextRepo.pageSize &&
          offset + SupportSourceTextRepo.pageSize > 4096)
        _deny();
      final entries = <SupportSourceCatalogEntry>[];
      // A bad projected metadata row refuses the page rather than substituting
      // another session with a similar label or a different preset domain.
      for (final row in rows.take(SupportSourceTextRepo.pageSize)) {
        entries.add(
          SupportSourceCatalogEntry._(this, domain, _metadata(row, domain)),
        );
      }
      return SupportSourceCatalogPage._(
        entries,
        rows.length > SupportSourceTextRepo.pageSize &&
                offset + SupportSourceTextRepo.pageSize <= 4096
            ? offset + SupportSourceTextRepo.pageSize
            : null,
      );
    } catch (_) {
      _deny();
    }
  }

  Future<Map<String, Object?>> _header(
    SupportSourceDomain domain,
    String id,
    void Function() guard,
  ) async {
    guard();
    if (!_identity(id)) _deny();
    final base = domain == SupportSourceDomain.game
        ? _gameMetadata
        : _studioMetadata;
    final identity = domain == SupportSourceDomain.game
        ? 's.session_id'
        : 'preset_id';
    final row = await _db
        .customSelect(
          '$base AND $identity = ? LIMIT 1',
          variables: [Variable.withString(id)],
        )
        .getSingleOrNull();
    guard();
    if (row == null) _deny();
    return _metadata(row, domain);
  }

  Future<SupportSourceObservation> _observe(
    SupportSourceCatalogEntry entry,
    int offset,
    bool Function() current,
  ) async {
    try {
      void guard() {
        if (!current()) _deny();
      }

      guard();
      if (!identical(entry._owner, this) ||
          offset < 0 ||
          offset > 2000 ||
          (entry.domain == SupportSourceDomain.studioPreset && offset != 0))
        _deny();
      final result = await _db.transaction(() async {
        guard();
        final before = await _stamp(guard);
        final header = await _header(entry.domain, entry.sourceId, guard);
        guard();
        if (!_equal(header, entry._header)) _deny();
        List<Map<String, Object?>>? discovery;
        List<String> ids;
        int count, chars, bytes;
        if (entry.domain == SupportSourceDomain.game) {
          discovery = await _discoverGame(entry.sourceId, guard);
          guard();
          final active = discovery.where((row) => row['visible'] == 1).toList();
          count = active.length;
          if (offset >= count) _deny();
          final end = count - offset;
          final start = end > SupportSourceTextRepo.pageSize
              ? end - SupportSourceTextRepo.pageSize
              : 0;
          final page = active.sublist(start, end);
          ids = [for (final row in page) row['message_id'] as String];
          chars = page.fold(0, (n, row) => n + (row['chars'] as int));
          bytes = page.fold(0, (n, row) => n + (row['bytes'] as int));
        } else {
          final extent = await _studioExtent(entry.sourceId, guard);
          guard();
          ids = [entry.sourceId];
          count = 1;
          chars = extent.$1;
          bytes = extent.$2;
        }
        if (bytes > SupportSourceTextRepo.maxToolResultBytes || chars > 65536)
          _deny();
        final after = await _stamp(guard);
        if (before != after) _deny();
        return SupportSourceObservation._(
          this,
          entry.domain,
          header,
          after,
          ids,
          offset,
          count,
          chars,
          bytes,
          discovery,
        );
      });
      guard();
      return result;
    } catch (_) {
      _deny();
    }
  }
}
