import 'dart:collection';
import 'dart:convert';

/// Exact JSON equality for the two session-scoped DB aggregates, not a sync hash.
///
/// Only map insertion order and the declared top-level DB row lists are ignored.
/// All other values (including unknown fields and JSON stored inside strings)
/// remain significant. This is shape/identity validation, not an import parser.
/// Callers must still authenticate the cloud hash and recheck the raw local hash
/// after any await before accepting a cloud entry. This helper does neither.
class SyncUnorderedAggregate {
  static const maxBytes = 2 * 1024 * 1024;
  static const maxNodes = 100000;
  static const maxDepth = 64;

  static bool equivalent({
    required String type,
    required String sessionId,
    required Object? local,
    required Object? cloud,
  }) {
    final left = canonicalize(local, type: type, sessionId: sessionId);
    if (left == null) return false;
    final right = canonicalize(cloud, type: type, sessionId: sessionId);
    return right != null && left == right;
  }

  /// Returns null for invalid/non-JSON input or a per-payload limit violation.
  /// The returned text contains payload data; do not log or publish it as a hash.
  /// Bytes are canonical UTF-8 JSON bytes, nodes include map keys, and root depth
  /// is zero. Lone UTF-16 surrogates and non-finite numbers are rejected.
  static String? canonicalize(
    Object? payload, {
    required String type,
    required String sessionId,
  }) {
    if (sessionId.isEmpty || sessionId.length > maxBytes) return null;
    final collections = switch (type) {
      'memory_graph' => const {
        'catalog': 'id',
        'entities': 'id',
        'salience': 'id',
        'cadence': 'chatSessionId',
        'consolidation': 'id',
      },
      'character_knowledge' => const {'facts': 'id'},
      _ => null,
    };
    if (collections == null) return null;
    try {
      final writer = _AggregateWriter(sessionId, collections);
      writer.validateRoot(payload, type);
      writer.write(payload, 0);
      return writer.output.toString();
    } catch (_) {
      // No exception text or payload leaves this pure, fail-closed boundary.
      return null;
    }
  }
}

class _AggregateWriter {
  _AggregateWriter(this.sessionId, this.collections);

  final String sessionId;
  final Map<String, String> collections;
  final output = StringBuffer();
  final _active = HashSet<Object>.identity();
  int _bytes = 0;
  int _nodes = 0;

  Never _reject() => throw const FormatException('Invalid aggregate');

  void validateRoot(Object? value, String type) {
    if (value is! Map || value.length > SyncUnorderedAggregate.maxNodes) {
      _reject();
    }
    final marker = type == 'memory_graph'
        ? '__memoryGraph'
        : '__characterKnowledge';
    final other = type == 'memory_graph'
        ? '__characterKnowledge'
        : '__memoryGraph';
    if (!identical(value[marker], true) || value.containsKey(other)) _reject();
    _validateSession(value);
    final rootSession = value['sessionId'];
    if (rootSession is! String || rootSession != sessionId) _reject();
    for (final key in collections.keys) {
      if (value[key] is! List) _reject();
    }
    if (type == 'character_knowledge' && value.containsKey('baseline')) {
      final baseline = value['baseline'];
      if (baseline is! Map) _reject();
      _validateSession(baseline, required: true);
    }
  }

  void _validateSession(Map<dynamic, dynamic> row, {bool required = false}) {
    if (!required && !row.containsKey('chatSessionId')) return;
    final owner = row['chatSessionId'];
    if (owner is! String || owner != sessionId) _reject();
  }

  void _emit(String text, [int? bytes]) {
    _bytes += bytes ?? text.length; // Non-string tokens are ASCII.
    if (_bytes > SyncUnorderedAggregate.maxBytes) _reject();
    output.write(text);
  }

  void _string(String value) {
    // Compute escaped UTF-8 size before allocating the encoded string.
    var bytes = 2;
    if (value.length > SyncUnorderedAggregate.maxBytes - _bytes) _reject();
    for (var i = 0; i < value.length; i++) {
      final unit = value.codeUnitAt(i);
      if (unit == 34 || unit == 92 || const {8, 9, 10, 12, 13}.contains(unit)) {
        bytes += 2;
      } else if (unit < 32) {
        bytes += 6;
      } else if (unit < 128) {
        bytes++;
      } else if (unit < 2048) {
        bytes += 2;
      } else if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++i >= value.length) _reject();
        final low = value.codeUnitAt(i);
        if (low < 0xdc00 || low > 0xdfff) _reject();
        bytes += 4;
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        _reject();
      } else {
        bytes += 3;
      }
      if (bytes > SyncUnorderedAggregate.maxBytes - _bytes) _reject();
    }
    _emit(jsonEncode(value), bytes);
  }

  void write(Object? value, int depth, {String? rowKey}) {
    if (++_nodes > SyncUnorderedAggregate.maxNodes ||
        depth > SyncUnorderedAggregate.maxDepth) {
      _reject();
    }
    if (identical(value, null)) {
      _emit('null');
    } else if (value is String) {
      _string(value);
    } else if (value is bool || value is int) {
      _emit(jsonEncode(value));
    } else if (value is double) {
      if (!value.isFinite) _reject();
      _emit(jsonEncode(value)); // Keeps int/double and signed zero distinct.
    } else if (value is Map) {
      if (!_active.add(value) ||
          value.length > SyncUnorderedAggregate.maxNodes - _nodes) {
        _reject();
      }
      final keys = <String>[];
      var keyUnits = 0;
      for (final key in value.keys) {
        if (key is! String) _reject();
        keyUnits += key.length;
        if (keyUnits > SyncUnorderedAggregate.maxBytes - _bytes) _reject();
        keys.add(key);
      }
      keys.sort();
      _emit('{');
      for (var i = 0; i < keys.length; i++) {
        if (i > 0) _emit(',');
        write(keys[i], depth + 1);
        _emit(':');
        write(
          value[keys[i]],
          depth + 1,
          rowKey: depth == 0 ? collections[keys[i]] : null,
        );
      }
      _emit('}');
      _active.remove(value);
    } else if (value is List) {
      if (!_active.add(value) ||
          value.length > SyncUnorderedAggregate.maxNodes - _nodes) {
        _reject();
      }
      final rows = rowKey == null ? value : _orderedRows(value, rowKey);
      _emit('[');
      for (var i = 0; i < rows.length; i++) {
        if (i > 0) _emit(',');
        write(rows[i], depth + 1);
      }
      _emit(']');
      _active.remove(value);
    } else {
      _reject(); // Never call arbitrary toJson, toString, equality or hashCode.
    }
  }

  List<Map<dynamic, dynamic>> _orderedRows(List<dynamic> rows, String key) {
    final byId = <String, Map<dynamic, dynamic>>{};
    var idUnits = 0;
    for (final row in rows) {
      if (row is! Map) _reject();
      final id = row[key];
      if (id is! String || id.length > SyncUnorderedAggregate.maxBytes) {
        _reject();
      }
      if (id.trim().isEmpty) _reject();
      idUnits += id.length;
      if (idUnits > SyncUnorderedAggregate.maxBytes - _bytes) _reject();
      _validateSession(row, required: true);
      if (byId.containsKey(id)) _reject();
      byId[id] = row;
    }
    final ids = byId.keys.toList()..sort();
    return [for (final id in ids) byId[id]!];
  }
}
