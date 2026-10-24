part of 'studio_preset_repo.dart';

enum StudioControlBlockField { content, enabled, role, order, depth }

extension StudioPresetAppControl on StudioPresetRepo {
  Future<({List<String> ids, int count})?> controlBlockIds(
    String id,
    int offset,
  ) async {
    final row =
        await (db.selectOnly(db.studioPresetRows)
              ..addColumns([db.studioPresetRows.blocksJson])
              ..where(db.studioPresetRows.presetId.equals(id)))
            .getSingleOrNull();
    if (row == null) return null;
    final blocks =
        jsonDecode(row.read(db.studioPresetRows.blocksJson)!) as List;
    final ids = blocks
        .map((b) => (b as Map)['id'])
        .whereType<String>()
        .toList();
    return (ids: ids.skip(offset).take(32).toList(), count: ids.length);
  }

  /// Native control observation retains dependency restoration state that the
  /// legacy general codec does not currently expose. It stays private.
  Future<StudioPreset?> controlObserve(String id) async {
    final row = await (db.select(
      db.studioPresetRows,
    )..where((t) => t.presetId.equals(id))).getSingleOrNull();
    if (row == null) return null;
    final runtime = jsonDecode(row.runtimeSettingsJson) as Map;
    final restore = runtime['agentEnabledBeforeDependencyOff'];
    return _rowToModel(row).copyWith(
      agentEnabledBeforeDependencyOff: restore is Map
          ? {
              for (final e in restore.entries)
                if (e.key is String && e.value is bool)
                  e.key as String: e.value as bool,
            }
          : const {},
    );
  }

  Future<({List<String> ids, int count})> controlIds(int offset) async {
    final count = db.studioPresetRows.presetId.count();
    final total = await (db.selectOnly(
      db.studioPresetRows,
    )..addColumns([count])).getSingle();
    final rows =
        await (db.selectOnly(db.studioPresetRows)
              ..addColumns([db.studioPresetRows.presetId])
              ..orderBy([OrderingTerm.asc(db.studioPresetRows.presetId)])
              ..limit(32, offset: offset))
            .get();
    return (
      ids: rows.map((r) => r.read(db.studioPresetRows.presetId)!).toList(),
      count: total.read(count) ?? 0,
    );
  }

  /// Creation clones an exact saved source, not the editor's detached draft.
  /// Selection is intentionally not changed by creation.
  Future<bool> controlClone({
    required StudioPreset expected,
    required String id,
    required String name,
    required int timestamp,
    required bool Function() current,
  }) => db.transaction(() async {
    if (!current()) return false;
    final source = await (db.select(
      db.studioPresetRows,
    )..where((t) => t.presetId.equals(expected.id))).getSingleOrNull();
    if (!current() || source == null) return false;
    final latest = _rowToModel(source);
    if (latest != expected) return false;
    if (await getById(id) != null || !current()) return false;
    final next = latest.copyWith(id: id, name: name, updatedAt: timestamp);
    if (StudioPresetValidator.hasErrors(StudioPresetValidator.validate(next)))
      return false;
    if (!current()) return false;
    await db
        .into(db.studioPresetRows)
        .insert(
          StudioPresetRowsCompanion.insert(
            presetId: id,
            name: name,
            blocksJson: Value(source.blocksJson),
            agentsJson: Value(source.agentsJson),
            expensiveApiConfigId: Value(source.expensiveApiConfigId),
            cheapApiConfigId: Value(source.cheapApiConfigId),
            cleanerApiConfigId: Value(source.cleanerApiConfigId),
            ledgerApiConfigId: Value(source.ledgerApiConfigId),
            maxFinalHistoryMessages: Value(source.maxFinalHistoryMessages),
            agentEnabledJson: Value(source.agentEnabledJson),
            executionMode: Value(source.executionMode),
            runtimeSettingsJson: Value(source.runtimeSettingsJson),
            updatedAt: Value(timestamp),
          ),
        );
    return true;
  });

