part of 'preset_repo.dart';

enum PresetControlText {
  name,
  summaryPrompt,
  guidedGenerationPrompt,
  guidedImpersonationPrompt,
  impersonationPrompt,
}

extension PresetAppControl on PresetRepo {
  Future<({List<String> ids, int count})?> controlBlockIds(
    String id,
    int offset,
  ) async {
    final row =
        await (_db.selectOnly(_db.presets)
              ..addColumns([_db.presets.dataJson])
              ..where(_db.presets.presetId.equals(id)))
            .getSingleOrNull();
    if (row == null) return null;
    final data = jsonDecode(row.read(_db.presets.dataJson)!) as Map;
    final blocks = data['blocks'] as List? ?? [];
    final ids = blocks
        .map((b) => (b as Map)['id'])
        .whereType<String>()
        .toList();
    return (ids: ids.skip(offset).take(32).toList(), count: ids.length);
  }

  /// Unlike getAll this projection has no repair/write side effect.
  Future<({List<String> ids, int count})> controlIds(int offset) async {
    final count = _db.presets.presetId.count();
    final total = await (_db.selectOnly(
      _db.presets,
    )..addColumns([count])).getSingle();
    final rows =
        await (_db.selectOnly(_db.presets)
              ..addColumns([_db.presets.presetId])
              ..orderBy([OrderingTerm.asc(_db.presets.presetId)])
              ..limit(32, offset: offset))
            .get();
    return (
      ids: rows.map((r) => r.read(_db.presets.presetId)!).toList(),
      count: total.read(count) ?? 0,
    );
  }

  Future<bool> controlCreate(Preset value, bool Function() current) =>
      _db.transaction(() async {
        if (!current() || await getById(value.id) != null || !current()) {
          return false;
        }
        await _selectionTargetWrite(value.id,
            () => _db.into(_db.presets).insert(_toCompanion(value)));
        return true;
      });

  /// Preserve the original JSON (including unknown/import fields); only the
  /// selected root key or non-static block is edited. No decoding repair write.
  Future<bool> controlPatch({
    required Preset expected,
    PresetControlText? field,
    String? value,
    String? blockId,
    bool? enabled,
    String? role,
    int? depth,
    bool addBlock = false,
    String? blockName,
    required bool Function() current,
  }) => _db.transaction(() async {
    if (!current()) return false;
    final row = await (_db.select(
      _db.presets,
    )..where((t) => t.presetId.equals(expected.id))).getSingleOrNull();
    if (!current() || row == null || _toModel(row) != expected) return false;
    final data = Map<String, dynamic>.from(jsonDecode(row.dataJson) as Map);
    if (field != null) data[field.name] = value;
    if (blockId != null) {
      final blocks = (data['blocks'] as List? ?? [])
          .map((b) => Map<String, dynamic>.from(b as Map))
          .toList();
      final index = blocks.indexWhere((b) => b['id'] == blockId);
      if (addBlock) {
        if (index != -1) return false;
        blocks.add(
          PresetBlock(
            id: blockId,
            name: blockName!,
            role: role ?? 'system',
            content: value ?? '',
          ).toJson(),
        );
      } else {
        if (index == -1 ||
            blocks.where((b) => b['id'] == blockId).length != 1 ||
            expected.blocks
                .where((b) => b.id == blockId)
                .any((b) => b.isStatic)) {
          return false;
        }
        final block = blocks[index];
        if (value != null) block['content'] = value;
        if (enabled != null) block['enabled'] = enabled;
        if (role != null) block['role'] = role;
        if (depth != null) {
          block['depth'] = depth;
          block['insertionMode'] = 'depth';
        }
      }
      data['blocks'] = blocks;
    }
    if (!current()) return false;
    final changed =
        await _selectionTargetWrite(row.presetId, () => (_db.update(_db.presets)..where(
              (t) =>
                  t.presetId.equals(row.presetId) &
                  t.dataJson.equals(row.dataJson),
            ))
            .write(
              PresetsCompanion(
                dataJson: Value(jsonEncode(data)),
                name: field == PresetControlText.name
                    ? Value(value!)
                    : const Value.absent(),
              ),
            ));
    return changed == 1;
  });
}
