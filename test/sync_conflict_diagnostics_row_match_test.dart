import 'dart:collection';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_conflict.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_conflict_diagnostics.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_conflict_diagnostics_comparator.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_conflict_diagnostics_schema.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_models.dart';

const _canary = 'SYNTHETIC_PRIVATE_ROW_CANARY';
const _comparator = SyncConflictDiagnosticComparator();

class _Forbidden {
  @override
  int get hashCode => throw StateError('hash forbidden');
  @override
  bool operator ==(Object other) => throw StateError('equality forbidden');
  @override
  String toString() => throw StateError('text forbidden');
  Object toJson() => throw StateError('serializer forbidden');
}

Map<String, dynamic> _payload(String type, {bool reverse = false}) {
  if (type == 'character') {
    return {'id': _canary, 'name': _canary, 'world': 'synthetic'};
  }
  final rows = List.generate(
    3,
    (i) => <String, dynamic>{
      'id': '${_canary}_$i',
      if (type == 'character_knowledge') ...{
        'predicate': 'synthetic predicate $i',
        'lifecycle': i.isEven ? 'active' : 'retracted',
        'basisRevisionHash': 'synthetic hash $i',
      } else ...{
        'title': 'synthetic title $i',
        'sourceHash': 'synthetic hash $i',
      },
      'updatedAt': i,
    },
  );
  return type == 'character_knowledge'
      ? {
          '__characterKnowledge': true,
          'sessionId': _canary,
          'facts': reverse ? rows.reversed.toList() : rows,
        }
      : {
          '__memoryGraph': true,
          'sessionId': _canary,
          'catalog': reverse ? rows.reversed.toList() : rows,
          'entities': <Object?>[],
          'salience': <Object?>[],
          'cadence': <Object?>[],
          'consolidation': <Object?>[],
        };
}

List<String> _evidence(DiagnosticInspection inspection) => inspection.paths
    .map((path) => '${path.path}: ${path.difference.name}')
    .toList();

