import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_unordered_aggregate.dart';

const _session = 'synthetic-session';
const _graphLists = [
  'catalog',
  'entities',
  'salience',
  'cadence',
  'consolidation',
];

Map<String, dynamic> _row(String id) => {
  'id': id,
  'chatSessionId': _session,
  'predicate': 'synthetic predicate',
  'lifecycle': 'retracted',
  'basisRevision': 3,
  'basisRevisionHash': 'synthetic-revision-hash',
  'entryRevision': 2,
  'sourceHash': 'synthetic-source-hash',
  'sourceMessageId': 'synthetic-message',
  'sourceSwipeId': 0,
  'createdAt': 1700000000000,
  'updatedAt': 1700000000001,
  'tokenCount': 7,
  'errorMessage': null,
  'confidence': 1.0,
  'entitiesJson': '["synthetic-a","synthetic-b"]',
  'unknown': {
    'facts': [1, 2],
    'catalog': [3, 4],
    'nested': {'z': true, 'a': null},
  },
};

Map<String, dynamic> _payload(String type) => type == 'memory_graph'
    ? {
        '__memoryGraph': true,
        'sessionId': _session,
        for (final name in _graphLists)
          name: name == 'cadence'
              ? [
                  {'chatSessionId': _session, 'lastRunAt': 1700000000000},
                ]
              : [_row('$name-b'), _row('$name-a')],
      }
    : {
        '__characterKnowledge': true,
        'sessionId': _session,
        'facts': List.generate(16, (i) => _row('synthetic-fact-$i')),
        'baseline': {
          'chatSessionId': _session,
          'characterId': 'synthetic-character',
          'baselineCardJson': '{"synthetic":true}',
          'baselineHash': 'synthetic-baseline-hash',
          'sourceHashLastSeen': 'synthetic-source-hash',
          'createdAt': 1700000000000,
          'updatedAt': 1700000000001,
        },
      };

Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

Object? _reverseMaps(Object? value) {
  if (value is Map) {
    return {
      for (final key in value.keys.toList().reversed)
        key: _reverseMaps(value[key]),
    };
  }
  if (value is List) return value.map(_reverseMaps).toList();
  return value;
}

bool _equal(String type, Object? a, Object? b) =>
    SyncUnorderedAggregate.equivalent(
      type: type,
      sessionId: _session,
      local: a,
      cloud: b,
    );

String? _canonical(String type, Object? value) =>
    SyncUnorderedAggregate.canonicalize(value, type: type, sessionId: _session);

class _Unsupported {
  int calls = 0;

  Object toJson() {
    calls++;
    throw StateError('Serializer forbidden');
  }

  @override
  String toString() {
    calls++;
    throw StateError('String conversion forbidden');
  }

  @override
  int get hashCode {
    calls++;
    throw StateError('Hash forbidden');
  }

  @override
  bool operator ==(Object other) {
    calls++;
    throw StateError('Equality forbidden');
  }
}

