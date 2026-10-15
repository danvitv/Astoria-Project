import 'sync_conflict_diagnostics_report.dart';

/// Matches only declared unordered DB rows. Identities remain private scalars.
class SyncDiagnosticRowMatcher {
  final bool Function() consume;
  final void Function(String, SyncDiagnosticDifference) add;
  final void Function() markLimited;

  const SyncDiagnosticRowMatcher({
    required this.consume,
    required this.add,
    required this.markLimited,
  });

  static bool supports(String schema) => const {
    'facts',
    'catalog',
    'entities',
    'salience',
    'cadence',
    'consolidation',
  }.contains(schema);

  void compare(
    List<dynamic> a,
    List<dynamic> b,
    String schema,
    String path,
    void Function(Object?, Object?) compareRow,
  ) {
    if (a.length > 4096 || b.length > 4096) {
      markLimited();
      add(r'$', SyncDiagnosticDifference.omitted);
      return;
    }
    final key = schema == 'cadence' ? 'chatSessionId' : 'id';
    final rowsA = _index(a, key);
    final rowsB = _index(b, key);
    if (rowsA == null || rowsB == null) {
      markLimited();
      add(path, SyncDiagnosticDifference.shape);
      return;
    }
    final idsA = rowsA.keys.toList();
    final idsB = rowsB.keys.toList();
    if (idsA.length != idsB.length ||
        List.generate(idsA.length, (i) => idsA[i] != idsB[i]).contains(true)) {
      add(path, SyncDiagnosticDifference.order);
    }
    for (final id in idsA) {
      if (!consume()) return;
      if (rowsB.containsKey(id)) {
        compareRow(rowsA[id], rowsB[id]);
      } else {
        add(path, SyncDiagnosticDifference.presence);
      }
    }
    for (final id in idsB) {
      if (!consume()) return;
      if (!rowsA.containsKey(id)) add(path, SyncDiagnosticDifference.presence);
    }
  }

  Map<Object, Map<dynamic, dynamic>>? _index(List<dynamic> rows, String key) {
    final result = <Object, Map<dynamic, dynamic>>{};
    for (final row in rows) {
      if (!consume() || row is! Map) return null;
      // Do not hash, compare, serialize or stringify unknown key objects.
      for (final field in row.keys) {
        if (!consume() || field is! String) return null;
      }
      final id = row[key];
      if (id is! String && id is! int) return null;
      if (id is String && id.trim().isEmpty) return null;
      if (result.containsKey(id)) return null;
      result[id as Object] = row;
    }
    return result;
  }
}
