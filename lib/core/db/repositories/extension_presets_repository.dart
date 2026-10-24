import 'dart:convert';

import 'package:drift/drift.dart';

import '../app_db.dart';
import '../tables.dart';
import '../../../features/extensions/models/extension_preset.dart';

part 'extension_presets_repository.g.dart';

@DriftAccessor(tables: [ExtensionPresets])
class ExtensionPresetsRepository extends DatabaseAccessor<AppDatabase>
    with _$ExtensionPresetsRepositoryMixin {
  ExtensionPresetsRepository(super.db);

  Future<void> insert(ExtensionPreset preset) async {
    await into(extensionPresets).insert(
      ExtensionPresetsCompanion.insert(
        id: preset.id,
        name: preset.name,
        configJson: jsonEncode(preset.toJson()),
        createdAt: Value(preset.createdAt),
      ),
    );
  }

  Future<List<ExtensionPreset>> getAll() async {
    final rows = await (select(
      extensionPresets,
    )..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).get();

    final result = <ExtensionPreset>[];
    for (final row in rows) {
      try {
        final json = jsonDecode(row.configJson) as Map<String, dynamic>;
        result.add(
          ExtensionPreset.fromJson({
            ...json,
            'id': row.id,
            'name': row.name,
            'createdAt': row.createdAt,
          }),
        );
      } catch (_) {
        // Skip malformed rows silently — corrupt configJson shouldn't
        // block the entire list.
        continue;
      }
    }
    return result;
  }

  Future<ExtensionPreset?> getById(String id) async {
    final row = await (select(
      extensionPresets,
    )..where((tbl) => tbl.id.equals(id))).getSingleOrNull();

    if (row == null) return null;

    final json = jsonDecode(row.configJson) as Map<String, dynamic>;
    return ExtensionPreset.fromJson({
      ...json,
      'id': row.id,
      'name': row.name,
      'createdAt': row.createdAt,
    });
  }

  Future<void> updatePreset(ExtensionPreset preset) async {
    await (update(
      extensionPresets,
    )..where((tbl) => tbl.id.equals(preset.id))).write(
      ExtensionPresetsCompanion(
        name: Value(preset.name),
        configJson: Value(jsonEncode(preset.toJson())),
      ),
    );
  }

  Future<void> deletePreset(String id) async {
    await (delete(extensionPresets)..where((tbl) => tbl.id.equals(id))).go();
  }

  /// Native-only snapshots. Names, prompts, scripts and raw row IDs must never
  /// be serialized into application-control metadata.
  Future<List<ExtensionControlObservation>> inspectControls({
    int limit = 32,
  }) async {
    if (limit < 1 || limit > 32) throw ArgumentError.value(limit);
    final rows =
        await (select(extensionPresets)
              ..orderBy([(row) => OrderingTerm.asc(row.id)])
              ..limit(limit + 1))
            .get();
    return [for (final row in rows) ExtensionControlObservation._(row)];
  }

  Future<ExtensionControlObservation?> inspectControl(String id) async {
    final row = await (select(
      extensionPresets,
    )..where((row) => row.id.equals(id))).getSingleOrNull();
    return row == null ? null : ExtensionControlObservation._(row);
  }

  /// Only deactivation is admitted. Enabling a stored script/model block can
  /// trigger code or paid work and needs a different native authority contract.
  /// SQL compares the exact latest preimage; only configJson is written, and
  /// unknown JSON fields are retained rather than passed through a model codec.
  Future<ExtensionControlMutation> disableControlBlock({
    required ExtensionControlObservation expected,
    required String blockId,
    required bool Function() isCurrent,
  }) => attachedDatabase.transaction(() async {
    if (!isCurrent()) return ExtensionControlMutation.stale;
    final latest = await inspectControl(expected._row.id);
    if (!isCurrent()) return ExtensionControlMutation.stale;
    if (latest == null || !expected.sameState(latest)) {
      return ExtensionControlMutation.conflict;
    }
    final config = jsonDecode(latest._row.configJson) as Map<String, dynamic>;
    final blocks = config['blocks'];
    if (blocks is! List) return ExtensionControlMutation.conflict;
    final targets = blocks.whereType<Map>().where((b) => b['id'] == blockId);
    if (targets.length != 1) return ExtensionControlMutation.conflict;
    final target = targets.single;
    if (target['enabled'] != null && target['enabled'] is! bool) {
      return ExtensionControlMutation.conflict;
    }
    if (target['enabled'] == false) return ExtensionControlMutation.noChange;
    target['enabled'] = false;
    final row = expected._row;
    if (!isCurrent()) return ExtensionControlMutation.stale;
    final changed =
        await (update(extensionPresets)..where(
              (t) =>
                  t.id.equals(row.id) &
                  t.name.equals(row.name) &
                  t.createdAt.equals(row.createdAt) &
                  t.configJson.equals(row.configJson),
            ))
            .write(
              ExtensionPresetsCompanion(configJson: Value(jsonEncode(config))),
            );
    // A completed write is durable even if its original source retires while
    // SQLite finishes. Never turn this into a retry or a compensating write.
    return changed == 1
        ? ExtensionControlMutation.persisted
        : ExtensionControlMutation.conflict;
  });
}

enum ExtensionControlMutation { persisted, noChange, conflict, stale }

/// Opaque native CAS preimage. Only finite controls are exposed to adapters.
final class ExtensionControlObservation {
  ExtensionControlObservation._(this._row);
  final ExtensionPresetRow _row;
  String get nativeId => _row.id;

  bool sameState(ExtensionControlObservation other) =>
      _row.id == other._row.id &&
      _row.name == other._row.name &&
      _row.createdAt == other._row.createdAt &&
      _row.configJson == other._row.configJson;

  List<ExtensionBlockControl>? get blocks {
    try {
      final config = jsonDecode(_row.configJson);
      if (config is! Map || config['blocks'] is! List) return null;
      final result = <ExtensionBlockControl>[];
      final ids = <String>{};
      for (final block in config['blocks'] as List) {
        if (block is! Map ||
            block['id'] is! String ||
            !ids.add(block['id'] as String) ||
            (block['enabled'] != null && block['enabled'] is! bool)) {
          return null;
        }
        final kind = switch (block['type']) {
          'generated' ||
          'infoblock' ||
          'imageGen' ||
          'interactive' => 'generated',
          'script' || 'jsRunner' => 'script',
          'rewrite' => 'rewrite',
          'accumulation' => 'accumulation',
          _ => 'unknown',
        };
        result.add(
          ExtensionBlockControl(
            nativeId: block['id'] as String,
            kind: kind,
            enabled: block['enabled'] != false,
          ),
        );
      }
      return List.unmodifiable(result);
    } catch (_) {
      return null;
    }
  }
}

final class ExtensionBlockControl {
  const ExtensionBlockControl({
    required this.nativeId,
    required this.kind,
    required this.enabled,
  });
  final String nativeId, kind;
  final bool enabled;
}