void main() {
  test(
    '29-shaped synthetic report separates permutation from content',
    () async {
      final types = [
        ...List.filled(12, 'character'),
        ...List.filled(16, 'character_knowledge'),
        'memory_graph',
      ];
      final conflicts = [
        for (var i = 0; i < types.length; i++)
          SyncConflict(
            key: _canary,
            type: types[i],
            id: '${_canary}_$i',
            name: _canary,
            localEntry: SyncManifestEntry(
              type: types[i],
              id: '${_canary}_$i',
              path: _canary,
              updatedAt: 1,
              hash: _canary,
            ),
            cloudEntry: SyncManifestEntry(
              type: types[i],
              id: '${_canary}_$i',
              path: _canary,
              updatedAt: 1,
              hash: _canary,
            ),
          ),
      ];
      final report = await SyncConflictDiagnostics(
        readLocal: (type, _) async => _payload(type),
        download: (path) async => jsonEncode(
          _payload(
            path.contains('/characters/')
                ? 'character'
                : path.contains('/character_knowledge/')
                ? 'character_knowledge'
                : 'memory_graph',
            reverse: true,
          ),
        ),
      ).diagnose(conflicts);
      expect(report.items, hasLength(29));
      expect(
        report.items.every((i) => i.status == SyncDiagnosticStatus.compared),
        isTrue,
      );
      expect(report.items.take(12).every((i) => i.paths.isEmpty), isTrue);
      for (final item in report.items.skip(12)) {
        expect(item.paths, hasLength(1));
        expect(item.paths.single.difference, SyncDiagnosticDifference.order);
        expect(
          item.paths.single.path,
          item.type == SyncDiagnosticType.memoryGraph ? 'catalog[]' : 'facts[]',
        );
      }
      expect(report.toSafeText(), isNot(contains(_canary)));
    },
  );

  for (final schema in [
    'facts',
    'catalog',
    'entities',
    'salience',
    'cadence',
    'consolidation',
  ]) {
    test('$schema uses its stable key in both directions', () {
      final key = schema == 'cadence' ? 'chatSessionId' : 'id';
      final field = diagnosticSchemas['$schema[]']!.last;
      final rows = [
        {key: '${_canary}_a', field: 1},
        {key: '${_canary}_b', field: 2},
      ];
      final type = schema == 'facts' ? 'character_knowledge' : 'memory_graph';
      for (final pair in [
        (rows, rows.reversed.toList()),
        (rows.reversed.toList(), rows),
      ]) {
        final result = _comparator.inspect(
          type,
          {schema: pair.$1},
          {schema: pair.$2},
        );
        expect(result.limited, isFalse);
        expect(_evidence(result), ['$schema[]: order']);
      }
      final changed = rows.reversed.map((row) => {...row}).toList();
      changed.last[field] = 3;
      final result = _comparator.inspect(
        type,
        {schema: rows},
        {schema: changed},
      );
      expect(_evidence(result), [
        '$schema[]: order',
        '$schema[].$field: value',
      ]);
      expect(result.paths.join(), isNot(contains(_canary)));
    });
  }

  test('same-ID predicate lifecycle hash and timestamp changes stay exact', () {
    final a = _payload('character_knowledge');
    final b = _payload('character_knowledge', reverse: true);
    (b['facts'] as List).last.addAll({
      'predicate': 'edited',
      'lifecycle': 'superseded',
      'basisRevisionHash': 'edited hash',
      'updatedAt': 9,
    });
    final result = _comparator.inspect('character_knowledge', a, b);
    expect(result.limited, isFalse);
    expect(_evidence(result), [
      'facts[]: order',
      'facts[].predicate: value',
      'facts[].lifecycle: value',
      'facts[].basisRevisionHash: value',
      'facts[].updatedAt: value',
    ]);
    expect(
      _evidence(_comparator.inspect('character_knowledge', b, a)),
      unorderedEquals(_evidence(result)),
    );
  });

  test('added removed and replaced IDs produce static membership evidence', () {
    final a = {
      'facts': [
        {'id': '${_canary}_a', 'predicate': 'kept'},
      ],
    };
    for (final b in [
      {'facts': <Object?>[]},
      {
        'facts': [
          {'id': '${_canary}_a', 'predicate': 'kept'},
          {'id': '${_canary}_b', 'predicate': 'new'},
        ],
      },
      {
        'facts': [
          {'id': '${_canary}_b', 'predicate': 'new'},
        ],
      },
    ]) {
      final result = _comparator.inspect('character_knowledge', a, b);
      expect(result.limited, isFalse);
      expect(_evidence(result), contains('facts[]: presence'));
      expect(
        _evidence(result),
        unorderedEquals([
          if ((b['facts'] as List).length != 1) 'facts: size',
          'facts[]: order',
          'facts[]: presence',
        ]),
      );
      expect(_evidence(result), isNot(contains('facts[].predicate: value')));
      expect(_evidence(result), isNot(contains('facts[].id: value')));
      expect(result.paths.join(), isNot(contains(_canary)));
      expect(
        _evidence(_comparator.inspect('character_knowledge', b, a)),
        unorderedEquals(_evidence(result)),
      );
    }
  });

  test('invalid duplicate missing and unknown-object IDs fail closed', () {
    final unknownKey = HashMap<Object, Object?>.identity()
      ..['id'] = _canary
      ..[_Forbidden()] = _canary;
    for (final rows in [
      [
        {'id': _canary},
        {'id': _canary},
      ],
      [
        {'predicate': _canary},
      ],
      [
        {'id': ''},
      ],
      [
        {'id': '   '},
      ],
      [
        {'id': null},
      ],
      [
        {'id': true},
      ],
      [
        {'id': 1.0},
      ],
      [
        {'id': <Object?>[]},
      ],
      [
        {'id': _Forbidden()},
      ],
      [unknownKey],
      [_Forbidden()],
    ]) {
      for (final pair in [
        (rows, rows),
        (
          rows,
          [
            {'id': _canary},
          ],
        ),
        (
          [
            {'id': _canary},
          ],
          rows,
        ),
      ]) {
        final result = _comparator.inspect(
          'character_knowledge',
          {'facts': pair.$1},
          {'facts': pair.$2},
        );
        expect(result.limited, isTrue);
        expect(result.equal, isFalse);
        expect(_evidence(result), contains('facts[]: shape'));
        expect(result.paths.join(), isNot(contains(_canary)));
      }
    }
  });

  test('valid integer IDs are distinct from string IDs', () {
    final result = _comparator.inspect(
      'character_knowledge',
      {
        'facts': [
          {'id': 1},
          {'id': '1'},
        ],
      },
      {
        'facts': [
          {'id': '1'},
          {'id': 1},
        ],
      },
    );
    expect(result.limited, isFalse);
    expect(_evidence(result), ['facts[]: order']);
  });

  test('graph source hash edits are matched rather than positional', () {
    final a = _payload('memory_graph');
    final b = _payload('memory_graph', reverse: true);
    (b['catalog'] as List).last['sourceHash'] = 'synthetic edited hash';
    final beforeA = jsonEncode(a);
    final beforeB = jsonEncode(b);
    final result = _comparator.inspect('memory_graph', a, b);
    expect(_evidence(result), [
      'catalog[]: order',
      'catalog[].sourceHash: value',
    ]);
    expect(result.limited, isFalse);
    expect(jsonEncode(a), beforeA);
    expect(jsonEncode(b), beforeB);
    expect(result.paths.join(), isNot(contains(_canary)));
  });

  test(
    'matched rows with unknown field names remain limited and values-free',
    () {
      final result = _comparator.inspect(
        'character_knowledge',
        {
          'facts': [
            {'id': _canary, _canary: 'synthetic value'},
          ],
        },
        {
          'facts': [
            {'id': _canary, _canary: 'synthetic edit'},
          ],
        },
      );
      expect(result.limited, isTrue);
      expect(result.equal, isFalse);
      expect(_evidence(result), ['facts[]: unknownSchema']);
      expect(result.paths.join(), isNot(contains(_canary)));
    },
  );

  test('permuted rows do not hide depth-limit evidence', () {
    final recursive = <String, Object?>{};
    recursive[_canary] = recursive;
    final rows = [
      {'id': '${_canary}_a', 'predicate': recursive},
      {'id': '${_canary}_b', 'predicate': 'synthetic'},
    ];
    final result = _comparator.inspect(
      'character_knowledge',
      {'facts': rows},
      {'facts': rows.reversed.toList()},
    );
    expect(result.limited, isTrue);
    expect(result.equal, isFalse);
    expect(_evidence(result), contains('facts[]: order'));
    expect(_evidence(result), contains(r'$: omitted'));
    expect(result.paths.join(), isNot(contains(_canary)));
  });

  test('gallery remains authored and positional including label edits', () {
    final a = {
      'gallery': [
        {'id': '${_canary}_a', 'label': 'first'},
        {'id': '${_canary}_b', 'label': 'second'},
      ],
    };
    final b = {
      'gallery': [
        {'id': '${_canary}_b', 'label': 'edited second'},
        {'id': '${_canary}_a', 'label': 'first'},
      ],
    };
    final result = _comparator.inspect('character', a, b);
    expect(result.limited, isFalse);
    expect(_evidence(result), [
      'gallery[]: order',
      'gallery[].id: value',
      'gallery[].label: value',
    ]);
    expect(result.paths.join(), isNot(contains(_canary)));
  });

  test('matched rows retain map order numeric shape and field presence', () {
    final result = _comparator.inspect(
      'character_knowledge',
      {
        'facts': [
          {'id': _canary, 'confidence': 1, 'predicate': 'kept'},
        ],
      },
      {
        'facts': [
          {'confidence': 1.0, 'predicate': 'kept', 'id': _canary},
        ],
      },
    );
    expect(_evidence(result), ['facts[]: order', 'facts[].confidence: shape']);
    final presence = _comparator.inspect(
      'character_knowledge',
      {
        'facts': [
          {'id': _canary, 'predicate': 'kept'},
        ],
      },
      {
        'facts': [
          {'id': _canary},
        ],
      },
    );
    expect(_evidence(presence), ['facts[].predicate: presence']);
  });

  test(
    'matching respects row and shared node budgets without equality claims',
    () {
      for (final count in [4096, 4097]) {
        final rows = List.generate(count, (i) => {'id': '${_canary}_$i'});
        final result = _comparator.inspect(
          'character_knowledge',
          {'facts': rows},
          {'facts': rows.reversed.toList()},
        );
        expect(result.limited, isTrue);
        expect(result.equal, isFalse);
        expect(_evidence(result), contains(r'$: omitted'));
        expect(result.paths.length, lessThanOrEqualTo(128));
        expect(result.paths.join(), isNot(contains(_canary)));
      }
    },
  );
}