void main() {
  for (final type in ['memory_graph', 'character_knowledge']) {
    final listName = type == 'memory_graph' ? 'catalog' : 'facts';
    group(type, () {
      test(
        'only declared row permutations and map insertion order disappear',
        () {
          final original = _payload(type);
          final changed = _copy(original);
          for (final key in type == 'memory_graph' ? _graphLists : ['facts']) {
            changed[key] = (changed[key] as List).reversed.toList();
          }
          expect(_equal(type, original, _reverseMaps(changed)), isTrue);
          expect(original, _payload(type));
          expect(_canonical(type, original), _canonical(type, changed));
        },
      );

      for (final field in [
        'predicate',
        'lifecycle',
        'basisRevision',
        'basisRevisionHash',
        'entryRevision',
        'sourceHash',
        'sourceMessageId',
        'sourceSwipeId',
        'createdAt',
        'updatedAt',
        'tokenCount',
        'errorMessage',
      ]) {
        test('same stable ID with edited $field is not equivalent', () {
          final original = _payload(type);
          final changed = _copy(original);
          final row = (changed[listName] as List).first;
          final value = row[field];
          row[field] = value is int ? value + 1 : 'synthetic-edit';
          expect(_canonical(type, changed), isNotNull);
          expect(_equal(type, original, changed), isFalse);
        });
      }

      for (final edit in ['added', 'removed', 'membership', 'duplicate']) {
        test('$edit rows cannot prove equality', () {
          final original = _payload(type);
          final changed = _copy(original);
          final rows = changed[listName] as List;
          switch (edit) {
            case 'added':
              rows.add(_row('synthetic-new'));
            case 'removed':
              rows.removeLast();
            case 'membership':
              rows.first['id'] = 'synthetic-new';
            case 'duplicate':
              rows.add(_copy(rows.first as Map<String, dynamic>));
          }
          expect(_equal(type, original, changed), isFalse);
          if (edit == 'duplicate') {
            expect(_equal(type, changed, changed), isFalse);
          }
        });
      }

      test('nested arrays and JSON strings retain order', () {
        final original = _payload(type);
        for (final field in ['facts', 'catalog']) {
          final changed = _copy(original);
          changed[listName][0]['unknown'][field] = [9, 8];
          final ordered = _copy(changed);
          ordered[listName][0]['unknown'][field] = [8, 9];
          expect(_equal(type, ordered, changed), isFalse);
        }
        final changed = _copy(original);
        changed[listName][0]['entitiesJson'] = '["synthetic-b","synthetic-a"]';
        expect(_equal(type, original, changed), isFalse);
      });

      test('unknown root and row fields are preserved', () {
        final original = _payload(type);
        final changed = _copy(original)..['future'] = {'revision': 1};
        expect(_equal(type, original, changed), isFalse);
        changed.remove('future');
        changed[listName][0]['unknown']['nested']['z'] = false;
        expect(_equal(type, original, changed), isFalse);
      });

      test('type, null, presence and numeric representation stay distinct', () {
        for (final pair in <List<Object?>>[
          [null, 'null'],
          [false, 0],
          [1, '1'],
          [1, 1.0],
          [0.0, -0.0],
          [<Object?>[], <String, Object?>{}],
        ]) {
          final a = _payload(type)..['future'] = pair[0];
          final b = _payload(type)..['future'] = pair[1];
          expect(_equal(type, a, b), isFalse);
        }
        final a = _payload(type);
        final b = _copy(a);
        b[listName][0].remove('errorMessage');
        expect(_equal(type, a, b), isFalse);
      });

      test(
        'marker, owner and collection malformations fail even against self',
        () {
          final marker = type == 'memory_graph'
              ? '__memoryGraph'
              : '__characterKnowledge';
          final other = type == 'memory_graph'
              ? '__characterKnowledge'
              : '__memoryGraph';
          final edits = <void Function(Map<String, dynamic>)>[
            (p) => p.remove(marker),
            (p) => p[marker] = 'true',
            (p) => p[marker] = false,
            (p) => p[other] = true,
            (p) => p['sessionId'] = 'synthetic-other',
            (p) => p.remove('sessionId'),
            (p) => p['chatSessionId'] = 'synthetic-other',
            (p) => p.remove(listName),
            (p) => p[listName] = null,
            (p) => p[listName] = <String, Object?>{},
            (p) => p[listName] = [null],
            (p) => p[listName][0].remove('id'),
            (p) => p[listName][0]['id'] = null,
            (p) => p[listName][0]['id'] = 1,
            (p) => p[listName][0]['id'] = '  ',
            (p) => p[listName][0].remove('chatSessionId'),
            (p) => p[listName][0]['chatSessionId'] = 'synthetic-other',
          ];
          for (final edit in edits) {
            final invalid = _payload(type);
            edit(invalid);
            expect(_canonical(type, invalid), isNull);
            expect(_equal(type, invalid, invalid), isFalse);
          }
        },
      );
    });
  }

  test(
    'all graph collections are required and unique; cadence uses owner ID',
    () {
      for (final name in _graphLists) {
        final invalid = _payload('memory_graph')..remove(name);
        expect(_canonical('memory_graph', invalid), isNull);
        final duplicate = _copy(_payload('memory_graph'));
        duplicate[name].add(_copy(duplicate[name][0] as Map<String, dynamic>));
        expect(_equal('memory_graph', duplicate, duplicate), isFalse);
      }
      expect(_canonical('memory_graph', _payload('memory_graph')), isNotNull);
      final otherOwner = _payload('memory_graph');
      otherOwner['cadence'].add({'chatSessionId': 'synthetic-other'});
      expect(_canonical('memory_graph', otherOwner), isNull);
    },
  );

  test('optional baseline retains every field and presence', () {
    final original = _payload('character_knowledge');
    final absent = _copy(original)..remove('baseline');
    expect(_equal('character_knowledge', absent, _copy(absent)), isTrue);
    expect(_equal('character_knowledge', original, absent), isFalse);
    for (final field in (original['baseline'] as Map).keys) {
      final changed = _copy(original);
      final value = changed['baseline'][field];
      changed['baseline'][field] = value is int ? value + 1 : 'synthetic-edit';
      expect(_equal('character_knowledge', original, changed), isFalse);
      final missing = _copy(original);
      missing['baseline'].remove(field);
      expect(_equal('character_knowledge', original, missing), isFalse);
    }
    for (final value in [
      null,
      <Object?>[],
      <String, Object?>{},
      {'chatSessionId': 'synthetic-other'},
    ]) {
      final invalid = _copy(original)..['baseline'] = value;
      expect(_equal('character_knowledge', invalid, invalid), isFalse);
    }
  });

  test(
    'every graph row list preserves row values and requires its stable key',
    () {
      final original = _payload('memory_graph');
      for (final name in _graphLists) {
        final changed = _copy(original);
        changed[name][0]['futureRevision'] = 1;
        expect(_canonical('memory_graph', changed), isNotNull);
        expect(_equal('memory_graph', original, changed), isFalse);
        final invalid = _copy(original);
        invalid[name][0].remove(name == 'cadence' ? 'chatSessionId' : 'id');
        expect(_canonical('memory_graph', invalid), isNull);
      }
    },
  );

  test('empty declared collections are valid and marker types are strict', () {
    final empty = _payload('memory_graph');
    for (final name in _graphLists) {
      empty[name] = <Object?>[];
    }
    expect(_equal('memory_graph', empty, _copy(empty)), isTrue);
    final knowledge = _payload('character_knowledge')
      ..['facts'] = <Object?>[]
      ..remove('baseline');
    expect(_equal('character_knowledge', knowledge, _copy(knowledge)), isTrue);
    for (final marker in [null, 1, <String, Object?>{}]) {
      knowledge['__characterKnowledge'] = marker;
      expect(_canonical('character_knowledge', knowledge), isNull);
    }
  });

  test('adversarial string keys have collision-free escaping', () {
    final original = _payload('character_knowledge')
      ..['future'] = {
        'a:b': 'c',
        'a': 'b:c',
        '"\\\n\u0000': 'synthetic',
        '__proto__': true,
        '🐈‍⬛': 'synthetic',
      };
    final canonical = _canonical('character_knowledge', original)!;
    expect((jsonDecode(canonical) as Map)['future'], original['future']);
    expect(
      _equal('character_knowledge', original, jsonDecode(canonical)),
      isTrue,
    );
    expect(
      _equal('character_knowledge', original, _reverseMaps(original)),
      isTrue,
    );
    final changed = _copy(original);
    changed['future']['a:b'] = 'different';
    expect(_equal('character_knowledge', original, changed), isFalse);
  });

  test('cycles, unsupported objects and non-string keys never serialize', () {
    final unsupported = _Unsupported();
    final listCycle = <Object?>[];
    listCycle.add(listCycle);
    final mapCycle = <String, Object?>{};
    mapCycle['self'] = mapCycle;
    for (final invalid in [
      unsupported,
      {1: 'synthetic'},
      Map<Object, Object?>.identity()..[unsupported] = 'synthetic',
      listCycle,
      mapCycle,
      double.nan,
      double.infinity,
      double.negativeInfinity,
      String.fromCharCode(0xd800),
      String.fromCharCode(0xdc00),
    ]) {
      final payload = _payload('character_knowledge')..['future'] = invalid;
      expect(_canonical('character_knowledge', payload), isNull);
      expect(_equal('character_knowledge', payload, payload), isFalse);
    }
    expect(unsupported.calls, 0);
    final shared = {
      'synthetic': [1, 2],
    };
    final valid = _payload('character_knowledge')
      ..['future'] = [shared, shared];
    expect(_equal('character_knowledge', valid, _copy(valid)), isTrue);
  });

  test('per-payload UTF-8 JSON byte limit is exact including escapes', () {
    final base = _payload('character_knowledge')..['future'] = '';
    final overhead = utf8
        .encode(_canonical('character_knowledge', base)!)
        .length;
    final available = SyncUnorderedAggregate.maxBytes - overhead;
    for (final token in ['x', 'я', '🐈', '\u0000']) {
      final cost = utf8.encode(jsonEncode(token)).length - 2;
      base['future'] = token * (available ~/ cost) + 'x' * (available % cost);
      final atLimit = _canonical('character_knowledge', base);
      expect(atLimit, isNotNull);
      expect(utf8.encode(atLimit!).length, SyncUnorderedAggregate.maxBytes);
      base['future'] = '${base['future']}x';
      expect(_canonical('character_knowledge', base), isNull);
    }
  });

  test('node and depth limits reject before unbounded traversal', () {
    final base = <String, Object?>{
      '__characterKnowledge': true,
      'sessionId': _session,
      'facts': [],
      'future': List.filled(
        SyncUnorderedAggregate.maxNodes - 9,
        null,
        growable: true,
      ),
    };
    expect(_canonical('character_knowledge', base), isNotNull);
    (base['future'] as List).add(null);
    expect(_canonical('character_knowledge', base), isNull);
    Object? nested;
    for (var i = 0; i < SyncUnorderedAggregate.maxDepth - 1; i++) {
      nested = [nested];
    }
    base['future'] = nested;
    expect(_canonical('character_knowledge', base), isNotNull);
    base['future'] = [nested];
    expect(_canonical('character_knowledge', base), isNull);
  });

  test('unsupported domains and absent roots never prove equality', () {
    expect(_equal('character', {}, {}), isFalse);
    expect(_equal('memory_graph', null, null), isFalse);
    expect(_equal('memory_graph', [], []), isFalse);
    expect(
      SyncUnorderedAggregate.canonicalize(
        _payload('memory_graph'),
        type: 'memory_graph',
        sessionId: '',
      ),
      isNull,
    );
  });
}
