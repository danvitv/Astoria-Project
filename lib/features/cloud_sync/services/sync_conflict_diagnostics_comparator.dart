import '../../../../core/models/gallery_entry.dart';
import 'sync_conflict_diagnostics_report.dart';
import 'sync_conflict_diagnostics_row_matcher.dart';
import 'sync_conflict_diagnostics_schema.dart';

/// Pure, bounded inspection. Never invokes arbitrary serializers or toString.
class SyncConflictDiagnosticComparator {
  const SyncConflictDiagnosticComparator();

  DiagnosticInspection inspect(String type, Object? local, Object? cloud) {
    final walker = _DiagnosticWalker();
    walker.compare(local, cloud, '', type, 0);
    return DiagnosticInspection(
      List.unmodifiable(walker.paths),
      walker.limited,
    );
  }
}

class DiagnosticInspection {
  final List<SyncDiagnosticPath> paths;
  final bool limited;
  const DiagnosticInspection(this.paths, this.limited);
  bool get equal => paths.isEmpty && !limited;
  @override
  String toString() => 'DiagnosticInspection';
}

class _DiagnosticWalker {
  final paths = <SyncDiagnosticPath>[];
  int nodes = 0;
  bool limited = false;

  void add(String path, SyncDiagnosticDifference kind) {
    path = path.isEmpty ? r'$' : path;
    if (paths.any((p) => p.path == path && p.difference == kind)) return;
    if (paths.length >= 127) {
      limited = true;
      if (paths.length == 127) {
        paths.add(SyncDiagnosticPath(r'$', SyncDiagnosticDifference.omitted));
      }
      return;
    }
    paths.add(SyncDiagnosticPath(path, kind));
  }

  Object? materialize(Object? value) => value is GalleryEntry
      ? <String, Object?>{
          'id': value.id,
          'characterId': value.characterId,
          'imagePath': value.imagePath,
          'label': value.label,
          'createdAt': value.createdAt,
        }
      : value;

  bool consume([int depth = 0]) {
    if (++nodes > 8192 || depth > 20 || paths.length >= 128) {
      limited = true;
      add(r'$', SyncDiagnosticDifference.omitted);
      return false;
    }
    return true;
  }

  void compare(Object? a, Object? b, String path, String schema, int depth) {
    if (!consume(depth)) return;
    a = materialize(a);
    b = materialize(b);
    if (a is Map && b is Map) {
      final fields = diagnosticSchemas[schema];
      if (fields == null) {
        if (!opaqueEqual(a, b, depth)) {
          add('$path.*', SyncDiagnosticDifference.value);
        }
        return;
      }
      // Examine only a bounded number of keys; unknown names never escape.
      for (final map in [a, b]) {
        var count = 0;
        for (final key in map.keys) {
          if (++count > 8192) {
            limited = true;
            add(r'$', SyncDiagnosticDifference.omitted);
            break;
          }
          if (!fields.contains(key)) {
            limited = true;
            add(path, SyncDiagnosticDifference.unknownSchema);
            break;
          }
        }
      }
      // Raw JSON preserves insertion order. Only fully allowlisted key sets
      // receive static order evidence; unknown names remain opaque/limited.
      if (a.length <= fields.length && b.length == a.length) {
        final keysA = a.keys.toList();
        final keysB = b.keys.toList();
        if (keysA.every((key) => key is String && fields.contains(key)) &&
            keysB.every((key) => key is String && fields.contains(key)) &&
            keysA.every(b.containsKey) &&
            List.generate(
              keysA.length,
              (i) => keysA[i] != keysB[i],
            ).contains(true)) {
          add(path, SyncDiagnosticDifference.order);
        }
      }
      for (final field in fields) {
        final next = path.isEmpty ? field : '$path.$field';
        if (a.containsKey(field) != b.containsKey(field)) {
          add(next, SyncDiagnosticDifference.presence);
        } else if (a.containsKey(field)) {
          compare(a[field], b[field], next, field, depth + 1);
        }
      }
    } else if (a is List && b is List) {
      if (a.length != b.length) add(path, SyncDiagnosticDifference.size);
      final rowSchema = '$schema[]';
      final rowPath = '$path[]';
      if (SyncDiagnosticRowMatcher.supports(schema)) {
        SyncDiagnosticRowMatcher(
          consume: consume,
          add: add,
          markLimited: () => limited = true,
        ).compare(a, b, schema, rowPath, (local, cloud) {
          compare(local, cloud, rowPath, rowSchema, depth + 1);
        });
        return;
      }
      // Detect permutations by trusted stable scalar IDs; never emit IDs.
      if (schema == 'gallery' && a.length == b.length && a.length <= 4096) {
        final idsA = rowIds(a, schema == 'cadence' ? 'chatSessionId' : 'id');
        final idsB = rowIds(b, schema == 'cadence' ? 'chatSessionId' : 'id');
        if (idsA != null &&
            idsB != null &&
            idsA.toSet().length == a.length &&
            idsB.toSet().length == b.length &&
            idsA.toSet().containsAll(idsB) &&
            List.generate(
              a.length,
              (i) => idsA[i] == idsB[i],
            ).contains(false)) {
          add(rowPath, SyncDiagnosticDifference.order);
        }
      }
      final length = a.length < b.length ? a.length : b.length;
      for (var i = 0; i < length; i++) {
        if (nodes > 8192) {
          limited = true;
          add(r'$', SyncDiagnosticDifference.omitted);
          break;
        }
        compare(
          a[i],
          b[i],
          diagnosticSchemas.containsKey(rowSchema) ? rowPath : path,
          rowSchema,
          depth + 1,
        );
      }
    } else if (a is Map || b is Map || a is List || b is List) {
      add(path, SyncDiagnosticDifference.shape);
    } else if (!scalar(a) || !scalar(b)) {
      limited = true;
      add(path, SyncDiagnosticDifference.omitted);
    } else if (a != b) {
      add(path, SyncDiagnosticDifference.value);
    } else if ((a is int && b is double) || (a is double && b is int)) {
      // Equal numeric values can still encode differently (1 versus 1.0).
      add(path, SyncDiagnosticDifference.shape);
    }
  }

  List<Object>? rowIds(List<dynamic> rows, String key) {
    final ids = <Object>[];
    for (final raw in rows) {
      final row = materialize(raw);
      if (row is! Map || (row[key] is! String && row[key] is! int)) return null;
      ids.add(row[key] as Object);
    }
    return ids;
  }

  bool scalar(Object? v) => v == null || v is String || v is num || v is bool;

  bool opaqueEqual(Object? a, Object? b, int depth) {
    if (++nodes > 8192 || depth > 20) {
      limited = true;
      add(r'$', SyncDiagnosticDifference.omitted);
      return false;
    }
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      // Dynamic key names and representation differences never become paths.
      // Reject unknown key objects rather than invoking their hash/equality.
      final keysB = b.keys.iterator;
      for (final key in a.keys) {
        if (key is! String || !keysB.moveNext() || keysB.current is! String) {
          limited = true;
          add(r'$', SyncDiagnosticDifference.omitted);
          return false;
        }
        if (key != keysB.current) return false;
        if (!b.containsKey(key) || !opaqueEqual(a[key], b[key], depth + 1)) {
          return false;
        }
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!opaqueEqual(a[i], b[i], depth + 1)) return false;
      }
      return true;
    }
    if (!scalar(a) || !scalar(b)) {
      limited = true;
      add(r'$', SyncDiagnosticDifference.omitted);
      return false;
    }
    return a == b && !((a is int && b is double) || (a is double && b is int));
  }
}
