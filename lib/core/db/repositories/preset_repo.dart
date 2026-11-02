import 'dart:convert';

import 'package:drift/drift.dart';

import '../app_db.dart';
import '../../models/preset.dart';
import '../../application/sync_repo_interfaces.dart';

part 'preset_app_control.dart';

class PresetRepo implements SyncPresetStore {
  final AppDatabase _db;
  PresetRepo(this._db);

  // Ordinary presets ONLY. Studio IDs belong to a different table/lifetime.
  // Shared original-writer intent detects ABA without an equality receipt.
  static final _selectionTargets =
      Expando<Map<String, ({Object event, int pending})>>();
  Map<String, ({Object event, int pending})> get _selectionTargetEvents =>
      _selectionTargets[_db] ??= {};

  bool Function()? captureNativeSelectionTarget(String id) {
    final events = _selectionTargetEvents;
    final before = events.putIfAbsent(id, () => (event: Object(), pending: 0));
    if (before.pending != 0) return null;
    var retired = false;
    return () {
      final now = events[id]!;
      if (now.pending != 0 || !identical(now.event, before.event)) retired = true;
      return !retired;
    };
  }

  Future<T> _selectionTargetWrite<T>(String id, Future<T> Function() write) async {
    final events = _selectionTargetEvents;
    final before = events[id];
    events[id] = (event: Object(), pending: (before?.pending ?? 0) + 1);
    try {
      return await write();
    } finally {
      final latest = events[id]!;
      events[id] = (event: latest.event, pending: latest.pending - 1);
    }
  }

  @override
  Future<List<Preset>> getAll() async {
    final rows = await _db.select(_db.presets).get();
    final presets = rows.map(_toModel).toList();
    for (int i = 0; i < presets.length; i++) {
      final original = rows[i].dataJson;
      final repaired = jsonEncode(presets[i].toJson());
      if (original != repaired) {
        await _selectionTargetWrite(presets[i].id, () => _db
            .into(_db.presets)
            .insertOnConflictUpdate(
              PresetsCompanion(
                presetId: Value(presets[i].id),
                name: Value(presets[i].name),
                dataJson: Value(repaired),
              ),
            ));
      }
    }
    return presets;
  }

  @override
  Future<Preset?> getById(String id) async {
    final row = await (_db.select(
      _db.presets,
    )..where((t) => t.presetId.equals(id))).getSingleOrNull();
    return row != null ? _toModel(row) : null;
  }

  @override
  Future<void> put(Preset preset) => _selectionTargetWrite(preset.id, () async {
    await _db.into(_db.presets).insertOnConflictUpdate(_toCompanion(preset));
  });

  /// Startup seeding may race with an editor, import, sync, or deletion. Only
  /// replace the exact copy the caller examined, or insert a still-missing row.
  Future<bool> putIfUnchanged(
    Preset preset, {
    Preset? expectedExisting,
    bool insertIfMissing = false,
  }) => _db.transaction(() async {
    final current = await getById(preset.id);
    if (current == null) {
      if (!insertIfMissing || expectedExisting != null) return false;
    } else if (expectedExisting == null || current != expectedExisting) {
      return false;
    }
    await put(preset);
    return true;
  });

  @override
  Future<void> delete(String id) => _selectionTargetWrite(id, () async {
    await (_db.delete(_db.presets)..where((t) => t.presetId.equals(id))).go();
  });

  Future<void> putFromMap(Map<String, dynamic> m) async {
    final preset = Preset.fromJson(m);
    await put(preset);
  }

  Preset _toModel(PresetRow c) =>
      Preset.fromJson(jsonDecode(c.dataJson) as Map<String, dynamic>);

  PresetsCompanion _toCompanion(Preset m) => PresetsCompanion(
    presetId: Value(m.id),
    name: Value(m.name),
    dataJson: Value(jsonEncode(m.toJson())),
  );
}
