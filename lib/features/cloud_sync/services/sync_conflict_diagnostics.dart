import 'dart:convert';

import '../cloud_adapter.dart';
import '../sync_models.dart';
import 'sync_conflict.dart';
import 'sync_conflict_diagnostics_comparator.dart';
import 'sync_conflict_diagnostics_download.dart';
import 'sync_conflict_diagnostics_report.dart';

export 'sync_conflict_diagnostics_report.dart';

class SyncConflictDiagnostics {
  final Future<Map<String, dynamic>?> Function(String, String) readLocal;
  final Future<String> Function(String) download;
  final SyncConflictDiagnosticComparator comparator;
  final bool adapterSupported;
  static const maxPayloadBytes = 2 * 1024 * 1024;

  const SyncConflictDiagnostics({
    required this.readLocal,
    required this.download,
    this.comparator = const SyncConflictDiagnosticComparator(),
    this.adapterSupported = true,
  });

  Future<SyncConflictDiagnosticReport> diagnose(
    List<SyncConflict> conflicts,
  ) async {
    final snapshot = List<SyncConflict>.unmodifiable(conflicts.take(50));
    final truncated = conflicts.length > 50;
    final items = <SyncConflictDiagnosticItem>[];
    for (var i = 0; i < snapshot.length; i++) {
      items.add(await _item(snapshot[i], i + 1));
    }
    return SyncConflictDiagnosticReport(items: items, truncated: truncated);
  }

  Future<SyncConflictDiagnosticItem> _item(
    SyncConflict conflict,
    int ordinal,
  ) async {
    final type = switch (conflict.type) {
      'character' => SyncDiagnosticType.character,
      'character_knowledge' => SyncDiagnosticType.characterKnowledge,
      'memory_graph' => SyncDiagnosticType.memoryGraph,
      _ => SyncDiagnosticType.unsupported,
    };
    SyncConflictDiagnosticItem result(
      SyncDiagnosticStatus status, [
      List<SyncDiagnosticPath> paths = const [],
    ]) => SyncConflictDiagnosticItem(
      ordinal: ordinal,
      type: type,
      status: status,
      paths: paths,
      localTimestampUnit: diagnosticTimestampUnit(
        conflict.localEntry.updatedAt,
      ),
      cloudTimestampUnit: diagnosticTimestampUnit(
        conflict.cloudEntry.updatedAt,
      ),
    );
    if (type == SyncDiagnosticType.unsupported) {
      return result(SyncDiagnosticStatus.unsupported);
    }
    if (!adapterSupported) return result(SyncDiagnosticStatus.unsupported);
    // cloudPath is computed, and identities cannot escape its directory.
    final path = cloudPath(conflict.type, conflict.id);
    if (!SyncConflictDiagnosticDownload.validPath(path)) {
      return result(SyncDiagnosticStatus.invalidIdentity);
    }
    Map<String, dynamic>? local;
    try {
      local = await readLocal(conflict.type, conflict.id);
    } catch (_) {
      return result(SyncDiagnosticStatus.localReadFailed);
    }
    if (local == null) return result(SyncDiagnosticStatus.missingLocal);
    // Freeze the inspected trusted tree before the cloud checkpoint. No encoder
    // or arbitrary serializer: repository-owned GalleryEntry is handled explicitly.
    final frozen = _snapshot(local);
    String raw;
    try {
      raw = await download(path);
    } on SyncDiagnosticInvalidIdentity {
      return result(SyncDiagnosticStatus.invalidIdentity);
    } on SyncDiagnosticAdapterUnsupported {
      return result(SyncDiagnosticStatus.unsupported);
    } on SyncDiagnosticAuthUnavailable {
      return result(SyncDiagnosticStatus.authUnavailable);
    } on CloudFileNotFoundException {
      return result(SyncDiagnosticStatus.cloudMissing);
    } on SyncDiagnosticDownloadMissing {
      return result(SyncDiagnosticStatus.cloudMissing);
    } catch (_) {
      return result(SyncDiagnosticStatus.cloudReadFailed);
    }
    Map<String, dynamic>? current;
    try {
      current = await readLocal(conflict.type, conflict.id);
    } catch (_) {
      return result(SyncDiagnosticStatus.localReadFailed);
    }
    final stability = comparator.inspect(conflict.type, frozen, current);
    if (!stability.equal) {
      return result(
        stability.limited
            ? SyncDiagnosticStatus.inspectionLimited
            : SyncDiagnosticStatus.changedDuringRead,
        stability.paths,
      );
    }
    if (raw.length > maxPayloadBytes ||
        utf8.encode(raw).length > maxPayloadBytes) {
      return result(SyncDiagnosticStatus.oversized);
    }
    Object? cloud;
    try {
      cloud = jsonDecode(raw);
    } catch (_) {
      return result(SyncDiagnosticStatus.invalidJson);
    }
    if (cloud is! Map<String, dynamic> || !_knownRoot(conflict.type, cloud)) {
      return result(SyncDiagnosticStatus.unknownRoot);
    }
    final inspection = comparator.inspect(conflict.type, frozen, cloud);
    return result(
      inspection.limited
          ? SyncDiagnosticStatus.inspectionLimited
          : SyncDiagnosticStatus.compared,
      inspection.paths,
    );
  }

  bool _knownRoot(String type, Map<String, dynamic> cloud) => switch (type) {
    'character' => cloud['id'] is String && cloud['name'] is String,
    'character_knowledge' =>
      cloud['__characterKnowledge'] == true && cloud['facts'] is List,
    'memory_graph' =>
      cloud['__memoryGraph'] == true &&
          [
            'catalog',
            'entities',
            'salience',
            'cadence',
            'consolidation',
          ].every((key) => cloud[key] is List),
    _ => false,
  };

  Object? _snapshot(Object? value, [int depth = 0, List<int>? budget]) {
    budget ??= [8192];
    if (depth > 20 || --budget[0] < 0) return const _Uninspected();
    if (value is Map) {
      final copy = <Object?, Object?>{};
      for (final key in value.keys) {
        if (budget[0] < 0 || key is! String) {
          copy[const _Uninspected()] = null;
          break;
        }
        copy[key] = _snapshot(value[key], depth + 1, budget);
      }
      return copy;
    }
    if (value is List) {
      final copy = <Object?>[];
      for (final item in value) {
        copy.add(_snapshot(item, depth + 1, budget));
        if (budget[0] < 0) break;
      }
      return copy;
    }
    return value;
  }
}

class _Uninspected {
  const _Uninspected();
  @override
  String toString() => 'Uninspected';
}