  /// Narrow persisted columns/JSON-key patches; never upsert an old full row.
  /// The supplied block is a native typed patch, checked against the exact
  /// current owner. History/context/static/locked blocks are protected.
  Future<bool> controlPatch({
    required StudioPreset expected,
    String? name,
    int? maxFinalHistoryMessages,
    StudioPresetBlock? block,
    Set<StudioControlBlockField> blockFields = const {},
    bool addBlock = false,
    required int timestamp,
    required bool Function() current,
  }) => db.transaction(() async {
    if (!current()) return false;
    final row = await (db.select(
      db.studioPresetRows,
    )..where((t) => t.presetId.equals(expected.id))).getSingleOrNull();
    if (!current() || row == null) return false;
    final latest = _rowToModel(row);
    if (latest != expected) return false;
    String? blocksJson;
    if (block != null) {
      final blocks = (jsonDecode(row.blocksJson) as List)
          .map((b) => Map<String, dynamic>.from(b as Map))
          .toList();
      final index = blocks.indexWhere((b) => b['id'] == block.id);
      final before = latest.blocks.where((b) => b.id == block.id).firstOrNull;
      if (addBlock) {
        if (index != -1 ||
            block.locked ||
            block.isStatic ||
            block.type != StudioBlockType.instruction ||
            block.mode != 'direct')
          return false;
        blocks.add(block.toJson());
      } else {
        if (index == -1 ||
            blocks.where((b) => b['id'] == block.id).length != 1 ||
            before == null ||
            before.locked ||
            before.isStatic ||
            before.type != StudioBlockType.instruction ||
            before.mode != 'direct')
          return false;
        // Only editable fields change; preserve raw routing/import fields.
        final raw = blocks[index];
        if (blockFields.contains(StudioControlBlockField.content))
          raw['content'] = block.content;
        if (blockFields.contains(StudioControlBlockField.enabled))
          raw['enabled'] = block.enabled;
        if (blockFields.contains(StudioControlBlockField.role))
          raw['role'] = block.role;
        if (blockFields.contains(StudioControlBlockField.order))
          raw['order'] = block.order;
        if (blockFields.contains(StudioControlBlockField.depth)) {
          raw['depth'] = block.depth;
          raw['insertionMode'] = 'depth';
        }
      }
      final proposed = latest.copyWith(
        blocks: blocks.map(StudioPresetBlock.fromJson).toList(),
      );
      if (StudioPresetValidator.hasErrors(
        StudioPresetValidator.validate(proposed),
      ))
        return false;
      blocksJson = jsonEncode(blocks);
    }
    if (!current()) return false;
    final changed =
        await (db.update(db.studioPresetRows)..where(
              (t) =>
                  t.presetId.equals(row.presetId) &
                  t.blocksJson.equals(row.blocksJson) &
                  t.agentsJson.equals(row.agentsJson) &
                  t.runtimeSettingsJson.equals(row.runtimeSettingsJson) &
                  t.updatedAt.equals(row.updatedAt),
            ))
            .write(
              StudioPresetRowsCompanion(
                name: name == null ? const Value.absent() : Value(name),
                maxFinalHistoryMessages: maxFinalHistoryMessages == null
                    ? const Value.absent()
                    : Value(maxFinalHistoryMessages),
                blocksJson: blocksJson == null
                    ? const Value.absent()
                    : Value(blocksJson),
                updatedAt: Value(timestamp),
              ),
            );
    return changed == 1;
  });

