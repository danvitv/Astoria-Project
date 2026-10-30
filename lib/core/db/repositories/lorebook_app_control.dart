part of 'lorebook_repo.dart';

enum LorebookControlText { name, description }

extension LorebookAppControl on LorebookRepo {
  Future<({List<String> ids, int count})?> controlEntryIds(
    String id,
    int offset,
  ) async {
    final row =
        await (_db.selectOnly(_db.lorebooks)
              ..addColumns([_db.lorebooks.entriesJson])
              ..where(_db.lorebooks.lorebookId.equals(id)))
            .getSingleOrNull();
    if (row == null) return null;
    final entries = jsonDecode(row.read(_db.lorebooks.entriesJson)!) as List;
    final ids = entries
        .map((e) => (e as Map)['id'])
        .whereType<String>()
        .toList();
    return (ids: ids.skip(offset).take(32).toList(), count: ids.length);
  }

  Future<({List<String> ids, int count})> controlIds(int offset) async {
    final count = _db.lorebooks.lorebookId.count();
    final total = await (_db.selectOnly(
      _db.lorebooks,
    )..addColumns([count])).getSingle();
    final rows =
        await (_db.selectOnly(_db.lorebooks)
              ..addColumns([_db.lorebooks.lorebookId])
              ..orderBy([OrderingTerm.asc(_db.lorebooks.lorebookId)])
              ..limit(32, offset: offset))
            .get();
    return (
      ids: rows.map((r) => r.read(_db.lorebooks.lorebookId)!).toList(),
      count: total.read(count) ?? 0,
    );
  }

  /// New unbound/global books need no preference-map side effects.
  Future<bool> controlCreate(Lorebook value, bool Function() current) =>
      _db.transaction(() async {
        if (!current() ||
            value.activationScope != 'global' ||
            value.activationTargetId != null) {
          return false;
        }
        if (await getById(value.id) != null || !current()) return false;
        await _db.into(_db.lorebooks).insert(_toCompanion(value));
        return true;
      });

  /// Editable base books only: session overlays/revisions are canon-owned.
  /// Original JSON maps are patched instead of dropping unknown entry fields.
  Future<bool> controlPatch({
    required Lorebook expected,
    LorebookControlText? field,
    String? value,
    bool? enabled,
    String? entryId,
    String? entryContent,
    String? entryComment,
    bool? constant,
    int? probability,
    int? order,
    bool addEntry = false,
    int? scanDepth,
    int? maxInjectedEntries,
    required bool Function() current,
  }) => _db.transaction(() async {
    if (!current()) return false;
    final row = await (_db.select(
      _db.lorebooks,
    )..where((t) => t.lorebookId.equals(expected.id))).getSingleOrNull();
    if (!current() ||
        row == null ||
        _toModel(row) != expected ||
        row.activationScope == 'chat') {
      return false;
    }
    String? entriesJson;
    if (entryId != null) {
      final entries = (jsonDecode(row.entriesJson) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final index = entries.indexWhere((e) => e['id'] == entryId);
      if (addEntry) {
        if (index != -1) return false;
        entries.add(
          LorebookEntry(
            id: entryId,
            content: entryContent ?? '',
            comment: entryComment ?? '',
            enabled: enabled ?? true,
            constant: constant ?? false,
          ).toJson(),
        );
      } else {
        if (index == -1 ||
            entries.where((e) => e['id'] == entryId).length != 1) {
          return false;
        }
        final entry = entries[index];
        if (entryContent != null) entry['content'] = entryContent;
        if (entryComment != null) entry['comment'] = entryComment;
        if (enabled != null) entry['enabled'] = enabled;
        if (constant != null) entry['constant'] = constant;
        if (probability != null) entry['probability'] = probability;
        if (order != null) entry['order'] = order;
      }
      entriesJson = jsonEncode(entries);
    }
    String? settingsJson;
    if (scanDepth != null || maxInjectedEntries != null) {
      final settings = row.settingsJson.isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(row.settingsJson) as Map);
      if (scanDepth != null) settings['scanDepth'] = scanDepth;
      if (maxInjectedEntries != null) {
        settings['maxInjectedEntries'] = maxInjectedEntries;
      }
      settingsJson = jsonEncode(settings);
    }
    if (!current()) return false;
    final changed =
        await (_db.update(_db.lorebooks)..where(
              (t) =>
                  t.lorebookId.equals(row.lorebookId) &
                  t.entriesJson.equals(row.entriesJson) &
                  t.settingsJson.equals(row.settingsJson) &
                  t.updatedAt.equals(row.updatedAt),
            ))
            .write(
              LorebooksCompanion(
                name: field == LorebookControlText.name
                    ? Value(value!)
                    : const Value.absent(),
                description: field == LorebookControlText.description
                    ? Value(value!)
                    : const Value.absent(),
                enabled: entryId != null || enabled == null
                    ? const Value.absent()
                    : Value(enabled),
                entriesJson: entriesJson == null
                    ? const Value.absent()
                    : Value(entriesJson),
                settingsJson: settingsJson == null
                    ? const Value.absent()
                    : Value(settingsJson),
                updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
              ),
            );
    return changed == 1;
  });
}