  /// The feature's canonical toggle helper computes dependency/radio changes;
  /// persistence is CAS-owned here. No other prompt/agent configuration moves.
  Future<bool> controlAgentToggle({
    required StudioPreset expected,
    required StudioPreset toggled,
    required int timestamp,
    required bool Function() current,
  }) => db.transaction(() async {
    if (!current()) return false;
    final latest = await controlObserve(expected.id);
    if (!current() ||
        latest == null ||
        latest != expected ||
        toggled.id != latest.id)
      return false;
    final row = await (db.select(
      db.studioPresetRows,
    )..where((t) => t.presetId.equals(latest.id))).getSingle();
    if (!current()) return false;
    final blocks = (jsonDecode(row.blocksJson) as List)
        .map((b) => Map<String, dynamic>.from(b as Map))
        .toList();
    for (final block in blocks) {
      final before = latest.blocks
          .where((b) => b.id == block['id'])
          .firstOrNull;
      final after = toggled.blocks
          .where((b) => b.id == block['id'])
          .firstOrNull;
      if (before == null || after == null) return false;
      if (before.enabled != after.enabled &&
          (before.locked ||
              before.isStatic ||
              before.type != StudioBlockType.instruction))
        return false;
      if (before.enabled != after.enabled) block['enabled'] = after.enabled;
    }
    final runtime =
        Map<String, dynamic>.from(jsonDecode(row.runtimeSettingsJson) as Map)
          ..['agentBlockRestoreState'] = toggled.agentBlockRestoreState
          ..['agentEnabledBeforeDependencyOff'] =
              toggled.agentEnabledBeforeDependencyOff;
    if (!current()) return false;
    final changed =
        await (db.update(db.studioPresetRows)..where(
              (t) =>
                  t.presetId.equals(row.presetId) &
                  t.blocksJson.equals(row.blocksJson) &
                  t.agentEnabledJson.equals(row.agentEnabledJson) &
                  t.runtimeSettingsJson.equals(row.runtimeSettingsJson),
            ))
            .write(
              StudioPresetRowsCompanion(
                blocksJson: Value(jsonEncode(blocks)),
                agentEnabledJson: Value(jsonEncode(toggled.agentEnabled)),
                runtimeSettingsJson: Value(jsonEncode(runtime)),
                updatedAt: Value(timestamp),
              ),
            );
    return changed == 1;
  });

  /// Scalar patches only. A nullable per-preset lane is not initialized from
  /// guessed global defaults: callers must first configure it in the native UI.
  Future<bool> controlRuntime({
    required StudioPreset expected,
    required bool cleaner,
    double? temperature,
    int? maxTokens,
    int? historyMessages,
    bool? enabled,
    int? interval,
    required int timestamp,
    required bool Function() current,
  }) => db.transaction(() async {
    if (!current()) return false;
    final row = await (db.select(
      db.studioPresetRows,
    )..where((t) => t.presetId.equals(expected.id))).getSingleOrNull();
    if (!current() || row == null || _rowToModel(row) != expected) return false;
    final runtime = Map<String, dynamic>.from(
      jsonDecode(row.runtimeSettingsJson) as Map,
    );
    final key = cleaner ? 'cleaner' : 'ledger';
    final original = runtime[key];
    if (original is! Map) return false;
    final settings = Map<String, dynamic>.from(original);
    if (cleaner) {
      if (temperature != null) settings['postCleanerTemperature'] = temperature;
      if (maxTokens != null) settings['postCleanerMaxTokens'] = maxTokens;
      if (historyMessages != null)
        settings['postCleanerHistoryMessages'] = historyMessages;
      if (enabled != null) settings['postCleanerEnabled'] = enabled;
    } else {
      if (temperature != null)
        settings['studioLedgerTemperature'] = temperature;
      if (maxTokens != null) settings['studioLedgerMaxTokens'] = maxTokens;
      if (interval != null) settings['studioLedgerIntervalN'] = interval;
    }
    runtime[key] = settings;
    if (!current()) return false;
    final changed =
        await (db.update(db.studioPresetRows)..where(
              (t) =>
                  t.presetId.equals(row.presetId) &
                  t.runtimeSettingsJson.equals(row.runtimeSettingsJson),
            ))
            .write(
              StudioPresetRowsCompanion(
                runtimeSettingsJson: Value(jsonEncode(runtime)),
                updatedAt: Value(timestamp),
              ),
            );
    return changed == 1;
  });
}
